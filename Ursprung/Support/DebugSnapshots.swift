// SPDX-License-Identifier: GPL-3.0-or-later

#if DEBUG
import AppKit

/// Development aid: when `URSPRUNG_SNAPSHOT_DIR` is set, all windows are
/// written to that directory as PNG every two seconds. Handy for reviewing UI
/// changes from scripts without screen recording permissions.
enum DebugSnapshots {
    static func startIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["URSPRUNG_SNAPSHOT_DIR"] else { return }
        let directory = URL(filePath: path, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                    guard let view = window.contentView?.superview ?? window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let name = window.identifier?.rawValue.replacingOccurrences(of: "/", with: "_") ?? "window\(index)"
                    try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
                    // Layer rendering also captures layer-hosted content (sidebar lists, Metal).
                    if let layer = view.layer, let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide,
                        pixelsHigh: rep.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                       let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                        let cg = context.cgContext
                        cg.scaleBy(x: CGFloat(rep.pixelsWide) / view.bounds.width, y: CGFloat(rep.pixelsHigh) / view.bounds.height)
                        layer.render(in: cg)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name)-layer.png"))
                    }
                }
            }
        }
    }
}
#endif
