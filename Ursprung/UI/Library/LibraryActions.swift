// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Library-wide commands. The toolbar, the File menu and the activity footer
/// all use these, so labels and behaviour match. See docs/DESIGN_SPEC.md, section D.
struct LibraryActions {
    let isScanning: Bool
    let addFolder: () -> Void
    let rescan: () -> Void
    /// Metadata for games without it, plus missing system logos and photos.
    let fetchMissingMetadata: () -> Void
    /// Asks for confirmation first: refetching overwrites existing metadata.
    let requestRefetchAllMetadata: () -> Void
    /// Settings › General, where the library folders are managed.
    let showLibraryFolders: () -> Void
}

extension FocusedValues {
    /// Published by the library window for the File menu.
    @Entry var libraryActions: LibraryActions?
}

/// The library commands, in one fixed order.
struct LibraryActionItems: View {
    enum Placement {
        /// The toolbar's Library Actions menu; Add Folder is the button next to it.
        case toolbar
        /// The File menu: the only place that registers shortcuts.
        case menuBar
    }

    /// `nil` while no library window is key; the menu bar then shows the items disabled.
    let actions: LibraryActions?
    let placement: Placement

    var body: some View {
        Group {
            if placement == .menuBar {
                Button("Add Folder to Library…") { actions?.addFolder() }
                    .keyboardShortcut("o")
            }
            Button("Rescan Library", systemImage: "arrow.clockwise") { actions?.rescan() }
                .keyboardShortcut(placement == .menuBar ? KeyboardShortcut("r", modifiers: [.command, .shift]) : nil)
                .disabled(actions?.isScanning ?? false)
            Divider()
            Button("Fetch Missing Metadata", systemImage: "sparkles") { actions?.fetchMissingMetadata() }
            Button("Refetch All Metadata…", systemImage: "arrow.triangle.2.circlepath") {
                actions?.requestRefetchAllMetadata()
            }
            Divider()
            Button("Library Folders…", systemImage: "folder") { actions?.showLibraryFolders() }
        }
        .disabled(actions == nil)
    }
}

/// Sort order for the grid, in the toolbar's View Options and the View menu.
struct LibrarySortPicker: View {
    /// The Recently Played filter always sorts by date; the picker then shows
    /// that order, disabled.
    let isFixedToRecentlyPlayed: Bool

    @AppStorage(PrefKey.librarySort) private var sort: LibrarySort = .title

    var body: some View {
        Picker("Sort By", selection: isFixedToRecentlyPlayed ? .constant(.recentlyPlayed) : $sort) {
            ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
        }
        .disabled(isFixedToRecentlyPlayed)
    }
}

extension FocusedValues {
    /// Whether the library window shows Recently Played, for the View menu's sort picker.
    @Entry var isShowingRecentlyPlayed: Bool?
}

/// Show/Hide Inspector in the View menu. Replaces SwiftUI's InspectorCommands,
/// whose German title reads “Informationen Hide” on macOS 27.
struct InspectorToggle {
    let isShown: Bool
    let toggle: () -> Void
}

extension FocusedValues {
    /// Published by the library window for the View menu.
    @Entry var inspectorToggle: InspectorToggle?
}
