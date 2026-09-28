// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

@Suite("ZIP archives")
struct ZipArchiveTests {
    @Test func listsAndExtractsDeflatedEntries() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "UrsprungZip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let source = directory.appending(path: "Sonic.md")
        try payload.write(to: source)

        let zip = directory.appending(path: "Sonic.zip")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", "-9", zip.path(percentEncoded: false), "Sonic.md"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let archive = try ZipArchive(url: zip)
        let entry = try #require(archive.files.first)
        #expect(entry.fileName == "Sonic.md")
        #expect(entry.uncompressedSize == UInt64(payload.count))
        #expect(entry.method == 8)
        #expect(entry.crc32 == (try Checksum.crc(of: source)))

        let output = directory.appending(path: "out/Sonic.md")
        try archive.extract(entry, to: output)
        #expect(try Data(contentsOf: output) == payload)
    }

    @Test func rejectsNonZipFiles() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "not-a-zip-\(UUID().uuidString).zip")
        try Data("hello world, definitely not a zip archive".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: ZipArchive.ZipError.self) { try ZipArchive(url: file) }
    }
}

@Suite("Checksums and secrets")
struct ChecksumTests {
    @Test func crc32MatchesKnownValue() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "crc-\(UUID().uuidString)")
        try Data("123456789".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(Checksum.hex(try Checksum.crc(of: file)) == "CBF43926")
    }

    @Test func secretsDecodeReversesObfuscation() {
        let plain = Array("dev-password!".utf8)
        let encoded = plain.enumerated().map { index, byte in byte ^ UInt8((0x5A + index * 31) & 0xFF) }
        #expect(Secrets.decode(encoded) == "dev-password!")
    }
}

@Suite("ScreenScraper parsing")
struct ScreenScraperParsingTests {
    let game: [String: Any] = [
        "id": "2144",
        "noms": [["region": "us", "text": "Super Mario World"],
                 ["region": "jp", "text": "Super Mario World : Super Mario Bros. 4"],
                 ["region": "de", "text": "Super Mario World (DE)"]],
        "synopsis": [["langue": "en", "text": "English synopsis"], ["langue": "de", "text": "Deutsche Beschreibung"]],
        "developpeur": ["id": "286", "text": "Nintendo"],
        "editeur": ["id": "286", "text": "Nintendo"],
        "joueurs": ["text": "1-2"],
        "note": ["text": "17"],
        "dates": [["region": "jp", "text": "1990-11-21"], ["region": "eu", "text": "1992-04-11"]],
        "genres": [["principale": "1", "noms": [["langue": "en", "text": "Platform"], ["langue": "de", "text": "Plattform"]]]],
        "medias": [
            ["type": "box-2D", "region": "us", "url": "https://example.invalid/box-us.png"],
            ["type": "box-2D", "region": "eu", "url": "https://example.invalid/box-eu.png"],
            ["type": "ss", "region": "wor", "url": "https://example.invalid/ss.png"],
            ["type": "wheel", "region": "wor", "url": "https://example.invalid/wheel.png"],
        ],
    ]

    @Test func prefersLanguageAndRegion() throws {
        var client = ScreenScraperClient(devID: "x", devPassword: "y")
        client.language = "de"
        client.region = "eu"
        let result = try #require(client.parse(game))
        #expect(result.title == "Super Mario World (DE)")
        #expect(result.overview == "Deutsche Beschreibung")
        #expect(result.genre == "Plattform")
        #expect(result.releaseDate == "1992-04-11")
        #expect(result.boxArt?.absoluteString == "https://example.invalid/box-eu.png")
        #expect(result.screenshot != nil)
        #expect(result.logo != nil)
        #expect(result.rating == 0.85)
    }

    @Test func fallsBackToEnglish() throws {
        var client = ScreenScraperClient(devID: "x", devPassword: "y")
        client.language = "en"
        client.region = "us"
        let result = try #require(client.parse(game))
        #expect(result.title == "Super Mario World")
        #expect(result.overview == "English synopsis")
        #expect(result.boxArt?.absoluteString == "https://example.invalid/box-us.png")
    }

    @Test func ignoresEmptyResults() {
        #expect(ScreenScraperClient(devID: "x", devPassword: "y").parse([:]) == nil)
        #expect(ScreenScraperClient(devID: "x", devPassword: "y").parse(["id": "0"]) == nil)
    }
}

@Suite("Input mapping")
struct InputMappingTests {
    @Test func standardMappingCoversEveryInput() {
        for input in RetroInput.allCases {
            #expect(KeyboardMapping.standard.bindings[input] != nil, "\(input) is unbound")
        }
        let codes = KeyboardMapping.standard.bindings.values.map(\.keyCode)
        #expect(Set(codes).count == codes.count, "Default keys must not overlap")
    }

    @Test func mappingRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(KeyboardMapping.standard)
        #expect(try JSONDecoder().decode(KeyboardMapping.self, from: data) == .standard)
    }
}
