// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreServices
import Foundation

/// Watches the library folders with FSEvents and reports changes that may add,
/// move or remove games. Changes to hidden files (Finder's .DS_Store and the
/// like) are ignored. Volumes that are mounted or unmounted count as a change,
/// since library folders may live on them. Lives as long as the app.
final class LibraryWatcher {
    private var stream: FSEventStreamRef?
    private var folders: [URL] = []
    private var observers: [NSObjectProtocol] = []
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                MainActor.assumeIsolated { self?.volumeChanged(volume) }
            })
        }
    }

    /// Watches `folders` instead of the previous ones. Folders that do not
    /// exist (an unmounted drive) are picked up when their volume mounts.
    func watch(_ folders: [URL]) {
        stop()
        self.folders = folders
        let paths = folders.map { $0.path(percentEncoded: false) }
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<LibraryWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []).prefix(count)
            MainActor.assumeIsolated { watcher.received(Array(changed)) }
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Whether a changed path can matter for the library: nothing below the
    /// watched folder is hidden. A library folder may itself lie inside a
    /// hidden folder (`~/.roms/SNES`); only the part below it counts.
    static func isRelevant(_ path: String, folders: [String] = []) -> Bool {
        let folder = folders.filter { LibraryPaths.isInside(path + "/", folder: $0) }.max { $0.count < $1.count }
        let below = folder.map { String(path.dropFirst($0.count)) } ?? path
        return !below.split(separator: "/").contains { $0.hasPrefix(".") && $0 != "." && $0 != ".." }
    }

    private func received(_ paths: [String]) {
        // FSEvents reports paths with symbolic links resolved (/private/var).
        let folders = self.folders.flatMap { [$0.path(percentEncoded: false), $0.resolvingSymlinksInPath().path(percentEncoded: false)] }
        if paths.contains(where: { Self.isRelevant($0, folders: folders) }) { onChange() }
    }

    private func volumeChanged(_ volume: URL?) {
        guard let volume else { return }
        let volumePath = volume.standardizedFileURL.path(percentEncoded: false)
        guard folders.contains(where: { LibraryPaths.isInside($0.path(percentEncoded: false), folder: volumePath) }) else { return }
        // The stream can only watch folders that exist.
        watch(folders)
        onChange()
    }
}

/// Turns a burst of change notifications into one rescan: it waits until
/// changes have settled, never starts while a scan runs, and keeps a minimum
/// distance between automatic scans.
@Observable
final class RescanScheduler {
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var lastScan = Date.distantPast
    @ObservationIgnored private let settle: Duration
    @ObservationIgnored private let minimumInterval: TimeInterval
    @ObservationIgnored private let now: () -> Date

    init(settle: Duration = .seconds(3), minimumInterval: TimeInterval = 15, now: @escaping () -> Date = { .now }) {
        self.settle = settle
        self.minimumInterval = minimumInterval
        self.now = now
    }

    /// Asks for a scan. `scan` runs once things are quiet; it reports whether
    /// it could start (false while another scan runs, which is then retried).
    func request(_ scan: @escaping () async -> Bool) {
        pending?.cancel()
        pending = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: settle)
            let wait = minimumInterval - now().timeIntervalSince(lastScan)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            if await scan() {
                lastScan = now()
            } else {
                request(scan)
            }
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
