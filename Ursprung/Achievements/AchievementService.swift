// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// The RetroAchievements account and the one achievement client of the app.
/// The password is only used to sign in; the token RetroAchievements returns
/// is kept in the keychain and signs in again at the next launch.
@Observable
final class AchievementService {
    /// Shared with the emulation session, which loads games into it.
    let client: AchievementClient
    private(set) var user: AchievementUser?
    private(set) var isSigningIn = false
    /// Why the last sign-in failed.
    private(set) var signInError: String?

    init() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        client = AchievementClient(clientName: "Ursprung", version: version)
        signInWithStoredToken()
    }

    var isSignedIn: Bool { user != nil }

    /// Whether games load their achievements: switched on and signed in.
    var isActive: Bool { Preferences.achievementsEnabled && isSignedIn }

    func signIn(username: String, password: String) async {
        isSigningIn = true
        signInError = nil
        let result = await withCheckedContinuation { continuation in
            client.login(withUsername: username, password: password) { user, error in
                continuation.resume(returning: (user, error))
            }
        }
        isSigningIn = false
        if let user = result.0 {
            self.user = user
            UserDefaults.standard.set(user.username, forKey: PrefKey.achievementsUsername)
            Keychain.setPassword(user.token, for: Self.tokenAccount(user.username))
        } else {
            signInError = result.1?.localizedDescription ?? String(localized: "Signing in failed.")
        }
    }

    func signOut() {
        if let username = user?.username ?? Optional(Preferences.achievementsUsername), !username.isEmpty {
            Keychain.setPassword(nil, for: Self.tokenAccount(username))
        }
        client.logout()
        user = nil
        signInError = nil
    }

    private func signInWithStoredToken() {
        let username = Preferences.achievementsUsername
        guard Preferences.achievementsEnabled, !username.isEmpty,
              let token = Keychain.password(for: Self.tokenAccount(username)) else { return }
        isSigningIn = true
        client.login(withUsername: username, token: token) { [weak self] user, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSigningIn = false
                self.user = user
                if let error, user == nil {
                    self.signInError = error.localizedDescription
                }
            }
        }
    }

    /// Signs in with the stored token after achievements were switched on.
    func enable() {
        guard user == nil, !isSigningIn else { return }
        signInWithStoredToken()
    }

    private static func tokenAccount(_ username: String) -> String {
        "retroachievements:\(username)"
    }

    /// The RetroAchievements console of a system (rc_consoles.h), or nil
    /// when RetroAchievements has none.
    nonisolated static func consoleID(for systemID: String) -> Int? {
        consoles[systemID]
    }

    private nonisolated static let consoles: [String: Int] = [
        "nes": 7, "fds": 81, "snes": 3, "n64": 2, "gamecube": 16, "wii": 19, "gb": 4, "gbc": 6, "gba": 5,
        "nds": 18, "virtualboy": 28, "pokemini": 24, "sg1000": 33, "mastersystem": 11, "megadrive": 1,
        "segacd": 9, "sega32x": 10, "gamegear": 15, "saturn": 39, "dreamcast": 40, "psx": 12, "psp": 41,
        "pce": 8, "pcecd": 76, "supergrafx": 8, "atari2600": 25, "atari5200": 50, "atari7800": 51,
        "lynx": 13, "jaguar": 17, "ngp": 14, "ngpc": 14, "wonderswan": 53, "wonderswancolor": 53,
        "colecovision": 44, "intellivision": 45, "vectrex": 46, "3do": 43, "msx": 29, "arcade": 27,
    ]
}
