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
    var lastError: String?

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
        let client = makeClient()
        while !queue.isEmpty, !Task.isCancelled {
            let id = queue.removeFirst()
            guard let game = context.model(for: id) as? Game else { completed += 1; continue }
            currentTitle = game.title
            do {
                try await scrape(game, client: client)
                try? context.save()
            } catch let error as ScreenScraperError {
                game.scrapeState = .failed
                lastError = error.localizedDescription
                if error.isFatal { queue.removeAll() }
                if error == .tooManyThreads { try? await Task.sleep(for: .seconds(5)) }
            } catch is CancellationError {
                break
            } catch {
                game.scrapeState = .failed
                lastError = error.localizedDescription
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

    private func makeClient() -> ScreenScraperClient {
        var client = ScreenScraperClient()
        client.username = Preferences.scraperUsername
        client.password = Keychain.password(for: client.username) ?? ""
        client.language = Preferences.scraperLanguage
        client.region = Preferences.scraperRegion
        return client
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
