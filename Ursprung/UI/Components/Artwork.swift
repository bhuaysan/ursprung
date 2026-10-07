// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ImageIO
import SwiftUI

/// Decodes and downsamples artwork off the main thread, with an in-memory cache.
nonisolated final class ArtworkCache: @unchecked Sendable {
    /// One version of an image file. Artwork and save state thumbnails are
    /// replaced at the same path, so the modification date tells them apart.
    nonisolated struct Version: Hashable, Sendable {
        let url: URL
        let modified: Date?

        init(_ url: URL) {
            self.url = url
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
            modified = attributes?[.modificationDate] as? Date
        }
    }

    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, CGImage>()

    init() {
        cache.countLimit = 600
    }

    func cached(_ version: Version, maxPixel: Int) -> CGImage? {
        cache.object(forKey: key(version, maxPixel))
    }

    func load(_ version: Version, maxPixel: Int) -> CGImage? {
        if let image = cached(version, maxPixel: maxPixel) { return image }
        // ARMSX2's save states carry their thumbnail inside.
        let source = version.url.pathExtension.lowercased() == ARMSX2States.fileExtension
            ? ARMSX2States.screenshot(of: version.url).flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
            : CGImageSourceCreateWithURL(version.url as CFURL, nil)
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        cache.setObject(image, forKey: key(version, maxPixel))
        return image
    }

    @concurrent
    func loadAsync(_ version: Version, maxPixel: Int) async -> CGImage? {
        load(version, maxPixel: maxPixel)
    }

    private func key(_ version: Version, _ maxPixel: Int) -> NSString {
        let modified = version.modified?.timeIntervalSinceReferenceDate ?? 0
        return "\(version.url.path(percentEncoded: false))#\(maxPixel)#\(modified)" as NSString
    }
}

/// Displays a local image file, loading it asynchronously.
struct ArtworkImage<Placeholder: View>: View {
    let url: URL?
    var maxPixel: Int = 640
    var contentMode: ContentMode = .fit
    /// Renders only the alpha channel in the foreground style (for monochrome logos).
    var isTemplate = false
    /// Fades the image in when it had to be loaded from disk (not with Reduce Motion).
    var fadesIn = false
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: CGImage?

    var body: some View {
        // Read on every update, so a file replaced at the same URL (refetched
        // artwork, an overwritten save state) loads again.
        let version = url.map(ArtworkCache.Version.init)
        // A ZStack rather than a Group: with an EmptyView placeholder a Group
        // produces no view, so the loading task below would never start.
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .renderingMode(isTemplate ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                placeholder()
            }
        }
        .task(id: version) {
            guard let version else { image = nil; return }
            if let cached = ArtworkCache.shared.cached(version, maxPixel: maxPixel) {
                image = cached
                return
            }
            // The view stays when the URL changes (the inspector on a new
            // selection): without this the previous game's art shows until
            // the new one has loaded.
            image = nil
            let loaded = await ArtworkCache.shared.loadAsync(version, maxPixel: maxPixel)
            // 0.15 s, the same short fade Reduce Motion uses elsewhere.
            withAnimation(fadesIn && !reduceMotion ? AppAnimation.reduced : nil) { image = loaded }
        }
    }
}

extension View {
    /// Rounded artwork with a hairline edge that stays visible on light and
    /// dark art alike: grid covers and the inspector's box art.
    func artworkFrame(radius: CGFloat) -> some View {
        modifier(ArtworkFrame(radius: radius))
    }
}

private struct ArtworkFrame: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let isHighContrast = contrast == .increased
        content
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(.primary.opacity(isHighContrast ? 0.25 : 0.10), lineWidth: isHighContrast ? 1 : 0.5)
            }
    }
}

extension Color {
    nonisolated init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension LinearGradient {
    /// Diagonal backdrop in a system's accent colour.
    static func system(accent: UInt32) -> LinearGradient {
        let color = Color(hex: accent)
        return LinearGradient(colors: [color.mix(with: .white, by: 0.12), color.mix(with: .black, by: 0.45)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Generated cover used until real box art is available.
struct PlaceholderCover: View {
    let title: String
    let system: GameSystem?
    @Environment(SystemMediaStore.self) private var systemMedia

    /// A nearly flat fill, two stops 8 % apart, so a system without covers
    /// reads as one calm block. Darkened for the white title.
    private var fill: LinearGradient {
        let color = Color(hex: system?.accent ?? 0x6E6E73)
        return LinearGradient(colors: [color.mix(with: .black, by: 0.18), color.mix(with: .black, by: 0.26)],
                              startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        let logo = systemMedia.logo(for: system)
        // Logo on top, title at the bottom, in one column so they never
        // overlap: the inspector shows this cover at 96 pt wide.
        GeometryReader { geometry in
            let padding = min(14, geometry.size.width * 0.1)
            VStack(alignment: .leading, spacing: 4) {
                if let logo {
                    ArtworkImage(url: logo, maxPixel: 600, isTemplate: true) { EmptyView() }
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, maxHeight: min(44, geometry.size.height * 0.22), alignment: .leading)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    Text(system?.shortName ?? "")
                        .font(.caption.weight(.semibold))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Text(title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .minimumScaleFactor(0.6)
            }
            .padding(padding)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .background(fill)
    }
}
