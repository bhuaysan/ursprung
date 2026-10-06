// SPDX-License-Identifier: GPL-3.0-or-later

import ImageIO
import SwiftUI

/// The console itself as an icon, like Finder's device icons; the flat
/// identity dot until its photo has been downloaded. Decorative: a label
/// next to it always names the system.
struct SystemIcon: View {
    let system: GameSystem
    /// Next to running text the icon takes its own width; in the sidebar every
    /// icon takes the whole slot, so the labels line up.
    var isInline = false
    @Environment(SystemMediaStore.self) private var systemMedia

    /// The largest icon; sidebar rows reserve all of it.
    private static let slot = CGSize(width: 28, height: 20)
    /// Photos range from a tall Game Boy to a wide SNES with its controller;
    /// giving each the same area, within the slot, makes them look equally big.
    private static let area: CGFloat = 380
    /// Width / height of each photo, read from its header once.
    private static var aspects: [URL: CGFloat] = [:]

    var body: some View {
        let photo = systemMedia.photo(for: system)
        // Without a photo the dot stands alone; inline it needs no more room than itself.
        let size = photo.flatMap(Self.aspect(of:)).map(Self.size(forAspect:))
            ?? (isInline ? CGSize(width: 8, height: 8) : Self.slot)
        ArtworkImage(url: photo, maxPixel: 96) {
            Circle()
                .fill(system.identityColor)
                // Keeps near-white and near-black systems visible on the sidebar material.
                .strokeBorder(.separator, lineWidth: 0.5)
                .frame(width: 8, height: 8)
        }
        .frame(width: size.width, height: size.height)
        .frame(width: isInline ? size.width : Self.slot.width, height: Self.slot.height)
        .accessibilityHidden(true)
    }

    static func size(forAspect aspect: CGFloat) -> CGSize {
        var width = (area * aspect).squareRoot()
        var height = width / aspect
        if width > slot.width {
            width = slot.width
            height = width / aspect
        }
        if height > slot.height {
            height = slot.height
            width = height * aspect
        }
        return CGSize(width: width, height: height)
    }

    private static func aspect(of url: URL) -> CGFloat? {
        if let aspect = aspects[url] { return aspect }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, height > 0 else { return nil }
        aspects[url] = width / height
        return width / height
    }
}
