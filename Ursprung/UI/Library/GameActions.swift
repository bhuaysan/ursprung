// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Everything the user can do with one game. The grid's context menu, the
/// inspector, the Game menu and VoiceOver all build their items from this,
/// so labels, symbols and order match everywhere.
struct GameActions {
    let game: Game
    let play: () -> Void
    let toggleFavorite: () -> Void
    let refetchMetadata: () -> Void
    let showInFinder: () -> Void
    /// `nil` selects the system's default core.
    let setCore: (String?) -> Void
    /// Asks for confirmation before the game leaves the library.
    let requestRemoval: () -> Void

    var favoriteTitle: LocalizedStringKey {
        game.isFavorite ? "Remove from Favorites" : "Add to Favorites"
    }

    var favoriteSymbol: String {
        game.isFavorite ? "heart.slash" : "heart"
    }
}

extension FocusedValues {
    /// The selected game's actions, published by the library window for the Game menu.
    @Entry var gameActions: GameActions?
    /// Set while the grid has keyboard focus. Only then does the Game menu give
    /// Remove from Library ⌘⌫, so the search field keeps ⌘⌫ for its text.
    @Entry var isGridFocused: Bool?
}

/// The menu items for one game, in one fixed order.
struct GameActionItems: View {
    enum Placement {
        /// Grid context menu: everything, including the core submenu.
        case contextMenu
        /// Inspector overflow menu: Play and Favorite are buttons next to it.
        case inspectorMenu
        /// Game menu in the menu bar: the only place that registers shortcuts.
        case menuBar
    }

    let actions: GameActions
    let placement: Placement
    /// Menu bar only: registers ⌘⌫ for Remove from Library.
    var removesWithDeleteKey = false

    var body: some View {
        if placement != .inspectorMenu {
            Button("Play", systemImage: "play.fill", action: actions.play)
            Button(actions.favoriteTitle, systemImage: actions.favoriteSymbol, action: actions.toggleFavorite)
                .keyboardShortcut(shortcut("d"))
            Divider()
        }
        Button("Refetch Metadata", systemImage: "arrow.triangle.2.circlepath", action: actions.refetchMetadata)
        Button("Show in Finder", systemImage: "folder", action: actions.showInFinder)
            .keyboardShortcut(shortcut("r"))
        if placement == .contextMenu, (actions.game.system?.cores.count ?? 0) > 1 {
            GameCorePicker(actions: actions)
                .pickerStyle(.menu)
        }
        Divider()
        Button("Remove from Library…", systemImage: "trash", role: .destructive, action: actions.requestRemoval)
            .keyboardShortcut(placement == .menuBar && removesWithDeleteKey ? KeyboardShortcut(.delete) : nil)
    }

    private func shortcut(_ key: KeyEquivalent) -> KeyboardShortcut? {
        placement == .menuBar ? KeyboardShortcut(key) : nil
    }
}

/// Per-game core override; the empty tag stands for the system default.
struct GameCorePicker: View {
    let actions: GameActions

    var body: some View {
        if let system = actions.game.system {
            Picker("Core", selection: Binding(
                get: { actions.game.coreID ?? "" },
                set: { actions.setCore($0.isEmpty ? nil : $0) }
            )) {
                Text("System Default (\(system.core(withID: Preferences.coreChoice(for: system.id)).name))").tag("")
                Divider()
                ForEach(system.cores) { core in
                    Text(core.name).tag(core.id)
                }
            }
        }
    }
}

extension View {
    /// VoiceOver custom actions for a game, mirroring its context menu.
    func gameAccessibilityActions(_ actions: GameActions) -> some View {
        accessibilityAction(named: "Play", actions.play)
            .accessibilityAction(named: Text(actions.favoriteTitle), actions.toggleFavorite)
            .accessibilityAction(named: "Show in Finder", actions.showInFinder)
            .accessibilityAction(named: "Refetch Metadata", actions.refetchMetadata)
            .accessibilityAction(named: "Remove from Library…", actions.requestRemoval)
    }
}
