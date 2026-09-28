// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftData
import SwiftUI

struct GameInspector: View {
    @Bindable var game: Game
    let play: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(MetadataService.self) private var metadata
    @Environment(EmulationSession.self) private var session
    @State private var expandedOverview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: 22) {
                    header
                    actions
                    if let overview = game.overview, !overview.isEmpty {
                        overviewSection(overview)
                    }
                    detailsSection
                    activitySection
                    settingsSection
                    fileSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ignoresSafeArea(edges: .top)
    }

    // MARK: Sections

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkImage(url: game.fanartURL ?? game.screenshotURL, maxPixel: 900, contentMode: .fill) {
                LinearGradient(colors: [Color(hex: game.system?.accent ?? 0x444444).opacity(0.8), .clear],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(height: 200)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.35),
                                       .init(color: Color(nsColor: .windowBackgroundColor), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }

            ArtworkImage(url: game.boxArtURL, maxPixel: 400) {
                PlaceholderCover(title: game.title, system: game.system)
                    .aspectRatio(game.system?.boxAspect ?? 0.72, contentMode: .fit)
            }
            .frame(maxWidth: 110, maxHeight: 130, alignment: .bottomLeading)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
            .padding(.leading, 20)
            .offset(y: 26)
        }
        .padding(.bottom, 42)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let logo = game.logoURL {
                ArtworkImage(url: logo, maxPixel: 600) { EmptyView() }
                    .frame(maxWidth: 220, maxHeight: 64, alignment: .leading)
                    .accessibilityLabel(game.title)
            }
            Text(game.title)
                .font(.title2.weight(.bold))
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(game.system?.name ?? game.systemID)
                if let year = game.releaseYear {
                    Text("·")
                    Text(year)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if let rating = game.rating {
                RatingView(value: rating)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(isStarting)

            Button {
                game.isFavorite.toggle()
                try? context.save()
            } label: {
                Image(systemName: game.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(game.isFavorite ? .pink : .primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .help(game.isFavorite ? "Remove from Favorites" : "Add to Favorites")

            Menu {
                Button("Refetch Metadata", systemImage: "arrow.triangle.2.circlepath") {
                    metadata.enqueue([game], force: true, context: context)
                }
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([game.fileURL])
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }

    private var isStarting: Bool {
        if case .preparing = session.phase { return true }
        return false
    }

    private func overviewSection(_ overview: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(overview)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(expandedOverview ? nil : 6)
                .textSelection(.enabled)
            Button(expandedOverview ? "Less" : "More") {
                withAnimation(.smooth) { expandedOverview.toggle() }
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    private var detailsSection: some View {
        InfoSection("Details") {
            InfoRow("Developer", game.developer)
            InfoRow("Publisher", game.publisher)
            InfoRow("Genre", game.genre)
            InfoRow("Players", game.players)
            InfoRow("Released", game.formattedReleaseDate)
            if game.scrapeState == .notFound {
                Text("No match on ScreenScraper.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
    private var settingsSection: some View {
        if let system = game.system, system.cores.count > 1 {
            InfoSection("Emulation") {
                Picker("Core", selection: Binding(
                    get: { game.coreID ?? "" },
                    set: { game.coreID = $0.isEmpty ? nil : $0; try? context.save() }
                )) {
                    Text("System Default (\(system.core(withID: Preferences.coreChoice(for: system.id)).name))").tag("")
                    Divider()
                    ForEach(system.cores) { core in
                        Text(core.name).tag(core.id)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var fileSection: some View {
        InfoSection("File") {
            InfoRow("Name", game.fileName)
            InfoRow("Size", ByteCountFormatter.string(fromByteCount: game.fileSize, countStyle: .file))
            InfoRow("CRC32", game.crc32)
        }
    }
}

struct InfoSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
            VStack(alignment: .leading, spacing: 6) {
                content
            }
        }
    }
}

struct InfoRow: View {
    let label: LocalizedStringKey
    let value: String?

    init(_ label: LocalizedStringKey, _ value: String?) {
        self.label = label
        self.value = value
    }

    var body: some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
                Text(value)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
        }
    }
}

struct RatingView: View {
    let value: Double

    var body: some View {
        let stars = value * 5
        HStack(spacing: 2) {
            ForEach(0..<5) { index in
                Image(systemName: Double(index) + 0.75 <= stars ? "star.fill" : (Double(index) + 0.25 <= stars ? "star.leadinghalf.filled" : "star"))
            }
        }
        .font(.caption)
        .foregroundStyle(.yellow)
        .accessibilityLabel(Text("Rating: \(Int((value * 100).rounded())) percent"))
    }
}
