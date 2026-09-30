// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Which side columns the library window shows, so the grid keeps at least
/// `AppMetrics.contentMinWidth`. See docs/DESIGN_SPEC.md, section M.
///
/// - Passive resize: the inspector yields and comes back when there is room.
/// - Opening the inspector in a narrow window collapses the sidebar; closing
///   the inspector brings it back.
/// - The user's own choices are kept apart from the automatic state, so
///   automation never overwrites intent.
nonisolated struct ColumnLayout: Equatable {
    /// Below this window width, opening the inspector collapses the sidebar.
    static let narrowWindowWidth = 1000.0

    private(set) var prefersSidebar = true
    private(set) var prefersInspector = true
    private(set) var showsSidebar = true
    private(set) var showsInspector = true
    /// The sidebar made room for the inspector and returns when it closes.
    private(set) var sidebarCollapsedAutomatically = false

    private(set) var windowWidth = 0.0
    /// Last measured column widths; the user can drag both.
    private(set) var sidebarWidth = AppMetrics.sidebarWidth.ideal
    private(set) var inspectorWidth = AppMetrics.inspectorWidth.ideal

    /// The width left for the grid with the given columns visible.
    func contentWidth(sidebar: Bool, inspector: Bool) -> Double {
        windowWidth - (sidebar ? sidebarWidth : 0) - (inspector ? inspectorWidth : 0)
    }

    private func fits(sidebar: Bool, inspector: Bool) -> Bool {
        contentWidth(sidebar: sidebar, inspector: inspector) >= AppMetrics.contentMinWidth
    }

    /// The window was resized.
    mutating func resize(to width: Double) {
        windowWidth = width
        reconcile()
    }

    /// A visible column reported its width, for example after the user dragged it.
    mutating func measure(sidebar: Double? = nil, inspector: Double? = nil) {
        if let sidebar, sidebar > 0 { sidebarWidth = sidebar }
        if let inspector, inspector > 0 { inspectorWidth = inspector }
        reconcile()
    }

    /// The user showed or hid the inspector.
    mutating func setInspector(_ visible: Bool) {
        prefersInspector = visible
        showsInspector = visible
        if visible {
            if showsSidebar, windowWidth < Self.narrowWindowWidth || !fits(sidebar: true, inspector: true) {
                showsSidebar = false
                sidebarCollapsedAutomatically = true
            }
        } else if sidebarCollapsedAutomatically {
            restoreSidebar()
        }
    }

    /// The user showed or hid the sidebar.
    mutating func setSidebar(_ visible: Bool) {
        prefersSidebar = visible
        showsSidebar = visible
        sidebarCollapsedAutomatically = false
        reconcile()
    }

    private mutating func restoreSidebar() {
        showsSidebar = prefersSidebar
        sidebarCollapsedAutomatically = false
    }

    private mutating func reconcile() {
        guard windowWidth > 0 else { return }
        // The sidebar comes back once the window has room for everything.
        if sidebarCollapsedAutomatically, windowWidth >= Self.narrowWindowWidth,
           fits(sidebar: prefersSidebar, inspector: showsInspector) {
            restoreSidebar()
        }
        showsInspector = prefersInspector && fits(sidebar: showsSidebar, inspector: true)
        // Nothing left to make room for.
        if sidebarCollapsedAutomatically, !showsInspector {
            restoreSidebar()
        }
    }
}

/// Holds a `ColumnLayout` for the library window. Only visibility changes
/// are observed, so measuring widths on every resize frame does not
/// re-render the window.
@Observable
final class ColumnLayoutState {
    @ObservationIgnored private var layout = ColumnLayout()
    private(set) var showsSidebar = true
    private(set) var showsInspector = true

    func update(_ change: (inout ColumnLayout) -> Void) {
        change(&layout)
        if showsSidebar != layout.showsSidebar { showsSidebar = layout.showsSidebar }
        if showsInspector != layout.showsInspector { showsInspector = layout.showsInspector }
    }
}
