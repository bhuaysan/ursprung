// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Lines the window's `.searchable` toolbar field up with the inspector column.
/// SwiftUI makes the field 325 pt wide whatever the columns (and ignores
/// `preferredWidthForSearchField`), so next to a 320 pt inspector it straddles
/// the column edge by a few points. While the inspector is shown, the field
/// starts just right of its edge, which then falls into the gap between the
/// field and the buttons. The field still shrinks when the toolbar runs out of room.
struct ToolbarSearchAlignment: NSViewRepresentable {
    func makeNSView(context: Context) -> AlignerView {
        AlignerView()
    }

    func updateNSView(_ view: AlignerView, context: Context) {}

    final class AlignerView: NSView {
        private static let constraintID = "ToolbarSearchAlignment"
        /// Half the toolbar's 8 pt gap between glass capsules, so the column edge sits in its middle.
        private static let edgeInset = 4.0
        /// Below this the field would be useless; leave it to the system.
        private static let minWidth = 120.0

        private var observers: [any NSObjectProtocol] = []
        /// The split view holding the inspector, once found.
        private weak var splitView: NSSplitView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard window != nil else { return }
            let center = NotificationCenter.default
            // SwiftUI recreates toolbar items when the toolbar content changes;
            // the new item is set up only after this notification.
            observers.append(center.addObserver(forName: NSToolbar.willAddItemNotification, object: nil,
                                                queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.align() }
            })
            // The inspector was shown, hidden or dragged, or the window resized.
            observers.append(center.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: nil,
                                                queue: .main) { [weak self] note in
                let sender = note.object.map { ObjectIdentifier($0 as AnyObject) }
                MainActor.assumeIsolated {
                    guard let self, sender == self.splitView.map(ObjectIdentifier.init) || self.splitView == nil
                    else { return }
                    self.align()
                }
            })
            // The toolbar may not be attached yet.
            DispatchQueue.main.async { [weak self] in self?.align() }
        }

        private func align() {
            guard let window, let toolbar = window.toolbar,
                  let field = toolbar.items.lazy.compactMap({ ($0 as? NSSearchToolbarItem)?.searchField }).first
            else { return }
            let constraint = field.constraints.first { $0.identifier == Self.constraintID } ?? {
                let constraint = field.widthAnchor.constraint(lessThanOrEqualToConstant: 0)
                constraint.identifier = Self.constraintID
                return constraint
            }()
            // The field keeps its trailing edge, so only its width moves its leading edge.
            let fieldFrame = field.convert(field.bounds, to: nil)
            if let edge = inspectorEdge(in: window), field.window != nil, fieldFrame.width > 0 {
                let width = fieldFrame.maxX - edge - Self.edgeInset
                constraint.constant = width
                constraint.isActive = width >= Self.minWidth
            } else {
                constraint.isActive = false
            }
        }

        /// The leading edge of the visible inspector column in window coordinates.
        private func inspectorEdge(in window: NSWindow) -> CGFloat? {
            if splitView?.window !== window { splitView = findInspectorSplitView(in: window) }
            guard let splitView, let controller = splitView.delegate as? NSSplitViewController,
                  let index = controller.splitViewItems.firstIndex(where: { $0.behavior == .inspector }),
                  !controller.splitViewItems[index].isCollapsed, index < splitView.arrangedSubviews.count
            else { return nil }
            let column = splitView.arrangedSubviews[index]
            return column.convert(column.bounds, to: nil).minX
        }

        private func findInspectorSplitView(in window: NSWindow) -> NSSplitView? {
            var stack = window.contentView.map { [$0] } ?? []
            while let view = stack.popLast() {
                if let splitView = view as? NSSplitView,
                   let controller = splitView.delegate as? NSSplitViewController,
                   controller.splitViewItems.contains(where: { $0.behavior == .inspector }) {
                    return splitView
                }
                stack.append(contentsOf: view.subviews)
            }
            return nil
        }
    }
}
