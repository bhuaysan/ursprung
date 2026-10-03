// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Everything the user can do with one game. The grid's context menu, the
/// inspector, the Game menu and VoiceOver all build their items from this,
/// so labels, symbols and order match everywhere.
struct GameActions {
    let game: Game
    /// Starts the game; continues from its automatic state when there is one
    /// and the user resumes automatically (Settings › Emulation).
    let play: () -> Void
    /// The other way to start when an automatic state exists: from the
    /// beginning, or continuing (when Play starts fresh).
    let playAlternate: () -> Void
    /// Whether an automatic state exists for the game's core.
    var hasAutosave = false
    var resumesAutomatically = true
    let toggleFavorite: () -> Void
    let refetchMetadata: () -> Void
    let editInfo: () -> Void
    let chooseMatch: () -> Void
    let showInFinder: () -> Void
    /// Chooses the file of a missing game.
    let locate: () -> Void
    /// Hides the game, or shows a hidden one again. Hidden games keep their data.
    let toggleHidden: () -> Void
    let importBatterySave: () -> Void
    /// False while the game runs: its next save would overwrite an import.
    var canImportBatterySave = true
    /// `nil` selects the system's default core.
    let setCore: (String?) -> Void
    /// Missing games only: asks for confirmation before the game leaves the
    /// library. A present file would come back with the next scan, so
    /// present games are hidden instead.
    let requestRemoval: () -> Void

    var favoriteTitle: LocalizedStringKey {
        game.isFavorite ? "Remove from Favorites" : "Add to Favorites"
    }

    var playTitle: LocalizedStringKey {
        hasAutosave && resumesAutomatically ? "Resume" : "Play"
    }

    var alternatePlayTitle: LocalizedStringKey {
        resumesAutomatically ? "Start from Beginning" : "Resume"
    }

    var hiddenTitle: LocalizedStringKey {
        game.isHidden ? "Show in Library" : "Hide from Library"
    }

    var favoriteSymbol: String {
        game.isFavorite ? "heart.slash" : "heart"
    }
}

extension FocusedValues {
    /// The selected game's actions, published by the library window for the Game menu.
    @Entry var gameActions: GameActions?
    /// Set while the grid has keyboard focus. Only then does the Game menu give
    /// Hide from Library (or Remove for a missing game) ⌘⌫, so the search field keeps ⌘⌫ for its text.
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
    /// Menu bar only: registers ⌘⌫ for Hide from Library or Remove from Library.
    var removesWithDeleteKey = false

    var body: some View {
        if placement != .inspectorMenu {
            Button(actions.playTitle, systemImage: "play.fill", action: actions.play)
            if actions.hasAutosave {
                Button(actions.alternatePlayTitle, systemImage: actions.resumesAutomatically ? "backward.end" : "play",
                       action: actions.playAlternate)
            }
            Button(actions.favoriteTitle, systemImage: actions.favoriteSymbol, action: actions.toggleFavorite)
                .keyboardShortcut(shortcut("d"))
            Divider()
        } else if actions.hasAutosave {
            Button(actions.alternatePlayTitle, systemImage: actions.resumesAutomatically ? "backward.end" : "play",
                   action: actions.playAlternate)
            Divider()
        }
        Button("Edit Info…", systemImage: "pencil", action: actions.editInfo)
            .keyboardShortcut(shortcut("i"))
        Button("Choose Match…", systemImage: "magnifyingglass.circle", action: actions.chooseMatch)
        Button("Refetch Metadata", systemImage: "arrow.triangle.2.circlepath", action: actions.refetchMetadata)
        if actions.game.isMissing {
            Button("Locate File…", systemImage: "magnifyingglass", action: actions.locate)
        } else {
            Button("Show in Finder", systemImage: "folder", action: actions.showInFinder)
                .keyboardShortcut(shortcut("r"))
        }
        Button("Import Battery Save…", systemImage: "square.and.arrow.down", action: actions.importBatterySave)
            .disabled(!actions.canImportBatterySave)
        if placement == .contextMenu, (actions.game.system?.cores.count ?? 0) > 1 {
            GameCorePicker(actions: actions)
                .pickerStyle(.menu)
        }
        Divider()
        if actions.game.isMissing {
            Button("Remove from Library…", systemImage: "trash", role: .destructive, action: actions.requestRemoval)
                .keyboardShortcut(placement == .menuBar && removesWithDeleteKey ? KeyboardShortcut(.delete) : nil)
        } else {
            Button(actions.hiddenTitle, systemImage: actions.game.isHidden ? "eye" : "eye.slash", action: actions.toggleHidden)
                .keyboardShortcut(placement == .menuBar && removesWithDeleteKey ? KeyboardShortcut(.delete) : nil)
        }
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
        accessibilityAction(named: Text(actions.playTitle), actions.play)
            .accessibilityAction(named: Text(actions.favoriteTitle), actions.toggleFavorite)
            .accessibilityAction(named: actions.game.isMissing ? "Locate File…" : "Show in Finder",
                                 actions.game.isMissing ? actions.locate : actions.showInFinder)
            .accessibilityAction(named: "Refetch Metadata", actions.refetchMetadata)
            .accessibilityAction(named: "Edit Info…", actions.editInfo)
            .accessibilityAction(named: actions.game.isMissing ? "Remove from Library…" : actions.hiddenTitle,
                                 actions.game.isMissing ? actions.requestRemoval : actions.toggleHidden)
    }
}
