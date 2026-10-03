// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Combines files without losing any: used when saves of two library entries
/// come together and when a backup is restored over existing data.
nonisolated enum FileMerge {
    struct Report: Sendable, Equatable {
        /// Files that had no counterpart at the destination.
        var added = 0
        /// Files whose counterpart had the same contents.
        var identical = 0
        /// Files that differed from their counterpart. The newer one is in
        /// place; the older one is kept next to it under a labelled name.
        var conflicts = 0

        static func + (lhs: Report, rhs: Report) -> Report {
            Report(added: lhs.added + rhs.added, identical: lhs.identical + rhs.identical,
                   conflicts: lhs.conflicts + rhs.conflicts)
        }
    }

    /// Names for the older file of a conflict, e.g. "before restore
    /// 2026-10-03 14.22" for the file that was there and "from backup …" for
    /// the incoming one.
    struct Labels: Sendable {
        let existing: String
        let incoming: String
    }

    /// Puts `source` at `destination`. Nothing that exists is overwritten:
    /// identical contents are left alone; otherwise the newer file (by
    /// modification date) ends up at `destination` and the older one next to
    /// it as "<name> (<label>).<extension>".
    static func place(_ source: URL, at destination: URL, moving: Bool, labels: Labels) throws -> Report {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let transfer = { (from: URL, to: URL) throws in
            if moving { try fileManager.moveItem(at: from, to: to) } else { try fileManager.copyItem(at: from, to: to) }
        }
        guard fileManager.fileExists(atPath: destination.path(percentEncoded: false)) else {
            try transfer(source, destination)
            return Report(added: 1)
        }
        if fileManager.contentsEqual(atPath: source.path(percentEncoded: false), andPath: destination.path(percentEncoded: false)) {
            if moving { try fileManager.removeItem(at: source) }
            return Report(identical: 1)
        }
        if modificationDate(of: source) > modificationDate(of: destination) {
            // The incoming file is newer: the existing one steps aside first.
            try fileManager.moveItem(at: destination, to: available(destination, label: labels.existing))
            try transfer(source, destination)
        } else {
            try transfer(source, available(destination, label: labels.incoming))
        }
        return Report(conflicts: 1)
    }

    /// Places every file below `source` at the same relative path below
    /// `destination`. `mapComponent` can rewrite path components, e.g. to
    /// give a game's folder its new ID.
    static func mergeDirectory(_ source: URL, into destination: URL, moving: Bool, labels: Labels,
                               mapComponent: (String) -> String = { $0 }) throws -> Report {
        var report = Report()
        for (file, components) in files(below: source) {
            var target = destination
            for component in components { target = target.appending(path: mapComponent(component)) }
            report = report + (try place(file, at: target, moving: moving, labels: labels))
        }
        if moving { removeEmptyDirectories(in: source) }
        return report
    }

    /// Regular files below `directory` with their path components relative to it.
    static func files(below directory: URL) -> [(url: URL, components: [String])] {
        let base = directory.standardizedFileURL.pathComponents
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: [(URL, [String])] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let components = Array(url.standardizedFileURL.pathComponents.dropFirst(base.count))
            files.append((url, components))
        }
        return files.sorted { $0.1.joined(separator: "/") < $1.1.joined(separator: "/") }
    }

    /// A label with the current date and time for `Labels`.
    static func stamp(_ date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }

    /// Whether `url` is the older file of a conflict, kept under a labelled
    /// name. Recognised by the date and time `stamp()` puts into every label.
    static func isLabelledCopy(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent
            .contains(#/ \([^()]*\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}( \d+)?\)$/#)
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// "<name> (<label>).<ext>", numbered if that is taken too.
    static func available(_ url: URL, label: String) -> URL {
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var attempt = 1
        while true {
            let suffix = attempt == 1 ? label : "\(label) \(attempt)"
            let name = ext.isEmpty ? "\(stem) (\(suffix))" : "\(stem) (\(suffix)).\(ext)"
            let candidate = directory.appending(path: name)
            if !FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
            attempt += 1
        }
    }

    private static func removeEmptyDirectories(in directory: URL) {
        let fileManager = FileManager.default
        let children = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            removeEmptyDirectories(in: child)
        }
        let remaining = (try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        // .DS_Store alone does not keep a folder.
        if remaining.allSatisfy({ $0 == ".DS_Store" }) { try? fileManager.removeItem(at: directory) }
    }
}
