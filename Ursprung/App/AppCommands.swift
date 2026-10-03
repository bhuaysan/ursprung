// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct AppCommands: Commands {
    let session: EmulationSession
    let backup: BackupService

    @FocusedValue(\.libraryActions) private var libraryActions
    @FocusedValue(\.isShowingRecentlyPlayed) private var isShowingRecentlyPlayed
    @FocusedValue(\.gameActions) private var gameActions
    @FocusedValue(\.isGridFocused) private var isGridFocused
    @FocusedValue(\.inspectorToggle) private var inspectorToggle
    @FocusedValue(\.saveStateSlot) private var saveStateSlot

    var body: some Commands {
        // Every toolbar command is also here (docs/DESIGN_SPEC.md, section D);
        // the items are disabled while another window is key.
        CommandGroup(replacing: .newItem) {
            LibraryActionItems(actions: libraryActions, placement: .menuBar)
        }

        CommandGroup(replacing: .importExport) {
            Button("Back Up Library…") { backup.backUp() }
                .disabled(backup.isWorking)
            Button("Restore from Backup…") { backup.restore() }
                .disabled(backup.isWorking)
        }

        CommandGroup(after: .toolbar) {
            LibrarySortPicker(isFixedToRecentlyPlayed: isShowingRecentlyPlayed ?? false)
                .pickerStyle(.menu)
                .disabled(isShowingRecentlyPlayed == nil)
            Divider()
            CoverSizeItems(showsShortcuts: true)
                .disabled(libraryActions == nil)
        }

        CommandGroup(after: .sidebar) {
            Button(inspectorToggle?.isShown == true ? "Hide Inspector" : "Show Inspector") { inspectorToggle?.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .control])
                .disabled(inspectorToggle == nil)
        }

        CommandMenu("Game") {
            // The selected game in the library; disabled while another window is key.
            if let gameActions {
                GameActionItems(actions: gameActions, placement: .menuBar, removesWithDeleteKey: isGridFocused == true)
            } else {
                Button("Play") {}.disabled(true)
                Button("Add to Favorites") {}.keyboardShortcut("d").disabled(true)
                Divider()
                Button("Refetch Metadata") {}.disabled(true)
                Button("Show in Finder") {}.keyboardShortcut("r").disabled(true)
                Button("Import Battery Save…") {}.disabled(true)
                Divider()
                Button("Remove from Library…") {}.disabled(true)
            }
            Divider()

            let running = session.phase == .running
            Button(session.isPaused ? "Resume" : "Pause") { session.togglePause() }
                .keyboardShortcut("p")
                .disabled(!running)
            Button("Show Menu") { session.toggleMenu() }
                .disabled(!running)
            Divider()
            if let saveStateSlot {
                // The pause menu's Save States page: ⌘S saves into the focused slot.
                Button("Save to Slot \(saveStateSlot)") { session.saveState(slot: saveStateSlot) }
                    .keyboardShortcut("s")
            } else {
                Button("Quick Save") { session.saveState(slot: 0) }
                    .keyboardShortcut("s")
                    .disabled(!running)
            }
            Button("Quick Load") { session.loadState(slot: 0) }
                .keyboardShortcut("l")
                .disabled(!running)
            Divider()
            Button("Reset") { session.reset() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!running)
        }
    }
}
