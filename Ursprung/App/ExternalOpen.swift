// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation

/// Files and folders the Finder asks Ursprung to open (“Open With”, a drop
/// on the Dock icon). The library window imports them, also those that
/// arrive before it has loaded the library.
@Observable
final class ExternalOpen {
    static let shared = ExternalOpen()

    /// One entry per open request, oldest first.
    var requests: [[URL]] = []
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        ExternalOpen.shared.requests.append(files)
    }
}
