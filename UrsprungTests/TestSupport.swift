// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A fresh directory below the system temp directory. Callers remove it with `defer`.
func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "UrsprungTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Creates `archive` with `/usr/bin/zip` from a single file named `name`.
func makeZip(at archive: URL, containing name: String, bytes: Data) throws {
    try makeZip(at: archive, files: [(name, bytes)])
}

/// Creates `archive` with `/usr/bin/zip` from `files`; `stored` keeps them uncompressed.
func makeZip(at archive: URL, files: [(name: String, bytes: Data)], stored: Bool = false) throws {
    let staging = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: staging) }
    for file in files { try file.bytes.write(to: staging.appending(path: file.name)) }
    try? FileManager.default.removeItem(at: archive)
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/zip")
    process.currentDirectoryURL = staging
    process.arguments = ["-q"] + (stored ? ["-0"] : []) + [archive.path(percentEncoded: false)] + files.map(\.name)
    try process.run()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0, "zip failed")
}
