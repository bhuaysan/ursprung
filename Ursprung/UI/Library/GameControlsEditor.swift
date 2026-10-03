// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftData
import SwiftUI

/// Controls for one game. Without its own, a game uses its system's controls
/// (or those for all systems). Edits a draft that Done writes.
struct GameControlsEditor: View {
    let game: Game

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var usesOwn: Bool
    @State private var profile: InputProfile

    init(game: Game) {
        self.game = game
        let own = game.inputProfileData.flatMap(InputProfile.decode)
        _usesOwn = State(initialValue: own != nil)
        _profile = State(initialValue: own ?? InputProfile.resolved(gameProfile: nil, systemID: game.systemID))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle(isOn: $usesOwn) {
                        Text("Separate Controls for This Game")
                        Text("Otherwise “\(game.title)” uses the controls of \(game.system?.name ?? game.systemID).")
                    }
                }
                if usesOwn {
                    InputProfileEditor(profile: $profile)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("Takes effect the next time the game starts.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    game.inputProfileData = usesOwn ? profile.encoded : nil
                    try? context.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(AppSpacing.l)
        }
        .frame(width: 520)
        .frame(minHeight: 300, idealHeight: usesOwn ? 640 : 300)
        .presentationSizing(.fitted)
    }
}
