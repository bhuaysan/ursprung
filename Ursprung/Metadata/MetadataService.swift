// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import SwiftData

/// Fetches metadata and artwork from ScreenScraper, one game at a time
/// (anonymous API access allows a single thread).
///
/// The queue lives in memory; what still needs doing is recorded on the games
/// (`scrapeState`, `mediaIncomplete`), so an interrupted fetch continues on the
/// next launch. Problems that are not a game's fault (quota, login, network)
/// stop the queue and leave the games as they were.
@Observable
final class MetadataService {
    /// What a queued job does with its game.
    enum Job: Sendable {
        /// Look the game up and take everything that is not locked.
        case full
        /// Download artwork that is missing; texts stay as they are.
        case media
        /// Take a match the user chose.
        case apply(ScrapedGame)
    }

    private struct Item {
        let id: PersistentIdentifier
        var job: Job
        var attempts = 0
    }

    private(set) var isRunning = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var currentTitle: String?
    var lastError: MetadataFailure?

    private var queue: [Item] = []
    private var worker: Task<Void, Never>?
    /// Bumped by `cancel()`. A cancelled worker may still be finishing its
    /// request; it then leaves the queue and the progress to its successor.
    private var generation = 0
    /// Failed games are retried automatically once per session, not on every scan.
    private var retriedFailures = Set<PersistentIdentifier>()
    private let makeClient: () -> ScreenScraperClient
    private let quota: QuotaPause

    /// How often a request that ScreenScraper turned away as busy is repeated.
    static let busyRetries = 3

    init(client: @escaping () -> ScreenScraperClient = { .configured }, quota: QuotaPause = QuotaPause()) {
        makeClient = client
        self.quota = quota
    }

    var progress: Double { total == 0 ? 0 : Double(completed) / Double(total) }

    /// True until ScreenScraper's daily quota resets once it has been reached.
    var isPausedForQuota: Bool { quota.isActive }

    /// What `enqueue` would do with `game`, or nil when nothing is missing.
    static func job(for game: Game, force: Bool, automatic: Bool) -> Job? {
        if force { return .full }
        switch game.scrapeState {
        case .pending, .failed: return .full
        case .notFound: return nil
        case .matched:
            if game.mediaIncomplete { return .media }
            // Libraries from before `mediaIncomplete` existed: a cover that
            // never arrived. Only on request, as the game may have none.
            if !automatic, game.boxArtFile == nil, !game.isLocked(.boxArt), game.screenScraperID != nil { return .media }
            return nil
        }
    }

    /// Queues games for scraping: games without metadata, and matched games
    /// with missing artwork. `force` fetches everything again. Automatic
    /// requests (after a scan) wait while the daily quota is used up, skip
    /// hidden and missing games, and retry failed games once per session.
    func enqueue(_ games: [Game], force: Bool = false, automatic: Bool = false, context: ModelContext) {
        if automatic, quota.isActive { return }
        if !automatic { quota.clear() }
        let known = Set(queue.map(\.id))
        var new: [Item] = []
        for game in games {
            let id = game.persistentModelID
            guard !known.contains(id) else { continue }
            if automatic {
                if game.isHidden || game.isMissing { continue }
                if game.scrapeState == .failed {
                    guard retriedFailures.insert(id).inserted else { continue }
                }
            }
            if let job = Self.job(for: game, force: force, automatic: automatic) { new.append(Item(id: id, job: job)) }
        }
        guard !new.isEmpty else { return }
        queue.append(contentsOf: new)
        total += new.count
        lastError = nil
        startIfNeeded(context: context)
    }

    /// Applies a match the user chose, ahead of everything else.
    func apply(_ match: ScrapedGame, to game: Game, context: ModelContext) {
        let id = game.persistentModelID
        // A job already queued for the game is replaced, not added to.
        let wasQueued = queue.contains { $0.id == id }
        queue.removeAll { $0.id == id }
        queue.insert(Item(id: id, job: .apply(match)), at: 0)
        if !wasQueued { total += 1 }
        lastError = nil
        startIfNeeded(context: context)
    }

    /// Every game a title search finds, for choosing a match.
    func search(_ title: String, systemID: Int) async throws -> [ScrapedGame] {
        try await makeClient().search(title: title, systemID: systemID)
    }

    /// Checks the configured account.
    func checkAccount() async throws -> ScraperAccount {
        try await makeClient().account()
    }

    func cancel() {
        worker?.cancel()
        generation += 1
        queue.removeAll()
        finish()
    }

    private func startIfNeeded(context: ModelContext) {
        guard worker == nil else { return }
        isRunning = true
        worker = Task { [weak self, generation = self.generation] in
            await self?.run(generation: generation, context: context)
        }
    }

    private func run(generation: Int, context: ModelContext) async {
        let client = makeClient()
        while generation == self.generation, !queue.isEmpty {
            let item = queue.removeFirst()
            guard let game = context.existingGame(item.id) else { completed += 1; continue }
            currentTitle = game.title
            do {
                try await perform(item.job, on: game, client: client)
                try? context.save()
            } catch {
                // A cancelled request is no failure of the game.
                guard generation == self.generation, !(error is CancellationError) else { break }
                if error as? ScreenScraperError == .tooManyThreads, item.attempts < Self.busyRetries {
                    var retry = item
                    retry.attempts += 1
                    queue.insert(retry, at: 0)
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                lastError = MetadataFailure(error)
                if Self.isSessionFailure(error) {
                    // Not this game's fault: it stays as it was, and so does
                    // every game still waiting. The next launch (or Retry) continues.
                    if error as? ScreenScraperError == .quotaExceeded { quota.start() }
                    queue.removeAll()
                    break
                }
                switch item.job {
                case .full: game.scrapeState = .failed
                case .media, .apply: game.mediaIncomplete = true
                }
            }
            guard generation == self.generation else { break }
            completed += 1
        }
        try? context.save()
        guard generation == self.generation else { return }
        finish()
    }

    /// Errors that say nothing about the game, only about this session.
    static func isSessionFailure(_ error: Error) -> Bool {
        if let error = error as? ScreenScraperError { return error.isFatal || error == .tooManyThreads }
        return error is URLError
    }

    private func finish() {
        worker = nil
        isRunning = false
        currentTitle = nil
        completed = 0
        total = 0
    }

    private func perform(_ job: Job, on game: Game, client: ScreenScraperClient) async throws {
        guard let system = game.system else { return }
        switch job {
        case .apply(let match):
            try await take(match, for: game, mediaOnly: false, client: client)
        case .media:
            guard let gameID = game.screenScraperID else { return try await perform(.full, on: game, client: client) }
            guard let result = try await client.lookup(gameID: gameID, systemID: system.screenScraperID) else {
                game.mediaIncomplete = false
                return
            }
            try await take(result, for: game, mediaOnly: true, client: client)
        case .full:
            let url = game.fileURL
            var crc = game.crc32
            // The file may have been replaced since the last scan. A missing
            // file keeps what is known about it: the checksum helps a later
            // scan recognize it after a rename.
            if game.fileSize > 0, game.fileSize <= 64 << 20,
               !["cue", "m3u", "gdi", "zip"].contains(url.pathExtension.lowercased()),
               let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               crc == nil || modified != game.fileModified,
               let checksum = await Self.checksum(of: url) {
                crc = checksum
                game.crc32 = checksum
                game.fileModified = modified
            }
            let query = ScrapeQuery(systemID: system.screenScraperID, fileName: game.fileName, fileSize: game.fileSize,
                                    crc32: crc, searchTitle: game.title)
            guard let result = try await client.lookup(query) else {
                game.scrapeState = .notFound
                return
            }
            try await take(result, for: game, mediaOnly: false, client: client)
        }
    }

    /// Takes `result` into `game`. Locked fields keep the user's values.
    /// `mediaOnly` downloads only artwork the game does not have yet.
    private func take(_ result: ScrapedGame, for game: Game, mediaOnly: Bool, client: ScreenScraperClient) async throws {
        if !mediaOnly {
            Self.takeTexts(of: result, into: game)
        }
        let downloads: [(URL?, String, Int, ReferenceWritableKeyPath<Game, String?>)] = [
            (result.boxArt, "box.png", 640, \.boxArtFile),
            (result.screenshot, "screenshot.png", 960, \.screenshotFile),
            (result.titleScreen, "title.png", 960, \.titleScreenFile),
            (result.logo, "logo.png", 800, \.logoFile),
            (result.fanart, "fanart.jpg", 1600, \.fanartFile),
        ]
        var incomplete = false
        for (source, name, width, keyPath) in downloads {
            if keyPath == \Game.boxArtFile, game.isLocked(.boxArt) { continue }
            if mediaOnly, let existing = game.mediaURL(game[keyPath: keyPath]),
               FileManager.default.fileExists(atPath: existing.path(percentEncoded: false)) { continue }
            guard let source else {
                // A new match without this kind of artwork: the old one belonged to another game.
                if !mediaOnly { game[keyPath: keyPath] = nil }
                continue
            }
            try Task.checkCancellation()
            do {
                try await client.download(source, to: game.mediaDirectory.appending(path: name), maxWidth: width)
                game[keyPath: keyPath] = name
            } catch {
                // Fetch Missing tries again later; the texts are fine.
                incomplete = true
            }
        }
        game.mediaIncomplete = incomplete
        game.scrapeState = .matched
    }

    /// Copies the texts of `result` into the fields the user has not locked.
    static func takeTexts(of result: ScrapedGame, into game: Game) {
        func take(_ field: GameField, _ value: String?, _ keyPath: ReferenceWritableKeyPath<Game, String?>) {
            if !game.isLocked(field) { game[keyPath: keyPath] = value }
        }
        if let title = result.title, !game.isLocked(.title) { game.title = title }
        game.screenScraperID = result.screenScraperID
        take(.overview, result.overview, \.overview)
        take(.developer, result.developer, \.developer)
        take(.publisher, result.publisher, \.publisher)
        take(.genre, result.genre, \.genre)
        take(.releaseDate, result.releaseDate, \.releaseDate)
        take(.players, result.players, \.players)
        game.rating = result.rating
    }

    @concurrent
    private static func checksum(of url: URL) async -> String? {
        (try? Checksum.crc(of: url)).map(Checksum.hex)
    }
}

/// Remembers that ScreenScraper's daily quota was reached, so automatic
/// fetching waits for the next day instead of failing on every scan. The
/// quota resets at midnight in France.
nonisolated struct QuotaPause: Sendable {
    var defaults: @Sendable () -> UserDefaults = { .standard }
    var now: @Sendable () -> Date = { .now }

    private static let key = "metadataQuotaDay"

    private var today: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: now())
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    var isActive: Bool { defaults().string(forKey: Self.key) == today }

    func start() { defaults().set(today, forKey: Self.key) }

    func clear() { defaults().removeObject(forKey: Self.key) }
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
