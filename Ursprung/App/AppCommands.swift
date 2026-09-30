// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftData
import SwiftUI

struct AppCommands: Commands {
    let session: EmulationSession
    let library: LibraryStore

    @FocusedValue(\.modelContext) private var modelContext
    @FocusedValue(\.gameActions) private var gameActions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Folder to Library…") {
                if let modelContext { library.presentAddFolderPanel(context: modelContext) }
            }
            .keyboardShortcut("o")
            .disabled(modelContext == nil)

            Button("Rescan Library") {
                if let modelContext { Task { await library.rescan(context: modelContext) } }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(modelContext == nil || library.isScanning)
        }

        CommandMenu("Game") {
            // The selected game in the library; disabled while another window is key.
            if let gameActions {
                GameActionItems(actions: gameActions, placement: .menuBar)
            } else {
                Button("Play") {}.disabled(true)
                Button("Add to Favorites") {}.keyboardShortcut("d").disabled(true)
                Divider()
                Button("Refetch Metadata") {}.disabled(true)
                Button("Show in Finder") {}.keyboardShortcut("r").disabled(true)
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
            Button("Quick Save") { session.saveState(slot: 0) }
                .keyboardShortcut("s")
                .disabled(!running)
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

extension FocusedValues {
    /// The library window publishes its model context for menu commands.
    @Entry var modelContext: ModelContext?
}
