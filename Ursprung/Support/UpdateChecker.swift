// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

/// Looks for a newer release on GitHub when the user asks. Releases are
/// signed, notarized disk images attached to tags named `v<version>`
/// (see Scripts/dist.sh). Nothing is downloaded or installed automatically.
@Observable
final class UpdateChecker {
    private(set) var isChecking = false

    nonisolated static let releasesAPI = URL(string: "https://api.github.com/repos/bhuaysan/ursprung/releases/latest")!

    struct Release: Sendable, Equatable {
        var version: String
        var page: URL
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            let alert = NSAlert()
            do {
                if let release = try await Self.latestRelease(), Self.isNewer(release.version, than: currentVersion) {
                    alert.messageText = String(localized: "Ursprung \(release.version) is available")
                    alert.informativeText = String(localized: "You have version \(currentVersion). Download the new version, then replace Ursprung in your Applications folder. Your library and saves stay as they are.")
                    alert.addButton(withTitle: String(localized: "Download"))
                    alert.addButton(withTitle: String(localized: "Later"))
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
                    return
                }
                alert.messageText = String(localized: "Ursprung is up to date")
                alert.informativeText = String(localized: "Version \(currentVersion) is the latest version.")
            } catch {
                alert.alertStyle = .warning
                alert.messageText = String(localized: "Couldn't check for updates")
                alert.informativeText = error.localizedDescription
            }
            alert.runModal()
        }
    }

    /// The latest published release, or nil when there is none yet.
    @concurrent
    static func latestRelease() async throws -> Release? {
        var request = URLRequest(url: releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return parse(data)
    }

    nonisolated static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page)
    }

    /// Compares dotted version numbers ("0.10.0" is newer than "0.9.2").
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
