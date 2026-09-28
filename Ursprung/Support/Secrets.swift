// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Build-time embedded ScreenScraper developer credentials.
///
/// The values come from `.env` via `Scripts/generate-secrets.sh`. Forks and
/// source builds without a `.env` still work — metadata scraping is simply
/// unavailable until developer credentials are provided.
nonisolated enum Secrets {
    static var screenScraperDevID: String { decode(GeneratedSecrets.screenScraperDevID) }
    static var screenScraperDevPassword: String { decode(GeneratedSecrets.screenScraperDevPassword) }

    static var hasScreenScraperCredentials: Bool {
        !GeneratedSecrets.screenScraperDevID.isEmpty && !GeneratedSecrets.screenScraperDevPassword.isEmpty
    }

    /// Reverses the XOR obfuscation applied by `generate-secrets.sh`.
    static func decode(_ bytes: [UInt8]) -> String {
        let key = 0x5A
        let plain = bytes.enumerated().map { index, byte in
            byte ^ UInt8((key + index * 31) & 0xFF)
        }
        return String(decoding: plain, as: UTF8.self)
    }
}
