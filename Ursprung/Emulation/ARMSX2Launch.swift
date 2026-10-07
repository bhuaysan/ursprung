// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Why ARMSX2 is not started for a game. Every error ARMSX2 would report
/// itself opens a dialog, and dialogs crash it on macOS 27, so Ursprung checks
/// what it can beforehand (docs/STANDALONE_PLAN.md, S5).
nonisolated enum StandaloneLaunchError: LocalizedError {
    case gameUnreadable(name: String)
    case memoryCardReadOnly(URL)
    case folderNotWritable(URL)
    case settingsNotWritten(reason: String)
    case stateNotLoadable

    var errorDescription: String? {
        switch self {
        case .gameUnreadable(let name):
            String(localized: "“\(name)” can't be read. Check its permissions in the Finder (Get Info › Sharing & Permissions), then try again.")
        case .memoryCardReadOnly(let url):
            String(localized: "The game's memory card is locked or read-only, so its saves couldn't be written: \(url.path(percentEncoded: false)).")
        case .folderNotWritable(let url):
            String(localized: "Ursprung can't write to “\(url.path(percentEncoded: false))”. Check the folder's permissions, then try again.")
        case .settingsNotWritten(let reason):
            String(localized: "The emulator's settings couldn't be written. \(reason)")
        case .stateNotLoadable:
            String(localized: "The save state can't be loaded. It is damaged, or it was saved by a version of ARMSX2 that this one can't read.")
        }
    }
}

/// Everything needed to start ARMSX2 for one game, or with its own window
/// for its settings: checked, with its settings written
/// (docs/STANDALONE_PLAN.md, "Process and window").
nonisolated struct ARMSX2Launch: Sendable {
    /// Where the game's files go and what ARMSX2 is started with.
    nonisolated struct Request: Sendable {
        var app: URL
        var executable: String
        /// ARMSX2's own data folder (`-datapath`), shared by all versions.
        var dataFolder: URL
        var logFile: URL
        /// Where the PINE socket goes: ARMSX2 replaces whatever is at its
        /// socket path, so only Ursprung uses this folder (S3).
        var pineFolder: URL
        /// Without a game ARMSX2 opens its own window, where its settings
        /// are (Q5); the folders then are ARMSX2's own (`ownFolder`).
        var game: URL?
        var biosFolder: URL
        var dumps: [PS2BIOS]
        /// Region of the BIOS to prefer when the disc does not tell.
        var fallbackRegion: PS2BIOS.Region
        var memoryCardFolder: URL
        var saveStateFolder: URL
        var snapshotFolder: URL
        /// Continue from the state ARMSX2 wrote when it was last quit.
        var resume: Bool
        var saveStateOnShutdown: Bool
        var fullscreen: Bool
        /// The game's controls as ARMSX2 bindings.
        var controls: ARMSX2Controls
        /// The installed version's save state format; states written by
        /// another one cannot be loaded, and none when it is unknown.
        var saveStateVersion: UInt32?
        /// A state to start from, chosen in the Save States browser.
        var stateFile: URL?
    }

    let executable: URL
    let arguments: [String]
    /// Ursprung's environment, with `TMPDIR` pointing at the PINE folder.
    let environment: [String: String]
    let config: PCSX2Config
    let logFile: URL
    /// The resume state the game continues from.
    let stateFile: URL?
    let pineSocket: URL
    /// The save state format the states were checked against.
    let saveStateVersion: UInt32?

    /// Checks the request, chooses the BIOS and writes `PCSX2.ini`.
    static func prepare(_ request: Request, environment base: [String: String]) throws -> ARMSX2Launch {
        let fileManager = FileManager.default
        if let game = request.game {
            guard let handle = try? FileHandle(forReadingFrom: game), (try? handle.read(upToCount: 1))?.count == 1 else {
                throw StandaloneLaunchError.gameUnreadable(name: game.lastPathComponent)
            }
            try? handle.close()
        }

        for folder in [request.memoryCardFolder, request.saveStateFolder, request.snapshotFolder,
                       request.dataFolder, request.pineFolder, request.logFile.deletingLastPathComponent()] {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            guard fileManager.isWritableFile(atPath: folder.path(percentEncoded: false)) else {
                throw StandaloneLaunchError.folderNotWritable(folder)
            }
        }
        let card = request.memoryCardFolder.appending(path: PCSX2Config.memoryCardFileName)
        if fileManager.fileExists(atPath: card.path(percentEncoded: false)),
           !fileManager.isWritableFile(atPath: card.path(percentEncoded: false)) || isLocked(card) {
            throw StandaloneLaunchError.memoryCardReadOnly(card)
        }

        let region = request.game.flatMap { game in
            PS2Disc.serial(of: game).flatMap(PS2Disc.region(ofSerial:)) ?? PS2Disc.region(ofFileName: game.lastPathComponent)
        } ?? request.fallbackRegion
        // The BIOS check before the launch makes sure there is a dump.
        let bios = PS2BIOS.preferred(in: request.dumps, region: region)

        let pineSlot = freePINESlot(in: request.pineFolder)
        let config = PCSX2Config(biosFolder: request.biosFolder, biosFileName: bios?.fileName ?? "",
                                 memoryCardFolder: request.memoryCardFolder, saveStateFolder: request.saveStateFolder,
                                 snapshotFolder: request.snapshotFolder, pineSlot: pineSlot,
                                 saveStateOnShutdown: request.saveStateOnShutdown, fullscreen: request.fullscreen,
                                 controls: request.controls)
        do {
            try config.write(dataFolder: request.dataFolder)
        } catch {
            throw StandaloneLaunchError.settingsNotWritten(reason: error.localizedDescription)
        }

        // A damaged or incompatible state would open a dialog. A chosen state
        // is refused; without a loadable resume state the game starts from
        // the beginning.
        let stateFile: URL?
        if request.game == nil {
            stateFile = nil
        } else if let chosen = request.stateFile {
            guard ARMSX2States.isLoadable(chosen, by: request.saveStateVersion) else {
                throw StandaloneLaunchError.stateNotLoadable
            }
            stateFile = chosen
        } else {
            stateFile = request.resume
                ? ARMSX2States.resumeState(in: request.saveStateFolder)
                    .flatMap { ARMSX2States.isLoadable($0, by: request.saveStateVersion) ? $0 : nil }
                : nil
        }

        try? fileManager.removeItem(at: request.logFile)
        var arguments = ["-datapath", request.dataFolder.path(percentEncoded: false)]
        if let game = request.game {
            arguments += ["-batch", "-nogui", "-logfile", request.logFile.path(percentEncoded: false),
                          request.fullscreen ? "-fullscreen" : "-nofullscreen"]
            if let stateFile { arguments += ["-statefile", stateFile.path(percentEncoded: false)] }
            arguments += ["--", game.path(percentEncoded: false)]
        } else {
            // Its main window, with the settings in its Settings menu; closing it quits ARMSX2.
            arguments += ["-logfile", request.logFile.path(percentEncoded: false)]
        }

        var environment = base
        environment["TMPDIR"] = request.pineFolder.path(percentEncoded: false)
        return ARMSX2Launch(executable: request.app.appending(path: request.executable), arguments: arguments,
                            environment: environment, config: config, logFile: request.logFile, stateFile: stateFile,
                            pineSocket: pineSocket(slot: pineSlot, in: request.pineFolder),
                            saveStateVersion: request.saveStateVersion)
    }

    /// A PINE folder of its own for every launch (ARMSX2 puts its socket in
    /// `TMPDIR`), so a request meant for one session can't reach the
    /// emulator of the next. Short: a socket path holds only 104 bytes.
    static func newPINEFolder(in temporary: URL) -> URL {
        temporary.appending(path: "Ursprung-PINE", directoryHint: .isDirectory)
            .appending(path: String(UUID().uuidString.prefix(8)), directoryHint: .isDirectory)
    }

    /// The default PINE slot unless a socket of an earlier run is still there.
    static func freePINESlot(in folder: URL) -> Int {
        let first = 28011
        return (first..<first + 100).first {
            !FileManager.default.fileExists(atPath: pineSocket(slot: $0, in: folder).path(percentEncoded: false))
        } ?? first
    }

    /// `pcsx2.sock` for the default slot, `pcsx2.sock.<slot>` otherwise.
    static func pineSocket(slot: Int, in folder: URL) -> URL {
        folder.appending(path: slot == 28011 ? "pcsx2.sock" : "pcsx2.sock.\(slot)")
    }

    private static func isLocked(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUserImmutableKey]))?.isUserImmutable == true
    }

    /// Why ARMSX2 stopped, from its log: `ReportErrorAsync: <message>` holds
    /// the error it showed (or tried to show) last.
    static func errorMessage(inLog log: String) -> String? {
        let marker = "ReportErrorAsync: "
        guard let line = log.split(whereSeparator: \.isNewline).last(where: { $0.contains(marker) }),
              let range = line.range(of: marker) else { return nil }
        let message = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return message.isEmpty ? nil : message
    }
}

/// What the disc tells about a PlayStation 2 game.
nonisolated enum PS2Disc {
    /// The serial from `SYSTEM.CNF` (`BOOT2 = cdrom0:\SLES_554.74;1` →
    /// `SLES-55474`), read from an ISO 9660 image with 2048 or 2352 byte
    /// sectors. Compressed images (CHD, CSO) give nil.
    static func serial(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Raw sectors begin with a sync pattern; their data follows the
        // header (mode 1) or the header and subheader (mode 2).
        guard let start = read(handle, at: 0, count: 16) else { return nil }
        let sync: [UInt8] = [0x00] + Array(repeating: 0xFF, count: 10) + [0x00]
        let layout: (size: UInt64, offset: UInt64) = Array(start.prefix(12)) == sync
            ? (2352, start[15] == 2 ? 24 : 16) : (2048, 0)
        func sector(_ lba: UInt64, count: Int = 2048) -> Data? {
            read(handle, at: lba * layout.size + layout.offset, count: count)
        }

        guard let descriptor = sector(16), descriptor.count == 2048, descriptor[0] == 1,
              String(decoding: descriptor[1..<6], as: UTF8.self) == "CD001" else { return nil }
        let root = descriptor.subdata(in: 156..<190)
        guard let file = findFile("SYSTEM.CNF", inDirectoryAt: UInt64(root.uint32(at: 2)), size: Int(root.uint32(at: 10)),
                                  sector: { sector($0) }),
              let contents = sector(file.lba, count: min(file.size, 2048)) else { return nil }
        return serial(fromSystemCNF: String(decoding: contents, as: UTF8.self))
    }

    static func serial(fromSystemCNF text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].uppercased() == "BOOT2" else { continue }
            // cdrom0:\SLES_554.74;1
            let path = parts[1].split(whereSeparator: { $0 == "\\" || $0 == ":" || $0 == "/" }).last ?? ""
            let name = path.split(separator: ";").first.map(String.init) ?? ""
            let letters = name.prefix(4)
            let digits = name.dropFirst(4).filter(\.isNumber)
            guard letters.count == 4, letters.allSatisfy(\.isLetter), digits.count == 5 else { return nil }
            return "\(letters.uppercased())-\(digits)"
        }
        return nil
    }

    /// The BIOS region a disc expects, from its serial's prefix.
    static func region(ofSerial serial: String) -> PS2BIOS.Region? {
        switch serial.prefix(4).uppercased() {
        case "SLES", "SCES", "SLED", "SCED": .europe
        case "SLUS", "SCUS", "SLUD", "SCUD": .usa
        case "SLPS", "SLPM", "SCPS", "SCPM", "PAPX", "PCPX": .japan
        case "SLAJ", "SCAJ", "SLKA", "SCKA": .asia
        case "SCCS": .china
        default: nil
        }
    }

    /// The region from a No-Intro or Redump file name, e.g. “(Europe)”.
    static func region(ofFileName name: String) -> PS2BIOS.Region? {
        for region in VariantInfo.parse(fileName: name).regions {
            switch region {
            case "Europe", "UK", "Germany", "France", "Spain", "Italy", "Australia", "Netherlands", "Sweden",
                 "Scandinavia", "Portugal", "Denmark", "Finland", "Norway", "Poland", "Greece", "Austria",
                 "Switzerland", "Belgium", "Russia":
                return .europe
            case "USA", "Canada", "Brazil": return .usa
            case "Japan": return .japan
            case "Asia", "Korea", "Taiwan", "Hong Kong": return .asia
            case "China": return .china
            default: continue
            }
        }
        return nil
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> Data? {
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: count),
              data.count == count else { return nil }
        return data
    }

    /// A file in an ISO 9660 directory (names end in `;1`).
    private static func findFile(_ name: String, inDirectoryAt lba: UInt64, size: Int,
                                 sector: (UInt64) -> Data?) -> (lba: UInt64, size: Int)? {
        let sectors = min((size + 2047) / 2048, 16)
        for index in 0..<sectors {
            guard let data = sector(lba + UInt64(index)) else { return nil }
            var offset = 0
            while offset + 33 <= data.count {
                let length = Int(data[offset])
                // Records never cross a sector; zero pads the rest of it.
                guard length >= 33, offset + length <= data.count else { break }
                let nameLength = Int(data[offset + 32])
                if offset + 33 + nameLength <= offset + length {
                    let recordName = String(decoding: data[(offset + 33)..<(offset + 33 + nameLength)], as: UTF8.self)
                    if recordName.split(separator: ";").first.map(String.init)?.uppercased() == name {
                        let record = data.subdata(in: offset..<(offset + length))
                        return (UInt64(record.uint32(at: 2)), Int(record.uint32(at: 10)))
                    }
                }
                offset += length
            }
        }
        return nil
    }
}

nonisolated extension PS2BIOS {
    /// The newest dump of `region`, else the newest of any region.
    static func preferred(in dumps: [PS2BIOS], region: Region) -> PS2BIOS? {
        func newest(_ candidates: [PS2BIOS]) -> PS2BIOS? {
            candidates.sorted { lhs, rhs in
                let order = lhs.version.compare(rhs.version, options: .numeric)
                return order == .orderedSame ? lhs.fileName < rhs.fileName : order == .orderedDescending
            }.first
        }
        return newest(dumps.filter { $0.region == region }) ?? newest(dumps)
    }
}
