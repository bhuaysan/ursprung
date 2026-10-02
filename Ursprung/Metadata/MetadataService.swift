// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import SwiftData

/// Fetches metadata and artwork from ScreenScraper, one game at a time
/// (anonymous API access allows a single thread).
@Observable
final class MetadataService {
    private(set) var isRunning = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var currentTitle: String?
    var lastError: MetadataFailure?

    private var queue: [PersistentIdentifier] = []
    private var worker: Task<Void, Never>?

    var progress: Double { total == 0 ? 0 : Double(completed) / Double(total) }

    /// Queues games for scraping. Already matched games are skipped unless
    /// `force` is set.
    func enqueue(_ games: [Game], force: Bool = false, context: ModelContext) {
        let pending = games.filter { force || $0.scrapeState == .pending || $0.scrapeState == .failed }
        let known = Set(queue)
        let new = pending.map(\.persistentModelID).filter { !known.contains($0) }
        guard !new.isEmpty else { return }
        queue.append(contentsOf: new)
        total += new.count
        lastError = nil
        startIfNeeded(context: context)
    }

    func cancel() {
        worker?.cancel()
        queue.removeAll()
    }

    private func startIfNeeded(context: ModelContext) {
        guard worker == nil else { return }
        isRunning = true
        worker = Task { [weak self] in
            await self?.run(context: context)
        }
    }

    private func run(context: ModelContext) async {
        let client = ScreenScraperClient.configured
        while !queue.isEmpty, !Task.isCancelled {
            let id = queue.removeFirst()
            guard let game = context.existingGame(id) else { completed += 1; continue }
            currentTitle = game.title
            do {
                try await scrape(game, client: client)
                try? context.save()
            } catch let error as ScreenScraperError {
                game.scrapeState = .failed
                lastError = MetadataFailure(error)
                if error.isFatal { queue.removeAll() }
                if error == .tooManyThreads { try? await Task.sleep(for: .seconds(5)) }
            } catch is CancellationError {
                break
            } catch {
                game.scrapeState = .failed
                lastError = MetadataFailure(error)
            }
            completed += 1
        }
        try? context.save()
        worker = nil
        isRunning = false
        currentTitle = nil
        completed = 0
        total = 0
    }

    private func scrape(_ game: Game, client: ScreenScraperClient) async throws {
        guard let system = game.system else { return }
        let url = game.fileURL
        var crc = game.crc32
        if crc == nil, game.fileSize > 0, game.fileSize <= 64 << 20,
           !["cue", "m3u", "gdi", "zip"].contains(url.pathExtension.lowercased()) {
            crc = await Self.checksum(of: url)
            game.crc32 = crc
        }

        let query = ScrapeQuery(systemID: system.screenScraperID, fileName: game.fileName, fileSize: game.fileSize,
                                crc32: crc, searchTitle: game.title)
        guard let result = try await client.lookup(query) else {
            game.scrapeState = .notFound
            return
        }

        if let title = result.title { game.title = title }
        game.screenScraperID = result.screenScraperID
        game.overview = result.overview
        game.developer = result.developer
        game.publisher = result.publisher
        game.genre = result.genre
        game.releaseDate = result.releaseDate
        game.players = result.players
        game.rating = result.rating

        let directory = game.mediaDirectory
        let downloads: [(URL?, String, Int, ReferenceWritableKeyPath<Game, String?>)] = [
            (result.boxArt, "box.png", 640, \.boxArtFile),
            (result.screenshot, "screenshot.png", 960, \.screenshotFile),
            (result.titleScreen, "title.png", 960, \.titleScreenFile),
            (result.logo, "logo.png", 800, \.logoFile),
            (result.fanart, "fanart.jpg", 1600, \.fanartFile),
        ]
        for (source, name, width, keyPath) in downloads {
            guard let source else { continue }
            try Task.checkCancellation()
            do {
                try await client.download(source, to: directory.appending(path: name), maxWidth: width)
                game[keyPath: keyPath] = name
            } catch {
                // Missing individual media is not an error for the game.
            }
        }
        game.scrapeState = .matched
    }

    @concurrent
    private static func checksum(of url: URL) async -> String? {
        (try? Checksum.crc(of: url)).map(Checksum.hex)
    }
}

/// Why the last metadata fetch failed, written as what happened plus what to do.
nonisolated struct MetadataFailure: Hashable, Sendable {
    /// What happened in a few words: one line in the activity footer.
    var reason: String
    /// What happened and what to do, for tooltips, VoiceOver and Settings.
    var message: String

    init(reason: String, message: String) {
        self.reason = reason
        self.message = message
    }

    init(_ error: any Error) {
        switch error {
        case let error as ScreenScraperError:
            self.init(reason: error.reason, message: error.localizedDescription)
        case let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                                          .internationalRoamingOff].contains(error.code):
            self.init(reason: String(localized: "No internet connection"),
                      message: String(localized: "Ursprung is offline. Check your internet connection, then retry."))
        case let error as URLError where [.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                                          .secureConnectionFailed].contains(error.code):
            self.init(reason: String(localized: "ScreenScraper didn't respond"),
                      message: String(localized: "ScreenScraper can't be reached right now. Try again later."))
        default:
            self.init(reason: error.localizedDescription,
                      message: String(localized: "\(error.localizedDescription) Try again later."))
        }
    }
}
