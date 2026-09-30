// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Official system logos and console photos from ScreenScraper, downloaded
/// into Application Support on first use (`<id>-logo.png`, `<id>-photo.png`).
/// They are the manufacturers' trademarks and are therefore never bundled;
/// until a logo is available the self-drawn `system.<id>` symbol is shown.
@Observable
final class SystemMediaStore {
    enum Kind: String, CaseIterable, Sendable {
        case logo, photo

        var maxWidth: Int { self == .logo ? 600 : 800 }
    }

    /// Downloaded files by kind and system ID.
    private(set) var files: [Kind: [String: URL]] = [:]

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var attempted: Set<String> = []
    @ObservationIgnored private var isFetching = false

    init(directory: URL = AppPaths.systemMedia) {
        self.directory = directory
        let existing = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in existing where file.pathExtension == "png" {
            let name = file.deletingPathExtension().lastPathComponent
            guard let dash = name.lastIndex(of: "-"), let kind = Kind(rawValue: String(name[name.index(after: dash)...])) else {
                continue
            }
            files[kind, default: [:]][String(name[..<dash])] = file
        }
    }

    func logo(for system: GameSystem?) -> URL? {
        system.flatMap { files[.logo]?[$0.id] }
    }

    func photo(for system: GameSystem?) -> URL? {
        system.flatMap { files[.photo]?[$0.id] }
    }

    /// Downloads the missing media of `systems`. Each system is tried once per
    /// launch unless `retry` is set; failures keep the fallbacks.
    func fetchMissing(for systems: [GameSystem], retry: Bool = false, client: ScreenScraperClient = .configured) async {
        if retry { attempted.removeAll() }
        let missing = systems.filter { system in
            !attempted.contains(system.id) && Self.kinds(for: system).contains { files[$0]?[system.id] == nil }
        }
        guard !missing.isEmpty, !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        attempted.formUnion(missing.map(\.id))

        guard let sources = try? await client.systemMedia() else { return }
        for system in missing {
            for kind in Self.kinds(for: system) where files[kind]?[system.id] == nil {
                let media = sources[system.screenScraperID]
                guard let source = kind == .logo ? media?.logo : media?.photo else { continue }
                let destination = directory.appending(path: "\(system.id)-\(kind.rawValue).png")
                do {
                    try await client.download(source, to: destination, maxWidth: kind.maxWidth)
                    await Self.trimTransparentEdges(of: destination)
                    files[kind, default: [:]][system.id] = destination
                } catch {
                    // Missing system media is not worth an error message.
                }
            }
        }
    }

    /// ScreenScraper's arcade entry shows MAME's logo, which would misrepresent
    /// FinalBurn Neo; the arcade cabinet photo is fine.
    private static func kinds(for system: GameSystem) -> [Kind] {
        system.kind == .arcade ? [.photo] : Kind.allCases
    }

    /// ScreenScraper centres media on a fixed canvas; crop them to their
    /// visible pixels so they align and scale predictably.
    @concurrent
    nonisolated static func trimTransparentEdges(of url: URL) async {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let bounds = opaqueBounds(of: image),
              bounds.width < CGFloat(image.width) || bounds.height < CGFloat(image.height),
              let cropped = image.cropping(to: bounds),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, cropped, nil)
        CGImageDestinationFinalize(destination)
    }

    /// Bounding box (top-left origin) of the pixels that are not almost transparent.
    nonisolated static func opaqueBounds(of image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        var alpha = [UInt8](repeating: 0, count: width * height)
        let drawn = alpha.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where alpha[row + x] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
