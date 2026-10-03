// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftData
import SwiftUI

/// Masked artwork, a compact title block, one action row and plain text
/// sections. See docs/DESIGN_SPEC.md, section G.
struct GameInspector: View {
    let game: Game
    let actions: GameActions

    @Environment(EmulationSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedOverview = false

    /// How far the box art reaches below the hero.
    private static let boxArtOverlap: CGFloat = 32

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                artwork
                titleBlock
                    .padding(.top, AppSpacing.m)
                actionRow
                    .padding(.top, AppSpacing.l)
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    if game.isMissing {
                        missingFileRow
                    }
                    if let overview = game.overview, !overview.isEmpty {
                        overviewSection(overview)
                    }
                    detailsSection
                    activitySection
                    emulationSection
                    fileSection
                }
                .padding(.top, AppSpacing.xl)
                .padding(.horizontal, AppSpacing.l)
                .padding(.bottom, AppSpacing.xl)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        // Only the hero reaches up under the toolbar; without it the box art
        // starts below the toolbar like any other content.
        .ignoresSafeArea(edges: heroURL == nil ? [] : .top)
    }

    // MARK: Artwork

    private var heroURL: URL? {
        game.fanartURL ?? game.screenshotURL
    }

    @ViewBuilder
    private var artwork: some View {
        if let heroURL {
            hero(heroURL)
                .overlay(alignment: .bottomLeading) {
                    boxArt
                        .padding(.leading, AppSpacing.l)
                        .offset(y: Self.boxArtOverlap)
                }
                .padding(.bottom, Self.boxArtOverlap)
        } else {
            boxArt
                .padding(.top, AppSpacing.l)
                .padding(.leading, AppSpacing.l)
        }
    }

    private func hero(_ url: URL) -> some View {
        // The image fills a 16:9 slot that takes the column's width; on its own
        // a filled image is as wide as its aspect ratio makes it and keeps the
        // inspector from getting narrower.
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                ArtworkImage(url: url, maxPixel: 900, contentMode: .fill, fadesIn: true) { Color.clear }
            }
            .clipped()
            // A mask rather than a colour overlay fades into whatever surface
            // is behind it, in Light and Dark Mode.
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .accessibilityHidden(true)
    }

    private var boxArt: some View {
        ArtworkImage(url: game.boxArtURL, maxPixel: 400) {
            PlaceholderCover(title: game.title, system: game.system)
                .aspectRatio(game.system?.boxAspect ?? 0.72, contentMode: .fit)
        }
        .artworkFrame(radius: AppMetrics.smallArtworkRadius)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        .frame(maxWidth: 96, maxHeight: 128, alignment: .bottomLeading)
        .accessibilityHidden(true)
    }

    // MARK: Title and actions

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(game.title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: [game.system?.name ?? game.systemID, game.releaseYear]
                .compactMap { $0 }
                .joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let rating = game.rating {
                RatingView(value: rating)
                    .padding(.top, AppSpacing.xxs)
            }
        }
        .padding(.horizontal, AppSpacing.l)
    }

    private var actionRow: some View {
        HStack(spacing: AppSpacing.s) {
            Button(action: actions.play) {
                HStack(spacing: AppSpacing.s) {
                    if isStarting {
                        ProgressView()
                            .controlSize(.small)
                        Text("Starting…")
                    } else {
                        Label("Play", systemImage: "play.fill")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(isStarting)

            Button(action: actions.toggleFavorite) {
                Image(systemName: game.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(game.isFavorite ? .favorite : .primary)
                    .contentTransition(.symbolEffect(.replace))
                    .modifier(RoundGlassLabel())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(actions.favoriteTitle)
            .accessibilityLabel("Favorite")
            .accessibilityValue(game.isFavorite ? Text("On") : Text("Off"))
            .accessibilityAddTraits(.isToggle)

            Menu {
                GameActionItems(actions: actions, placement: .inspectorMenu)
            } label: {
                Image(systemName: "ellipsis")
                    .modifier(RoundGlassLabel())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help("More Actions")
            .accessibilityLabel("More Actions")
        }
        .padding(.horizontal, AppSpacing.l)
    }

    private var isStarting: Bool {
        if case .preparing = session.phase { return true }
        return false
    }

    // MARK: Sections

    private func overviewSection(_ overview: String) -> some View {
        InfoSection("Overview") {
            Text(overview)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(expandedOverview ? nil : 6)
                .textSelection(.enabled)
            Button(expandedOverview ? "Less" : "More") {
                withAppAnimation(AppAnimation.standard, reduceMotion: reduceMotion) { expandedOverview.toggle() }
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    @ViewBuilder
    private var detailsSection: some View {
        let details: [(LocalizedStringKey, String?)] = [
            ("Developer", game.developer),
            ("Publisher", game.publisher),
            ("Genre", game.genre),
            ("Players", game.players),
            ("Released", game.formattedReleaseDate),
        ]
        let hasDetails = details.contains { !($0.1 ?? "").isEmpty }
        if hasDetails || metadataStatus != nil {
            InfoSection("Details") {
                if let metadataStatus {
                    metadataStatusRow(metadataStatus)
                }
                ForEach(details.indices, id: \.self) { index in
                    InfoRow(details[index].0, details[index].1)
                }
            }
        }
    }

    private var metadataStatus: ScrapeState? {
        switch game.scrapeState {
        case .notFound, .failed: game.scrapeState
        case .pending, .matched: nil
        }
    }

    /// Inline status row (section H): symbol, text and a Refetch link.
    private func metadataStatusRow(_ state: ScrapeState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
            if state == .failed {
                StatusLabel("Metadata couldn't be fetched", kind: .warning, prominent: true)
            } else {
                StatusLabel("No match on ScreenScraper", systemImage: "questionmark.circle", kind: .neutral, prominent: true)
            }
            Spacer(minLength: AppSpacing.s)
            Button("Refetch", action: actions.refetchMetadata)
                .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.bottom, AppSpacing.xxs)
    }

    /// The game's file is gone; it keeps its data until the file is located.
    private var missingFileRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
            StatusLabel("File missing", kind: .warning, prominent: true,
                        detail: String(localized: "Favorites, play time and saves are kept."))
            Spacer(minLength: AppSpacing.s)
            Button("Locate…", action: actions.locate)
                .buttonStyle(.link)
        }
        .font(.callout)
    }

    private var activitySection: some View {
        InfoSection("Activity") {
            InfoRow("Last Played", game.lastPlayed.map { $0.formatted(.relative(presentation: .named)) } ?? String(localized: "Never"))
            InfoRow("Play Time", game.playTime > 0 ? Duration.seconds(game.playTime).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) : "–")
            InfoRow("Sessions", game.playCount > 0 ? String(game.playCount) : "–")
            InfoRow("Added", game.dateAdded.formatted(date: .abbreviated, time: .omitted))
        }
    }

    @ViewBuilder
    private var emulationSection: some View {
        if let system = game.system {
            InfoSection("Emulation") {
                if system.cores.count > 1 {
                    InfoRowLayout("Core") {
                        GameCorePicker(actions: actions)
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .controlSize(.small)
                            // Not fixedSize: the picker's ideal width, set by the
                            // longest core name, became the column's width.
                            .frame(maxWidth: 180, alignment: .leading)
                    }
                } else {
                    InfoRow("Core", system.defaultCore.name)
                }
            }
        }
    }

    private var fileSection: some View {
        InfoSection("File") {
            InfoRow("Name", game.fileName, isCode: true)
            if game.isMissing {
                InfoRow("Last Location", game.fileURL.deletingLastPathComponent().path(percentEncoded: false), isCode: true)
            }
            InfoRow("Size", ByteCountFormatter.string(fromByteCount: game.fileSize, countStyle: .file))
            InfoRow("CRC32", game.crc32, isCode: true)
        }
    }
}

/// Favorite and More Actions: round glass buttons as tall as Play. A glass
/// button style draws a menu smaller than a button, so both draw their own size.
private struct RoundGlassLabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.body)
            .frame(width: 28, height: 28)
            .contentShape(.circle)
    }
}

/// A titled group of inspector rows, separated from the next by space only.
struct InfoSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 6) {
                content
            }
        }
    }
}

/// A text row; rows without a value are left out.
struct InfoRow: View {
    let label: LocalizedStringKey
    let value: String?
    /// File names and checksums: monospaced, one line, shortened in the middle.
    var isCode = false

    init(_ label: LocalizedStringKey, _ value: String?, isCode: Bool = false) {
        self.label = label
        self.value = value
        self.isCode = isCode
    }

    var body: some View {
        if let value, !value.isEmpty {
            InfoRowLayout(label) {
                if isCode {
                    Text(value)
                        .monospaced()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(value)
                } else {
                    Text(value)
                        .textSelection(.enabled)
                }
            }
            // One element: combining selectable text keeps only the label.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityValue(value)
        }
    }
}

/// Label column and value, for rows whose value is not plain text. The label
/// is hidden from VoiceOver: a control in the value column carries its own.
struct InfoRowLayout<Value: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let value: Value

    init(_ label: LocalizedStringKey, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
            Text(label)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                // 96 rather than the spec's 88 pt: “Zuletzt gespielt” needs it.
                .frame(width: 96, alignment: .leading)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

/// Five stars, filled or outlined; the shape carries the value, not colour.
struct RatingView: View {
    /// 0…1
    let value: Double

    var body: some View {
        let stars = Self.stars(for: value)
        HStack(spacing: 2) {
            ForEach(0..<5) { index in
                Image(systemName: index < stars ? "star.fill" : "star")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Rating: \(stars) of 5 stars"))
    }

    /// Whole stars for a 0…1 rating.
    nonisolated static func stars(for value: Double) -> Int {
        Int((min(max(value, 0), 1) * 5).rounded())
    }
}
