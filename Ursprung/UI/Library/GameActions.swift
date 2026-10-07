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
    let organize: OrganizeActions
    /// Opens the game's save states.
    let showSaveStates: () -> Void
    /// Opens the game's shader in the shader editor, with its captured frames.
    let editShader: () -> Void
    /// Edits the disc playlist of an .m3u game, or creates one from the
    /// game's loose discs; nil when the game has neither.
    var discs: DiscAction?

    var favoriteTitle: LocalizedStringKey {
        game.isFavorite ? "Remove from Favorites" : "Add to Favorites"
    }

    var playTitle: LocalizedStringKey {
        hasAutosave && resumesAutomatically ? "Resume" : "Play"
    }

    var alternatePlayTitle: LocalizedStringKey {
        resumesAutomatically ? "Start from Beginning" : "Resume"
    }

    /// PlayStation 2 games, run by ARMSX2, save to a memory card.
    var importSaveTitle: LocalizedStringKey {
        game.effectiveCore?.standalone != nil ? "Import Memory Card…" : "Import Battery Save…"
    }

    var hiddenTitle: LocalizedStringKey {
        game.isHidden ? "Show in Library" : "Hide from Library"
    }

    var favoriteSymbol: String {
        game.isFavorite ? "heart.slash" : "heart"
    }
}

/// Edit Discs… or Create Disc Playlist… for a multi-disc game.
struct DiscAction {
    enum Kind { case edit, create }
    let kind: Kind
    let perform: () -> Void

    var title: LocalizedStringKey {
        kind == .edit ? "Edit Discs…" : "Create Disc Playlist…"
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
        } else if actions.hasAutosave {
            Button(actions.alternatePlayTitle, systemImage: actions.resumesAutomatically ? "backward.end" : "play",
                   action: actions.playAlternate)
        }
        OrganizeItems(actions: actions.organize)
        Divider()
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
        Button("Save States…", systemImage: "square.stack.3d.up", action: actions.showSaveStates)
        // A standalone emulator applies its own post-processing.
        if actions.game.effectiveCore?.isLibretro != false {
            Button("Edit Shader…", systemImage: "camera.filters", action: actions.editShader)
        }
        Button(actions.importSaveTitle, systemImage: "square.and.arrow.down", action: actions.importBatterySave)
            .disabled(!actions.canImportBatterySave)
        if let discs = actions.discs {
            Button(discs.title, systemImage: "opticaldisc", action: discs.perform)
        }
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
    /// Shows the name of the core in use, also when it is the system's.
    var showsCoreName = false

    var body: some View {
        if let system = actions.game.system {
            let selection = Binding(get: { actions.game.coreID ?? "" },
                                    set: { actions.setCore($0.isEmpty ? nil : $0) })
            if showsCoreName, let core = actions.game.effectiveCore {
                Picker(selection: selection) { items(system) } label: { Text("Core") } currentValueLabel: { Text(verbatim: core.name) }
            } else {
                Picker("Core", selection: selection) { items(system) }
            }
        }
    }

    @ViewBuilder
    private func items(_ system: GameSystem) -> some View {
        Text("System Default (\(system.core(withID: Preferences.coreChoice(for: system.id)).name))").tag("")
        Divider()
        ForEach(system.cores) { core in
            Text(core.name).tag(core.id)
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
