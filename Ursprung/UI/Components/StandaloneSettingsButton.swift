// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Opens a standalone emulator's own window for its settings (graphics,
/// achievements), downloading the emulator first if needed.
struct StandaloneSettingsButton: View {
    let emulator: StandaloneEmulator
    /// "Open" where the row already names the settings.
    var isShort = false
    @Environment(EmulationSession.self) private var session
    @State private var failure: String?

    var body: some View {
        Button {
            Task {
                do {
                    try await session.openStandaloneSettings(emulator)
                } catch {
                    failure = error.localizedDescription
                }
            }
        } label: {
            if isShort { Text("Open") } else { Text("Open \(emulator.name) Settings") }
        }
        .disabled(session.isStandaloneEmulatorInUse)
        .help(session.isStandaloneEmulatorInUse
              ? String(localized: "Available when no game is running in \(emulator.name)")
              : String(localized: "Opens \(emulator.name)'s window; its settings are in its Settings menu"))
        .alert(Text("\(emulator.name) couldn't be opened"),
               isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }
}
