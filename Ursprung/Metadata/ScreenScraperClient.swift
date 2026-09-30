// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Metadata for one game as returned by ScreenScraper, already reduced to the
/// preferred language and region.
nonisolated struct ScrapedGame: Sendable {
    var screenScraperID: String
    var title: String?
    var overview: String?
    var developer: String?
    var publisher: String?
    var genre: String?
    var releaseDate: String?
    var players: String?
    var rating: Double?
    /// Media download URLs. They embed API credentials — never persist or log them.
    var boxArt: URL?
    var screenshot: URL?
    var titleScreen: URL?
    var logo: URL?
    var fanart: URL?
}

/// Media of one system. The URLs embed API credentials — never persist or log them.
nonisolated struct ScrapedSystemMedia: Sendable {
    /// Monochrome logo (`logo-monochrome`).
    var logo: URL?
    /// Cut-out console photo (`photo`).
    var photo: URL?
}

nonisolated struct ScrapeQuery: Sendable {
    var systemID: Int
    var fileName: String
    var fileSize: Int64
    var crc32: String?
    var searchTitle: String
}

nonisolated enum ScreenScraperError: LocalizedError, Equatable {
    case missingDeveloperCredentials
    case invalidCredentials
    case quotaExceeded
    case tooManyThreads
    case serverClosed
    case http(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingDeveloperCredentials:
            String(localized: "This build has no ScreenScraper developer credentials. Add them to .env and rebuild.")
        case .invalidCredentials:
            String(localized: "ScreenScraper rejected the login. Check your username and password in Settings.")
        case .quotaExceeded:
            String(localized: "The daily ScreenScraper quota is used up. Try again tomorrow or sign in with a ScreenScraper account.")
        case .tooManyThreads:
            String(localized: "ScreenScraper is busy. Please try again in a moment.")
        case .serverClosed:
            String(localized: "ScreenScraper is currently closed for maintenance or overloaded.")
        case .http(let code):
            String(localized: "ScreenScraper returned HTTP \(code).")
        case .invalidResponse:
            String(localized: "ScreenScraper returned an unexpected response.")
        }
    }

    /// Errors that make further requests pointless in this session.
    var isFatal: Bool {
        switch self {
        case .missingDeveloperCredentials, .invalidCredentials, .quotaExceeded, .serverClosed: true
        default: false
        }
    }
}

nonisolated struct ScreenScraperClient: Sendable {
    var devID: String = Secrets.screenScraperDevID
    var devPassword: String = Secrets.screenScraperDevPassword
    var username: String = ""
    var password: String = ""
    var language: String = "en"
    var region: String = "eu"

    private static let baseURL = URL(string: "https://api.screenscraper.fr/api2/")!
    private static let softwareName = "Ursprung"

    /// A client with the account and language settings from Preferences.
    static var configured: ScreenScraperClient {
        var client = ScreenScraperClient()
        client.username = Preferences.scraperUsername
        client.password = Keychain.password(for: client.username) ?? ""
        client.language = Preferences.scraperLanguage
        client.region = Preferences.scraperRegion
        return client
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.httpAdditionalHeaders = ["User-Agent": "Ursprung/0.1 (macOS)"]
        return URLSession(configuration: configuration)
    }()

    // MARK: - API

    /// Looks a game up by checksum / file name, falling back to a title search.
    @concurrent
    func lookup(_ query: ScrapeQuery) async throws -> ScrapedGame? {
        guard !devID.isEmpty, !devPassword.isEmpty else { throw ScreenScraperError.missingDeveloperCredentials }

        var items = [
            URLQueryItem(name: "systemeid", value: String(query.systemID)),
            URLQueryItem(name: "romtype", value: "rom"),
            URLQueryItem(name: "romnom", value: query.fileName),
            URLQueryItem(name: "romtaille", value: String(query.fileSize)),
        ]
        if let crc = query.crc32 { items.append(URLQueryItem(name: "crc", value: crc)) }

        if let json = try await request("jeuInfos.php", items),
           let response = json["response"] as? [String: Any],
           let game = response["jeu"] as? [String: Any],
           let result = parse(game) {
            return result
        }

        // Fallback: search by the cleaned-up title.
        let search = [
            URLQueryItem(name: "systemeid", value: String(query.systemID)),
            URLQueryItem(name: "recherche", value: query.searchTitle),
        ]
        if let json = try await request("jeuRecherche.php", search),
           let response = json["response"] as? [String: Any],
           let games = response["jeux"] as? [[String: Any]] {
            for game in games {
                if let result = parse(game) { return result }
            }
        }
        return nil
    }

    /// Logo and console photo download URLs by ScreenScraper system ID.
    @concurrent
    func systemMedia() async throws -> [Int: ScrapedSystemMedia] {
        guard !devID.isEmpty, !devPassword.isEmpty else { throw ScreenScraperError.missingDeveloperCredentials }
        guard let json = try await request("systemesListe.php", []) else { return [:] }
        return parseSystemMedia(json)
    }

    func parseSystemMedia(_ json: [String: Any]) -> [Int: ScrapedSystemMedia] {
        let systems = (json["response"] as? [String: Any])?["systemes"] as? [[String: Any]] ?? []
        var result: [Int: ScrapedSystemMedia] = [:]
        for system in systems {
            guard let id = Self.string(system["id"]).flatMap({ Int($0) }) else { continue }
            let medias = system["medias"] as? [[String: Any]] ?? []
            result[id] = ScrapedSystemMedia(logo: pickMedia(medias, types: ["logo-monochrome"]),
                                            photo: pickMedia(medias, types: ["photo"]))
        }
        return result
    }

    /// Downloads a media file into `destination`.
    @concurrent
    func download(_ url: URL, to destination: URL, maxWidth: Int) async throws {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "maxwidth", value: String(maxWidth)))
        components?.queryItems = items
        guard let requestURL = components?.url else { throw ScreenScraperError.invalidResponse }

        let (data, response) = try await Self.session.data(from: requestURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count > 64 else {
            throw ScreenScraperError.invalidResponse
        }
        // ScreenScraper answers with a short text body ("NOMEDIA", "CRCOK", …) when there is no image.
        if let text = String(data: data.prefix(16), encoding: .ascii), text.hasPrefix("NOMEDIA") || text.hasPrefix("CRCOK") {
            throw ScreenScraperError.invalidResponse
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    // MARK: - Networking

    private func request(_ endpoint: String, _ items: [URLQueryItem]) async throws -> [String: Any]? {
        var components = URLComponents(url: Self.baseURL.appending(path: endpoint), resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "devid", value: devID),
            URLQueryItem(name: "devpassword", value: devPassword),
            URLQueryItem(name: "softname", value: Self.softwareName),
            URLQueryItem(name: "output", value: "json"),
        ]
        if !username.isEmpty {
            query.append(URLQueryItem(name: "ssid", value: username))
            query.append(URLQueryItem(name: "sspassword", value: password))
        }
        components.queryItems = query + items
        // `+` must be encoded, URLComponents leaves it alone.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")

        let (data, response) = try await Self.session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse else { throw ScreenScraperError.invalidResponse }

        switch http.statusCode {
        case 200: break
        case 404: return nil // game not found
        case 400: return nil // malformed query (e.g. odd file names) — treat as not found
        case 401, 403: throw ScreenScraperError.invalidCredentials
        case 423: throw ScreenScraperError.serverClosed
        case 429: throw ScreenScraperError.tooManyThreads
        case 430, 431: throw ScreenScraperError.quotaExceeded
        default: throw ScreenScraperError.http(http.statusCode)
        }

        guard let object = try? JSONSerialization.jsonObject(with: Self.sanitize(data)) as? [String: Any] else {
            throw ScreenScraperError.invalidResponse
        }
        return object
    }

    /// ScreenScraper occasionally emits raw control characters inside strings.
    private static func sanitize(_ data: Data) -> Data {
        Data(data.map { $0 < 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 ? 0x20 : $0 })
    }

    // MARK: - Parsing

    func parse(_ game: [String: Any]) -> ScrapedGame? {
        guard let id = Self.string(game["id"]), !id.isEmpty, id != "0" else { return nil }
        if Self.string(game["notgame"]) == "true" { return nil }

        var result = ScrapedGame(screenScraperID: id)
        // ScreenScraper uses French typography ("Pokémon : Edition").
        result.title = pickRegional(game["noms"] as? [[String: Any]], key: "region", preferences: regionPreferences)?
            .replacingOccurrences(of: " : ", with: ": ")
        result.overview = pickRegional(game["synopsis"] as? [[String: Any]], key: "langue", preferences: languagePreferences)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        result.developer = Self.string((game["developpeur"] as? [String: Any])?["text"])
        result.publisher = Self.string((game["editeur"] as? [String: Any])?["text"])
        result.players = Self.string((game["joueurs"] as? [String: Any])?["text"])
        if let note = Self.string((game["note"] as? [String: Any])?["text"]), let value = Double(note) {
            result.rating = min(max(value / 20.0, 0), 1)
        }
        result.releaseDate = pickRegional(game["dates"] as? [[String: Any]], key: "region", preferences: regionPreferences)

        if let genres = game["genres"] as? [[String: Any]] {
            let main = genres.filter { Self.string($0["principale"]) == "1" }
            let chosen = (main.isEmpty ? genres : main).prefix(2)
            let names = chosen.compactMap { pickRegional($0["noms"] as? [[String: Any]], key: "langue", preferences: languagePreferences) }
            result.genre = names.isEmpty ? nil : names.joined(separator: ", ")
        }

        let medias = game["medias"] as? [[String: Any]] ?? []
        result.boxArt = pickMedia(medias, types: ["box-2D"])
        result.screenshot = pickMedia(medias, types: ["ss"])
        result.titleScreen = pickMedia(medias, types: ["sstitle"])
        result.logo = pickMedia(medias, types: ["wheel-hd", "wheel"])
        result.fanart = pickMedia(medias, types: ["fanart"])
        return result
    }

    var regionPreferences: [String] {
        var order: [String] = []
        if language == "de" { order.append("de") }
        if language == "fr" { order.append("fr") }
        if language == "es" { order.append("sp") }
        if language == "it" { order.append("it") }
        order += [region, "wor", "eu", "us", "ss", "jp"]
        var seen = Set<String>()
        return order.filter { seen.insert($0).inserted }
    }

    var languagePreferences: [String] {
        var seen = Set<String>()
        return [language, "en", "fr"].filter { seen.insert($0).inserted }
    }

    private func pickRegional(_ values: [[String: Any]]?, key: String, preferences: [String]) -> String? {
        guard let values, !values.isEmpty else { return nil }
        for preference in preferences {
            if let match = values.first(where: { Self.string($0[key]) == preference }), let text = Self.string(match["text"]) {
                return text
            }
        }
        return Self.string(values.first?["text"])
    }

    private func pickMedia(_ medias: [[String: Any]], types: [String]) -> URL? {
        for type in types {
            let candidates = medias.filter { Self.string($0["type"]) == type }
            guard !candidates.isEmpty else { continue }
            for preference in regionPreferences {
                if let match = candidates.first(where: { Self.string($0["region"]) == preference }),
                   let url = Self.string(match["url"]).flatMap(URL.init(string:)) {
                    return url
                }
            }
            if let url = Self.string(candidates.first?["url"]).flatMap(URL.init(string:)) { return url }
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: string.isEmpty ? nil : string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }
}
