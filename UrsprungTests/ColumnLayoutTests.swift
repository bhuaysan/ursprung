// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import Ursprung

/// Default column widths: sidebar 220, inspector 320, content at least 440.
@Suite("Library column layout")
struct ColumnLayoutTests {
    private func layout(width: Double) -> ColumnLayout {
        var layout = ColumnLayout()
        layout.resize(to: width)
        return layout
    }

    @Test func wideWindowShowsEverything() {
        let layout = layout(width: 1240)
        #expect(layout.showsSidebar)
        #expect(layout.showsInspector)
    }

    @Test func narrowWindowHidesTheInspectorByDefault() {
        let layout = layout(width: 900)
        #expect(layout.showsSidebar)
        #expect(!layout.showsInspector)
        #expect(layout.prefersInspector)
    }

    @Test func inspectorYieldsOnResizeAndComesBack() {
        var layout = layout(width: 1240)
        layout.resize(to: 979) // 979 − 220 − 320 = 439
        #expect(!layout.showsInspector)
        #expect(layout.showsSidebar)
        layout.resize(to: 980)
        #expect(layout.showsInspector)
    }

    @Test func closedInspectorStaysClosedWhenTheWindowGrows() {
        var layout = layout(width: 1240)
        layout.setInspector(false)
        layout.resize(to: 1600)
        #expect(!layout.showsInspector)
    }

    @Test func openingTheInspectorInANarrowWindowCollapsesTheSidebar() {
        var layout = layout(width: 900)
        layout.setInspector(true)
        #expect(layout.showsInspector)
        #expect(!layout.showsSidebar)
        #expect(layout.prefersSidebar)

        layout.resize(to: 880)
        #expect(layout.showsInspector)
        #expect(!layout.showsSidebar)

        layout.setInspector(false)
        #expect(layout.showsSidebar)
        #expect(!layout.sidebarCollapsedAutomatically)
    }

    @Test func automaticallyCollapsedSidebarReturnsInAWideWindow() {
        var layout = layout(width: 900)
        layout.setInspector(true)
        layout.resize(to: 1100)
        #expect(layout.showsSidebar)
        #expect(layout.showsInspector)
    }

    @Test func userHiddenSidebarIsNotRestoredByTheInspector() {
        var layout = layout(width: 900)
        layout.setSidebar(false)
        layout.setInspector(true)
        #expect(!layout.sidebarCollapsedAutomatically)
        layout.setInspector(false)
        #expect(!layout.showsSidebar)
    }

    @Test func showingTheSidebarInANarrowWindowHidesTheInspectorUntilThereIsRoom() {
        var layout = layout(width: 900)
        layout.setInspector(true)
        layout.setSidebar(true)
        #expect(layout.showsSidebar)
        #expect(!layout.showsInspector)
        #expect(layout.prefersInspector)

        layout.setSidebar(false)
        #expect(layout.showsInspector)
    }

    @Test func measuringAWiderInspectorHidesIt() {
        var layout = layout(width: 1000)
        #expect(layout.showsInspector) // 1000 − 220 − 320 = 460
        layout.measure(sidebar: 230, inspector: 357)
        #expect(!layout.showsInspector)
        #expect(layout.prefersInspector)
    }

    @Test func measuredWidthsAreClampedToTheColumnsRange() {
        var layout = layout(width: 1240)
        layout.measure(sidebar: 144, inspector: 270)
        #expect(layout.sidebarWidth == 200)
        #expect(layout.inspectorWidth == 280)
        layout.measure(sidebar: 500, inspector: 500)
        #expect(layout.sidebarWidth == 280)
        #expect(layout.inspectorWidth == 400)
        layout.measure(sidebar: 0)
        #expect(layout.sidebarWidth == 280)
    }

    @Test func measuringNeverShowsAHiddenInspector() {
        // At launch in a 950 pt window AppKit briefly reports a 144 pt sidebar,
        // which would make room for the inspector.
        var layout = layout(width: 950)
        #expect(!layout.showsInspector)
        layout.measure(sidebar: 144, inspector: 270) // 950 − 200 − 280 = 470
        #expect(!layout.showsInspector)
        #expect(layout.prefersInspector)
        // A real resize still brings it back.
        layout.resize(to: 951)
        #expect(layout.showsInspector)
    }

    @Test func wideColumnsCollapseTheSidebarAboveTheNarrowBand() {
        var layout = layout(width: 1060)
        layout.setInspector(false)
        layout.measure(sidebar: 280, inspector: 400)
        layout.setInspector(true) // 1060 − 280 − 400 = 380
        #expect(!layout.showsSidebar)
        #expect(layout.showsInspector)
    }
}
