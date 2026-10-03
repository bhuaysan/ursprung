// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// An .m3u disc playlist: the discs of a game in order, each optionally
/// labelled. Labels are written as `#EXTINF` lines, which cores skip as
/// comments and libretro's own playlist reader shows; RetroArch's
/// `Disc.cue|Label` form is read too.
nonisolated struct DiscPlaylist: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        /// As the playlist names it: usually relative to the playlist's folder.
        var path: String
        var label: String?
    }

    var entries: [Entry] = []

    static func parse(_ text: String) -> DiscPlaylist {
        var playlist = DiscPlaylist()
        var pendingLabel: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.uppercased().hasPrefix("#EXTINF:") {
                // “#EXTINF:<duration>,<title>”
                let title = line.firstIndex(of: ",").map { String(line[line.index(after: $0)...]) } ?? ""
                pendingLabel = title.trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("#") { continue }
            var path = line
            var label = pendingLabel
            if let bar = line.lastIndex(of: "|") {
                path = line[..<bar].trimmingCharacters(in: .whitespaces)
                let inline = line[line.index(after: bar)...].trimmingCharacters(in: .whitespaces)
                if !inline.isEmpty { label = inline }
            }
            playlist.entries.append(Entry(path: path, label: label?.isEmpty == true ? nil : label))
            pendingLabel = nil
        }
        return playlist
    }

    static func read(_ url: URL) -> DiscPlaylist? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return parse(text)
    }

    /// The playlist as written to disk. Without labels it is a plain list of
    /// discs, which every core reads.
    var text: String {
        let hasLabels = entries.contains { !($0.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var lines = hasLabels ? ["#EXTM3U"] : []
        for entry in entries {
            if let label = entry.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                lines.append("#EXTINF:0,\(label.replacingOccurrences(of: "\n", with: " "))")
            }
            lines.append(entry.path)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func write(to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// How a disc file is named in a playlist in `directory`: relative when
    /// the file is inside it, else absolute.
    static func reference(to file: URL, from directory: URL) -> String {
        let filePath = file.standardizedFileURL.path(percentEncoded: false)
        let directoryPath = directory.standardizedFileURL.path(percentEncoded: false)
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return filePath.hasPrefix(prefix) ? String(filePath.dropFirst(prefix.count)) : filePath
    }

    /// The file an entry points to.
    static func resolve(_ path: String, in directory: URL) -> URL {
        let path = path.replacingOccurrences(of: "\\", with: "/")
        return path.hasPrefix("/") ? URL(filePath: path) : directory.appending(path: path)
    }
}

/// Discs of one game that sit next to each other without a playlist:
/// “Game (USA) (Disc 1).cue”, “Game (USA) (Disc 2).cue”.
nonisolated enum DiscSets {
    /// The file name without its disc tag and extension (“Game (USA)”), or
    /// nil when the name has no disc tag.
    static func setName(of fileName: String) -> String? {
        let name = (fileName as NSString).deletingPathExtension
        var result = ""
        var group = ""
        var depth = 0
        var found = false
        for character in name {
            if character == "(" {
                if depth == 0 { group = "" }
                depth += 1
                group.append(character)
            } else if depth > 0 {
                group.append(character)
                if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        if VariantInfo.disc(in: String(group.dropFirst().dropLast())) != nil {
                            found = true
                        } else {
                            result += group
                        }
                    }
                }
            } else {
                result.append(character)
            }
        }
        guard found else { return nil }
        return result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Disc numbers missing from `numbers`: gaps, and discs after the last
    /// one when the names say how many there are (“Disc 1 of 3”).
    static func missingDiscs(_ numbers: [Int], declaredCount: Int?) -> [Int] {
        guard let highest = ([declaredCount ?? 0] + numbers).max(), highest > 0 else { return [] }
        let present = Set(numbers)
        return (1...highest).filter { !present.contains($0) }
    }
}

extension DiscSets {
    /// The loose discs `game` belongs to, in disc order: same system, same
    /// folder and the same name apart from the disc number. Just the game
    /// when it is not part of a set.
    static func set(containing game: Game, in games: [Game]) -> [Game] {
        guard let name = setName(of: game.fileName) else { return [game] }
        let folder = game.fileURL.deletingLastPathComponent()
        let discs = games.filter { other in
            guard other.systemID == game.systemID, setName(of: other.fileName) == name else { return false }
            return other.fileURL.deletingLastPathComponent() == folder
        }
        // One file per disc: a second file of the same disc is another version, not a disc.
        var byNumber: [Int: Game] = [:]
        for disc in discs {
            guard let number = disc.variantInfo.disc else { continue }
            if byNumber[number] == nil || disc === game { byNumber[number] = disc }
        }
        let sorted = byNumber.keys.sorted().compactMap { byNumber[$0] }
        return sorted.count > 1 ? sorted : [game]
    }
}
