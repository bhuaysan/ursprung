// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The RetroAchievements account and how achievements behave while playing.
struct AchievementsSettingsView: View {
    @Environment(AchievementService.self) private var achievements
    @Environment(EmulationSession.self) private var session
    @AppStorage(PrefKey.achievementsEnabled) private var enabled = false
    @AppStorage(PrefKey.achievementsHardcore) private var hardcore = false
    @AppStorage(PrefKey.achievementsShowsProgress) private var showsProgress = true
    @AppStorage(PrefKey.achievementsUsername) private var storedUsername = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    Text("Earn Achievements")
                    Text("Games with achievements on RetroAchievements.org unlock them while you play.")
                }
            } footer: {
                Text("RetroAchievements is a free community service. Ursprung sends it a checksum of the game, your unlocks and what you are doing in the game.")
                    .settingsFootnote()
            }
            if enabled {
                accountSection
                Section {
                    Toggle(isOn: $hardcore) {
                        Text("Hardcore Mode")
                        Text("Unlocks earn full points. Loading states, rewind and cheats are off, and games start from the beginning.")
                    }
                    .disabled(session.isActive)
                    Toggle(isOn: $showsProgress) {
                        Text("Show Progress")
                        Text("Shows how far you are with achievements that count something, like collected items.")
                    }
                } header: {
                    Text("Playing")
                } footer: {
                    if session.isActive {
                        Text("Hardcore mode can be changed when no game is running.")
                            .settingsFootnote()
                    }
                }
            }
            ForEach(CoreManager.standaloneEmulators) { core in
                if let emulator = core.standalone {
                    Section {
                        LabeledContent {
                            StandaloneSettingsButton(emulator: emulator)
                        } label: {
                            Text(verbatim: SystemCatalog.all.filter { $0.cores.contains(core) }.map(\.name)
                                .formatted(.list(type: .and)))
                            Text("These games run in \(emulator.name), which earns achievements with its own RetroAchievements sign-in. Sign in under Achievements in its settings.")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { username = storedUsername }
        .onChange(of: enabled) { if enabled { achievements.enable() } }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if let user = achievements.user {
                LabeledContent("Signed In As") {
                    HStack(spacing: AppSpacing.s) {
                        if let avatar = user.imageURL.flatMap(URL.init(string:)) {
                            RemoteBadge(url: avatar, size: 24)
                        }
                        Text(user.displayName)
                    }
                }
                LabeledContent("Points") {
                    Text("\(user.score) hardcore, \(user.softcoreScore) softcore")
                        .monospacedDigit()
                }
                HStack {
                    Spacer()
                    Button("Sign Out") { achievements.signOut() }
                        .disabled(session.isActive)
                }
            } else {
                TextField("Username", text: $username)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .onSubmit(signIn)
                if let error = achievements.signInError {
                    StatusLabel("Signing in failed", kind: .error, detail: error)
                }
                HStack(spacing: AppSpacing.s) {
                    Spacer()
                    if achievements.isSigningIn { ProgressView().controlSize(.small) }
                    Button("Sign In", action: signIn)
                        .disabled(username.isEmpty || password.isEmpty || achievements.isSigningIn)
                }
            }
        } header: {
            Text("RetroAchievements Account")
        } footer: {
            Text("Your password is only sent to sign in. Ursprung keeps the sign-in token in your keychain. No account yet? Create one at retroachievements.org.")
                .settingsFootnote()
        }
    }

    private func signIn() {
        guard !username.isEmpty, !password.isEmpty else { return }
        let password = password
        self.password = ""
        Task { await achievements.signIn(username: username, password: password) }
    }
}
