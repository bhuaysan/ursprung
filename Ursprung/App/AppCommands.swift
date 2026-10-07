// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct AppCommands: Commands {
    let session: EmulationSession
    let backup: BackupService
    let updates: UpdateChecker

    @FocusedValue(\.libraryActions) private var libraryActions
    @FocusedValue(\.isShowingRecentlyPlayed) private var isShowingRecentlyPlayed
    @FocusedValue(\.gameActions) private var gameActions
    @FocusedValue(\.batchActions) private var batchActions
    @FocusedValue(\.libraryFilter) private var libraryFilter
    @FocusedValue(\.isGridFocused) private var isGridFocused
    @FocusedValue(\.inspectorToggle) private var inspectorToggle
    @FocusedValue(\.saveStateSlot) private var saveStateSlot
    @FocusedValue(\.shaderEditorSave) private var shaderEditorSave
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Every toolbar command is also here (docs/DESIGN_SPEC.md, section D);
        // the items are disabled while another window is key.
        CommandGroup(replacing: .newItem) {
            LibraryActionItems(actions: libraryActions, placement: .menuBar)
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(updates.isChecking)
        }

        CommandGroup(replacing: .saveItem) {
            // ⌘S saves the shader while the shader editor is the key window.
            if let shaderEditorSave {
                Button("Save Shader", action: shaderEditorSave)
                    .keyboardShortcut("s")
            }
        }

        CommandGroup(before: .windowList) {
            Button("Shader Editor") { openWindow(id: WindowID.shaderEditor) }
                .keyboardShortcut("e", modifiers: [.command, .option])
            Divider()
        }

        CommandGroup(replacing: .importExport) {
            Button("Back Up Library…") { backup.backUp() }
                .disabled(backup.isWorking)
            Button("Restore from Backup…") { backup.restore() }
                .disabled(backup.isWorking)
        }

        CommandGroup(after: .toolbar) {
            Group {
                LibraryViewModeItems(showsShortcuts: true)
            }
            .disabled(libraryActions == nil)
            Divider()
            LibrarySortPicker(isFixedToRecentlyPlayed: isShowingRecentlyPlayed ?? false)
                .pickerStyle(.menu)
                .disabled(isShowingRecentlyPlayed == nil)
            Menu("Filter") {
                if let libraryFilter {
                    LibraryFilterItems(control: libraryFilter)
                }
            }
            .disabled(libraryFilter == nil)
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
            if let batchActions {
                BatchActionItems(actions: batchActions, showsShortcuts: true, removesWithDeleteKey: isGridFocused == true)
            } else if let gameActions {
                GameActionItems(actions: gameActions, placement: .menuBar, removesWithDeleteKey: isGridFocused == true)
            } else {
                Button("Play") {}.disabled(true)
                Button("Add to Favorites") {}.keyboardShortcut("d").disabled(true)
                Divider()
                Button("Edit Info…") {}.keyboardShortcut("i").disabled(true)
                Button("Choose Match…") {}.disabled(true)
                Button("Refetch Metadata") {}.disabled(true)
                Button("Show in Finder") {}.keyboardShortcut("r").disabled(true)
                Button("Import Battery Save…") {}.disabled(true)
                Divider()
                Button("Hide from Library") {}.disabled(true)
            }
            Divider()

            let running = session.phase == .running
            Button(session.isPaused ? "Resume" : "Pause") { session.togglePause() }
                .keyboardShortcut("p")
                .disabled(!running)
            Button("Show Menu") {
                // The menu key closes the shader panel first; this item always shows the menu.
                session.isShaderPanelVisible = false
                session.toggleMenu()
            }
                .disabled(!running)
            Button(session.isShaderPanelVisible ? "Hide Shader Panel" : "Show Shader Panel") { session.toggleShaderPanel() }
                .disabled(!running)
            Divider()
            if shaderEditorSave != nil {
                Button("Quick Save") { session.saveState(slot: 0) }
                    .disabled(!running)
            } else if let saveStateSlot {
                // The pause menu's Save States page: ⌘S saves into the focused slot.
                Button("Save to Slot \(saveStateSlot)") { session.saveState(slot: saveStateSlot) }
                    .keyboardShortcut("s")
            } else {
                // A game in a standalone emulator saves through its remote control.
                Button("Quick Save") { session.saveState(slot: 0) }
                    .keyboardShortcut("s")
                    .disabled(!running && !session.canUseExternalStates)
            }
            Button("Quick Load") { session.loadState(slot: 0) }
                .keyboardShortcut("l")
                .disabled(!running && !session.canUseExternalStates)
            Button("Take Screenshot") { session.takeScreenshot() }
                .disabled(!running)
            Divider()
            Button("Reset") { session.reset() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!running)
        }
    }
}
