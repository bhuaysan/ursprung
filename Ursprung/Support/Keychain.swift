// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Security

/// Minimal generic-password Keychain wrapper for the optional ScreenScraper
/// user account password.
nonisolated enum Keychain {
    private static let service = "io.github.bhuaysan.Ursprung"

    static func password(for account: String) -> String? {
        guard !account.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String?, for account: String) {
        guard !account.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
