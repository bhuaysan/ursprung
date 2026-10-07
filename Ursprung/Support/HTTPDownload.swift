// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Downloads from the libretro buildbot (cores, the shader pack) and GitHub
/// releases (standalone emulators).
nonisolated enum HTTPDownload {
    /// Fetches a URL to a temporary file, reporting progress (0…1).
    typealias Downloader = @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> URL
    /// When the file at a URL last changed on the server (HTTP Last-Modified).
    typealias LastModifiedFetcher = @Sendable (URL) async throws -> Date?

    /// The server answered with something other than 200 OK.
    struct StatusError: Error {
        let status: Int
    }

    /// Fetches `url` to a temporary file with the URL's extension (`.zip`
    /// when it has none), reporting progress (0…1).
    static func file(from url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let tracker = DownloadTracker(onProgress: onProgress)
        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: tracker)
        tracker.stop()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw StatusError(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "zip" : url.pathExtension)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// When the file at `url` last changed on the server (HTTP Last-Modified).
    static func lastModified(of url: URL) async throws -> Date? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let header = http.value(forHTTPHeaderField: "Last-Modified") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header)
    }
}

/// Reports download progress of a single URLSession task.
nonisolated private final class DownloadTracker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [onProgress] progress, _ in
            onProgress(progress.fractionCompleted)
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
    }
}
