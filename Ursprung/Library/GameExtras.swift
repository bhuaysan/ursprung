// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the user adds to a game besides its file: screenshots, a manual,
/// ROM patches and cheats. One folder per game, named after its library ID:
///
///     Extras/<game id>/
///       Screenshots/   PNG files taken while playing
///       Manual/        one file (usually a PDF)
///       Patches/       IPS, UPS and BPS files, and patches.json (the active one)
///       cheats.json
///
/// See docs/SAVES.md. Backups include the folder.
nonisolated enum GameExtras {
    static func directory(in extras: URL, gameID: UUID) -> URL {
        extras.appending(path: gameID.uuidString, directoryHint: .isDirectory)
    }

    /// Names a file of the folder may not use.
    static func sanitizedFileName(_ name: String) -> String {
        let cleaned = name.map { "/:\\".contains($0) ? "-" : $0 }
        let result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result.hasPrefix(".") ? "File" + result : result
    }

    /// `url`, or "name 2.ext", "name 3.ext" … when it exists.
    static func available(_ url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let directory = url.deletingLastPathComponent()
        for number in 2... {
            let candidate = directory.appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
        }
        return url
    }

    /// Copies `source` into `directory` under its own name (numbered if taken).
    static func copy(_ source: URL, into directory: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = available(directory.appending(path: sanitizedFileName(source.lastPathComponent)))
        try fileManager.copyItem(at: source, to: target)
        return target
    }
}

// MARK: - Screenshots

nonisolated enum ScreenshotStore {
    static func directory(in extras: URL, gameID: UUID) -> URL {
        GameExtras.directory(in: extras, gameID: gameID).appending(path: "Screenshots", directoryHint: .isDirectory)
    }

    /// The game's screenshots, newest first.
    static func screenshots(in extras: URL, gameID: UUID) -> [URL] {
        let directory = directory(in: extras, gameID: gameID)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey],
                                                                  options: .skipsHiddenFiles)) ?? []
        let screenshots: [(url: URL, date: Date)] = files.filter { $0.pathExtension.lowercased() == "png" }.map { url in
            (url, (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }
        return screenshots.sorted { first, second in
            first.date != second.date ? first.date > second.date : first.url.lastPathComponent > second.url.lastPathComponent
        }.map(\.url)
    }

    /// Where a screenshot taken at `date` goes, e.g. "2026-10-04 14.03.22.png".
    static func newURL(in extras: URL, gameID: UUID, date: Date = .now) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return GameExtras.available(directory(in: extras, gameID: gameID).appending(path: formatter.string(from: date) + ".png"))
    }

    /// The frame as the player shows it: stretched to the core's aspect
    /// ratio (consoles rarely have square pixels) and rotated upright.
    /// Pixels stay sharp; small frames are doubled.
    static func render(_ frame: CGImage, aspectRatio: Double, rotation: Int) -> CGImage? {
        let sourceWidth = Double(frame.width), sourceHeight = Double(frame.height)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let scale = sourceHeight < 300 ? 2.0 : 1.0
        let height = (sourceHeight * scale).rounded()
        let aspect = aspectRatio > 0 ? aspectRatio : sourceWidth / sourceHeight
        // The aspect ratio is the frame's, before rotation (as the player draws it).
        let quarterTurns = ((rotation % 4) + 4) % 4
        let width = (height * aspect).rounded()
        let canvas = quarterTurns % 2 == 1 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        guard let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.translateBy(x: canvas.width / 2, y: canvas.height / 2)
        context.rotate(by: Double(quarterTurns) * .pi / 2)
        context.draw(frame, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        return context.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

// MARK: - Manual

nonisolated enum ManualStore {
    static func directory(in extras: URL, gameID: UUID) -> URL {
        GameExtras.directory(in: extras, gameID: gameID).appending(path: "Manual", directoryHint: .isDirectory)
    }

    /// The game's manual, if the user added one.
    static func manual(in extras: URL, gameID: UUID) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(in: extras, gameID: gameID),
                                                                  includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }

    /// Makes a copy of `source` the game's manual, replacing the previous one.
    @discardableResult
    static func setManual(_ source: URL, in extras: URL, gameID: UUID) throws -> URL {
        let fileManager = FileManager.default
        let directory = directory(in: extras, gameID: gameID)
        let staging = extras.appending(path: ".manual-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        let copy = try GameExtras.copy(source, into: staging)
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: staging, to: directory)
        return directory.appending(path: copy.lastPathComponent)
    }

    static func removeManual(in extras: URL, gameID: UUID) throws {
        let directory = directory(in: extras, gameID: gameID)
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Patches

/// The ROM patches of a game and which one is applied when it starts.
nonisolated enum PatchStore {
    private struct Settings: Codable {
        /// File name of the patch to apply; nil plays the original.
        var active: String?
    }

    static func directory(in extras: URL, gameID: UUID) -> URL {
        GameExtras.directory(in: extras, gameID: gameID).appending(path: "Patches", directoryHint: .isDirectory)
    }

    private static func settingsURL(in extras: URL, gameID: UUID) -> URL {
        directory(in: extras, gameID: gameID).appending(path: "patches.json")
    }

    /// The patch files, by name.
    static func patches(in extras: URL, gameID: UUID) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(in: extras, gameID: gameID),
                                                                  includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return files.filter { ROMPatch.Format.fileExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Copies a patch file to the game. Throws for files that are not patches.
    @discardableResult
    static func add(_ source: URL, in extras: URL, gameID: UUID) throws -> URL {
        let data = try Data(contentsOf: source)
        guard ROMPatch.format(of: data) != nil else { throw ROMPatch.PatchError.unknownFormat }
        return try GameExtras.copy(source, into: directory(in: extras, gameID: gameID))
    }

    static func remove(_ patch: URL, in extras: URL, gameID: UUID) throws {
        if active(in: extras, gameID: gameID)?.lastPathComponent == patch.lastPathComponent {
            try setActive(nil, in: extras, gameID: gameID)
        }
        try FileManager.default.removeItem(at: patch)
    }

    /// The patch applied when the game starts, if it still exists.
    static func active(in extras: URL, gameID: UUID) -> URL? {
        guard let data = try? Data(contentsOf: settingsURL(in: extras, gameID: gameID)),
              let name = try? JSONDecoder().decode(Settings.self, from: data).active else { return nil }
        return patches(in: extras, gameID: gameID).first { $0.lastPathComponent == name }
    }

    static func setActive(_ patch: URL?, in extras: URL, gameID: UUID) throws {
        let url = settingsURL(in: extras, gameID: gameID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Settings(active: patch?.lastPathComponent)).write(to: url, options: .atomic)
    }

    /// The folder name that keeps a patched game's saves and states apart
    /// from the original's: a hack must never overwrite the original's progress.
    static func saveFolderName(for patch: URL) -> String {
        GameExtras.sanitizedFileName(patch.deletingPathExtension().lastPathComponent)
    }

    /// Writes `rom` patched with `patch` into `directory` (the cache) and
    /// returns the patched file, named like the ROM.
    static func patchedCopy(of rom: URL, with patch: URL, into directory: URL) throws -> URL {
        let patched = try ROMPatch.apply(Data(contentsOf: patch), to: Data(contentsOf: rom))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: rom.lastPathComponent)
        try patched.write(to: target, options: .atomic)
        return target
    }
}

// MARK: - Cheats

/// A cheat code for the running core, e.g. a Game Genie or Action Replay code.
nonisolated struct Cheat: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    /// One or more codes; several are joined with "+".
    var code: String
    var isEnabled: Bool
}

nonisolated enum CheatStore {
    static func url(in extras: URL, gameID: UUID) -> URL {
        GameExtras.directory(in: extras, gameID: gameID).appending(path: "cheats.json")
    }

    static func cheats(in extras: URL, gameID: UUID) -> [Cheat] {
        guard let data = try? Data(contentsOf: url(in: extras, gameID: gameID)) else { return [] }
        return (try? JSONDecoder().decode([Cheat].self, from: data)) ?? []
    }

    static func save(_ cheats: [Cheat], in extras: URL, gameID: UUID) throws {
        let url = url(in: extras, gameID: gameID)
        if cheats.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(cheats).write(to: url, options: .atomic)
    }

    /// Cheats of a RetroArch cheat file (.cht):
    ///
    ///     cheats = 2
    ///     cheat0_desc = "Infinite Lives"
    ///     cheat0_code = "7E0DBE:09"
    ///     cheat0_enable = false
    static func parseCHT(_ text: String) -> [Cheat] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            values[key] = value
        }
        let count = Int(values["cheats"] ?? "") ?? 0
        return (0..<min(count, 10_000)).compactMap { index in
            guard let code = values["cheat\(index)_code"], !code.isEmpty else { return nil }
            let name = values["cheat\(index)_desc"].flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Cheat \(index + 1)")
            return Cheat(name: name, code: code, isEnabled: values["cheat\(index)_enable"] == "true")
        }
    }
}
