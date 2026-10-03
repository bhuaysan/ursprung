// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What a file name says about its version of a game, following No-Intro
/// (“Game (Europe) (Rev 1)”) and GoodTools (“Game (E) [T+Ger] [!]”) naming.
nonisolated struct VariantInfo: Equatable, Sendable {
    enum Flag: String, CaseIterable, Sendable {
        case verified, alternate, badDump, hack, beta, prototype, demo, unlicensed, pirate, trainer, overdump, fixed
    }

    /// Canonical English region names (“USA”, “Europe”, “Germany” …).
    var regions: [String] = []
    /// Language codes the file lists, e.g. ["en", "fr", "de"].
    var languages: [String] = []
    /// “1”, “A” or “1.1”.
    var revision: String?
    /// Language code of a fan translation; “” when the tag names none.
    var translation: String?
    var flags: Set<Flag> = []
    var disc: Int?
    /// Discs in the set when the name says (“Disc 1 of 3”).
    var discCount: Int?
    /// The title without any tags, as the library shows it.
    var baseTitle: String

    /// Versions that are not the released game.
    var isUnofficial: Bool {
        translation != nil || !flags.isDisjoint(with: [.hack, .beta, .prototype, .demo, .pirate, .badDump, .trainer, .overdump])
    }

    // MARK: Parsing

    static func parse(fileName: String) -> VariantInfo {
        var info = VariantInfo(baseTitle: TitleFormatter.title(fromFileName: fileName))
        let name = (fileName as NSString).deletingPathExtension
        for (tag, isBracket) in tags(in: name) {
            if isBracket { info.readBracket(tag) } else { info.readParenthesis(tag) }
        }
        return info
    }

    /// The contents of `(…)` and `[…]` groups in order.
    private static func tags(in name: String) -> [(String, Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        var closing: Character?
        for character in name {
            if let close = closing {
                if character == close {
                    result.append((current.trimmingCharacters(in: .whitespaces), close == "]"))
                    current = ""
                    closing = nil
                } else {
                    current.append(character)
                }
            } else if character == "(" {
                closing = ")"
            } else if character == "[" {
                closing = "]"
            }
        }
        return result
    }

    private mutating func readParenthesis(_ tag: String) {
        let lower = tag.lowercased()
        if let disc = Self.disc(in: lower) {
            self.disc = disc.number
            discCount = disc.count
            return
        }
        if let revision = Self.revision(in: tag) {
            self.revision = revision
            return
        }
        switch lower {
        case "beta": flags.insert(.beta); return
        case "proto", "prototype": flags.insert(.prototype); return
        case "demo", "sample", "kiosk": flags.insert(.demo); return
        case "unl", "unlicensed": flags.insert(.unlicensed); return
        case "hack": flags.insert(.hack); return
        case "pirate": flags.insert(.pirate); return
        default: break
        }
        if lower.hasPrefix("beta ") { flags.insert(.beta); return }
        if lower.hasPrefix("proto ") { flags.insert(.prototype); return }
        if lower.hasPrefix("alt") { flags.insert(.alternate); return }
        if lower.hasPrefix("translated") {
            translation = Self.languageCode(String(tag.dropFirst("translated".count)).trimmingCharacters(in: .whitespaces)) ?? ""
            return
        }
        let parts = tag.split(whereSeparator: { $0 == "," || $0 == "+" }).map { $0.trimmingCharacters(in: .whitespaces) }
        let regions = parts.compactMap { Self.regionNames[$0.lowercased()] }
        if !regions.isEmpty, regions.count == parts.count {
            self.regions += regions
            return
        }
        if let codes = Self.goodToolsRegions(tag) {
            self.regions += codes
            return
        }
        let languages = parts.compactMap { $0.count == 2 ? Self.languageCode($0) : nil }
        if !languages.isEmpty, languages.count == parts.count {
            self.languages += languages
        }
    }

    private mutating func readBracket(_ tag: String) {
        let lower = tag.lowercased()
        if lower == "!" { flags.insert(.verified); return }
        if lower.hasPrefix("t+") || lower.hasPrefix("t-") {
            let rest = tag.dropFirst(2).split(separator: " ").first.map(String.init) ?? ""
            let letters = rest.prefix { $0.isLetter }
            translation = Self.languageCode(String(letters)) ?? ""
            return
        }
        guard let first = lower.first else { return }
        let isCode = lower.count == 1 || lower.dropFirst().allSatisfy { $0.isNumber || $0 == " " }
        guard isCode else {
            if lower.hasPrefix("hack") { flags.insert(.hack) }
            return
        }
        switch first {
        case "a": flags.insert(.alternate)
        case "b": flags.insert(.badDump)
        case "h": flags.insert(.hack)
        case "p": flags.insert(.pirate)
        case "t": flags.insert(.trainer)
        case "o": flags.insert(.overdump)
        case "f": flags.insert(.fixed)
        default: break
        }
    }

    /// “disc 2”, “cd 1”, “disk 1 of 3”.
    static func disc(in tag: String) -> (number: Int, count: Int?)? {
        let words = tag.lowercased().split(separator: " ")
        guard words.count == 2 || (words.count == 4 && words[2] == "of"),
              ["disc", "disk", "cd"].contains(words[0]),
              let number = Int(words[1]) else { return nil }
        return (number, words.count == 4 ? Int(words[3]) : nil)
    }

    private static func revision(in tag: String) -> String? {
        let lower = tag.lowercased()
        if lower.hasPrefix("rev ") {
            let value = tag.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        if lower.hasPrefix("v"), lower.count > 1, lower.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }) {
            return String(tag.dropFirst())
        }
        return nil
    }

    private static let regionNames: [String: String] = [
        "usa": "USA", "us": "USA", "america": "USA", "europe": "Europe", "eu": "Europe", "japan": "Japan",
        "world": "World", "germany": "Germany", "france": "France", "spain": "Spain", "italy": "Italy",
        "uk": "UK", "united kingdom": "UK", "australia": "Australia", "korea": "Korea", "china": "China",
        "brazil": "Brazil", "asia": "Asia", "canada": "Canada", "netherlands": "Netherlands", "sweden": "Sweden",
        "scandinavia": "Scandinavia", "taiwan": "Taiwan", "hong kong": "Hong Kong", "russia": "Russia",
        "portugal": "Portugal", "denmark": "Denmark", "finland": "Finland", "norway": "Norway", "poland": "Poland",
        "greece": "Greece", "austria": "Austria", "switzerland": "Switzerland", "belgium": "Belgium",
    ]

    private static let goodToolsCodes: [Character: String] = [
        "U": "USA", "E": "Europe", "J": "Japan", "W": "World", "G": "Germany", "F": "France", "S": "Spain",
        "I": "Italy", "K": "Korea", "B": "Brazil", "A": "Australia", "C": "China", "H": "Netherlands",
    ]

    /// GoodTools region codes such as “U”, “E” or “JUE”.
    private static func goodToolsRegions(_ tag: String) -> [String]? {
        guard (1...3).contains(tag.count), tag == tag.uppercased() else { return nil }
        let regions = tag.compactMap { goodToolsCodes[$0] }
        return regions.count == tag.count ? regions : nil
    }

    private static let languageAbbreviations: [String: String] = [
        "eng": "en", "ger": "de", "deu": "de", "fre": "fr", "fra": "fr", "spa": "es", "esp": "es", "ita": "it",
        "por": "pt", "bra": "pt", "rus": "ru", "jap": "ja", "jpn": "ja", "chi": "zh", "kor": "ko", "pol": "pl",
        "dut": "nl", "swe": "sv", "nor": "no", "dan": "da", "fin": "fi", "gre": "el", "tur": "tr", "ara": "ar",
        "heb": "he", "hun": "hu", "cze": "cs", "cat": "ca",
    ]

    /// A two-letter code (“De”) or a common abbreviation (“Ger”) as an ISO code.
    static func languageCode(_ text: String) -> String? {
        let lower = text.lowercased()
        if lower.count == 2, lower.allSatisfy(\.isLetter) {
            return Locale.LanguageCode(lower).isISOLanguage ? lower : nil
        }
        return languageAbbreviations[lower]
    }

    // MARK: Display

    /// A short description of the version, e.g. “Europe · Rev 1” or
    /// “USA · Translation (German)”. Empty when the name has no tags.
    var label: String {
        var parts: [String] = []
        if !regions.isEmpty { parts.append(regions.map(Self.regionTitle).joined(separator: ", ")) }
        if let revision { parts.append(String(localized: "Rev \(revision)")) }
        if let translation {
            parts.append(translation.isEmpty ? String(localized: "Translation")
                : String(localized: "Translation (\(Self.languageTitle(translation)))"))
        }
        for flag in Flag.allCases where flags.contains(flag) && flag != .verified && flag != .fixed {
            parts.append(flag.title)
        }
        if parts.isEmpty, !languages.isEmpty {
            parts.append(languages.map { $0.uppercased() }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    static func regionTitle(_ region: String) -> String {
        switch region {
        case "Europe": String(localized: "Europe")
        case "World": String(localized: "World")
        case "Asia": String(localized: "Asia")
        case "Scandinavia": String(localized: "Scandinavia")
        default:
            regionCodes[region].flatMap { Locale.current.localizedString(forRegionCode: $0) } ?? region
        }
    }

    private static let regionCodes: [String: String] = [
        "USA": "US", "Japan": "JP", "Germany": "DE", "France": "FR", "Spain": "ES", "Italy": "IT", "UK": "GB",
        "Australia": "AU", "Korea": "KR", "China": "CN", "Brazil": "BR", "Canada": "CA", "Netherlands": "NL",
        "Sweden": "SE", "Taiwan": "TW", "Hong Kong": "HK", "Russia": "RU", "Portugal": "PT", "Denmark": "DK",
        "Finland": "FI", "Norway": "NO", "Poland": "PL", "Greece": "GR", "Austria": "AT", "Switzerland": "CH",
        "Belgium": "BE",
    ]

    static func languageTitle(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }
}

nonisolated extension VariantInfo.Flag {
    var title: String {
        switch self {
        case .verified: String(localized: "Verified")
        case .alternate: String(localized: "Alternate")
        case .badDump: String(localized: "Bad Dump")
        case .hack: String(localized: "Hack")
        case .beta: String(localized: "Beta")
        case .prototype: String(localized: "Prototype")
        case .demo: String(localized: "Demo")
        case .unlicensed: String(localized: "Unlicensed")
        case .pirate: String(localized: "Pirate")
        case .trainer: String(localized: "Trainer")
        case .overdump: String(localized: "Overdump")
        case .fixed: String(localized: "Fixed")
        }
    }
}

/// Groups the files that are versions of one game and picks the one to show.
nonisolated enum VariantGrouping {
    /// Files with the same key are versions of one game: same system, same
    /// title once tags are removed, and the same disc of a multi-disc set.
    static func key(systemID: String, info: VariantInfo) -> String {
        let title = info.baseTitle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
        return [systemID, title, info.disc.map(String.init) ?? ""].joined(separator: "|")
    }

    /// Regions in the order the user most likely wants them, from the
    /// metadata region (Settings › Metadata) and the system language.
    static func regionOrder(scraperRegion: String, languageCode: String) -> [String] {
        let local: [String] = switch languageCode {
        case "de": ["Germany", "Austria", "Switzerland"]
        case "fr": ["France", "Belgium"]
        case "es": ["Spain"]
        case "it": ["Italy"]
        case "nl": ["Netherlands", "Belgium"]
        case "sv": ["Sweden", "Scandinavia"]
        default: []
        }
        return switch scraperRegion {
        case "us": ["USA", "World", "Canada", "Europe", "UK", "Australia", "Japan"]
        case "jp": ["Japan", "World", "Asia", "USA", "Europe"]
        default: local + ["Europe", "World", "UK", "Australia", "USA", "Japan"]
        }
    }

    /// How good a version is as the one to show; larger is better.
    static func score(_ info: VariantInfo, regionOrder: [String], languageCode: String) -> [Int] {
        let regionRank = info.regions.compactMap { regionOrder.firstIndex(of: $0) }.min().map { regionOrder.count - $0 } ?? 0
        let speaksLanguage = info.languages.contains(languageCode) || info.translation == languageCode
        let revision = info.revision.map { Int($0.filter(\.isNumber)) ?? ($0.first?.asciiValue.map(Int.init) ?? 0) } ?? 0
        return [
            info.isUnofficial ? 0 : 1,
            info.flags.contains(.unlicensed) || info.flags.contains(.alternate) ? 0 : 1,
            regionRank,
            speaksLanguage ? 1 : 0,
            info.flags.contains(.verified) ? 1 : 0,
            revision,
        ]
    }
}
