// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Reports the width of the hosting window. Measuring a SwiftUI view is not
/// enough: while the inspector animates in, the split view is briefly laid
/// out wider than the window.
struct WindowWidthReader: NSViewRepresentable {
    let onChange: (Double) -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(onChange: onChange)
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: (Double) -> Void
        private var observer: (any NSObjectProtocol)?

        init(onChange: @escaping (Double) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                                              object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            if let window { onChange(window.frame.width) }
        }
    }
}
