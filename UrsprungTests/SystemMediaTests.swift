// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import Testing
@testable import Ursprung

@Suite("System media")
struct SystemMediaTests {
    @Test func picksLogoAndPhotoInThePreferredRegion() {
        var client = ScreenScraperClient()
        client.region = "us"
        let json: [String: Any] = ["response": ["systemes": [
            ["id": 1, "medias": [
                ["type": "wheel", "region": "us", "url": "https://example.com/wheel"],
                ["type": "logo-monochrome", "region": "wor", "url": "https://example.com/wor"],
                ["type": "logo-monochrome", "region": "us", "url": "https://example.com/us"],
                ["type": "photo", "region": "wor", "url": "https://example.com/photo"],
            ]],
            ["id": "3", "medias": [["type": "logo-monochrome", "region": "jp", "url": "https://example.com/jp"]]],
            ["id": 4, "medias": [["type": "wheel", "region": "wor", "url": "https://example.com/wheel"]]],
        ]]]
        let media = client.parseSystemMedia(json)
        #expect(media[1]?.logo?.lastPathComponent == "us")
        #expect(media[1]?.photo?.lastPathComponent == "photo")
        #expect(media[3]?.logo?.lastPathComponent == "jp")
        #expect(media[3]?.photo == nil)
        #expect(media[4]?.logo == nil)
    }

    @Test func readsDownloadedFilesByKind() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["snes-logo.png", "snes-photo.png", "n64-photo.png", "gb.png", "notes.txt"] {
            try Data([0]).write(to: directory.appending(path: name))
        }
        let store = SystemMediaStore(directory: directory)
        #expect(store.logo(for: SystemCatalog.system(withID: "snes"))?.lastPathComponent == "snes-logo.png")
        #expect(store.photo(for: SystemCatalog.system(withID: "snes"))?.lastPathComponent == "snes-photo.png")
        #expect(store.logo(for: SystemCatalog.system(withID: "n64")) == nil)
        #expect(store.photo(for: SystemCatalog.system(withID: "n64")) != nil)
        #expect(store.logo(for: SystemCatalog.system(withID: "gb")) == nil)
    }

    @Test func findsTheVisibleBoundsOfAPaddedImage() throws {
        let context = try #require(CGContext(data: nil, width: 60, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        // Core Graphics draws bottom-up: y 5...9 is rows 20...24 from the top.
        context.fill(CGRect(x: 10, y: 5, width: 30, height: 5))
        let image = try #require(context.makeImage())
        #expect(SystemMediaStore.opaqueBounds(of: image) == CGRect(x: 10, y: 20, width: 30, height: 5))
    }

    @Test func fullyTransparentImagesHaveNoBounds() throws {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        #expect(SystemMediaStore.opaqueBounds(of: image) == nil)
    }
}
