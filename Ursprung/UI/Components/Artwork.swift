// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ImageIO
import SwiftUI

/// Decodes and downsamples artwork off the main thread, with an in-memory cache.
nonisolated final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, CGImage>()

    init() {
        cache.countLimit = 600
    }

    func cached(_ url: URL, maxPixel: Int) -> CGImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    func load(_ url: URL, maxPixel: Int) -> CGImage? {
        if let image = cached(url, maxPixel: maxPixel) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        cache.setObject(image, forKey: key(url, maxPixel))
        return image
    }

    @concurrent
    func loadAsync(_ url: URL, maxPixel: Int) async -> CGImage? {
        load(url, maxPixel: maxPixel)
    }

    func invalidate() {
        cache.removeAllObjects()
    }

    private func key(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(url.path(percentEncoded: false))#\(maxPixel)" as NSString
    }
}

/// Displays a local image file, loading it asynchronously.
struct ArtworkImage<Placeholder: View>: View {
    let url: URL?
    var maxPixel: Int = 640
    var contentMode: ContentMode = .fit
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = ArtworkCache.shared.cached(url, maxPixel: maxPixel) {
                image = cached
                return
            }
            image = await ArtworkCache.shared.loadAsync(url, maxPixel: maxPixel)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Generated cover used until real box art is available.
struct PlaceholderCover: View {
    let title: String
    let system: GameSystem?

    var body: some View {
        let accent = Color(hex: system?.accent ?? 0x6E6E73)
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [accent.mix(with: .white, by: 0.12), accent.mix(with: .black, by: 0.45)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: system?.symbol ?? "gamecontroller")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.14))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(12)
            VStack(alignment: .leading, spacing: 4) {
                Text(system?.shortName ?? "")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.7))
                Text(title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .minimumScaleFactor(0.7)
            }
            .padding(14)
        }
    }
}
