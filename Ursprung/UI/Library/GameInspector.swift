// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftData
import SwiftUI

/// Masked artwork, a compact title block, one action row and plain text
/// sections. See docs/DESIGN_SPEC.md, section G.
struct GameInspector: View {
    let game: Game
    let actions: GameActions
    /// Every version of the game, the shown one first.
    var versions: [Game] = []
    /// Whether the library shows one card for all versions.
    var showsGroupedVersions = true
    var versionActions: VersionActions?

    @Environment(EmulationSession.self) private var session
    @Environment(BIOSManager.self) private var bios
    @Environment(\.openSettings) private var openSettings
    @AppStorage(PrefKey.settingsTab) private var settingsTab = SettingsTab.general
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedOverview = false
    @State private var isEditingControls = false

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
                    organizeSection
                    if versions.count > 1 {
                        versionsSection
                    }
                    activitySection
                    MediaSection(game: game)
                    emulationSection
                    discsSection
                    if game.system?.supportsPatches == true {
                        PatchesSection(game: game)
                    }
                    CheatsSection(game: game)
                    ManualSection(game: game)
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
                        Label(actions.playTitle, systemImage: "play.fill")
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
            if state == .notFound {
                Button("Choose Match…", action: actions.chooseMatch)
                    .buttonStyle(.link)
            } else {
                Button("Refetch", action: actions.refetchMetadata)
                    .buttonStyle(.link)
            }
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

    private var organizeSection: some View {
        InfoSection("Organize") {
            InfoRowLayout("Status") {
                Picker("Status", selection: Binding(get: { game.playStatus }, set: { actions.organize.setStatus($0) })) {
                    Text(verbatim: "–").tag(PlayStatus?.none)
                    Divider()
                    ForEach(PlayStatus.allCases) { status in
                        Label(status.title, systemImage: status.symbol).tag(PlayStatus?.some(status))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 180, alignment: .leading)
            }
            CollectionToggles(actions: actions.organize)
        }
    }

    /// The other files of this game: regions, revisions, translations, hacks.
    private var versionsSection: some View {
        InfoSection("Versions") {
            ForEach(versions, id: \.persistentModelID) { version in
                VersionRow(version: version, isCurrent: version === game,
                           isShown: showsGroupedVersions && version === versions.first,
                           isDuplicate: isDuplicate(version), actions: versionActions)
            }
        }
    }

    private func isDuplicate(_ version: Game) -> Bool {
        guard let crc = version.crc32 else { return false }
        return versions.contains { $0 !== version && $0.crc32?.caseInsensitiveCompare(crc) == .orderedSame }
    }

    private var activitySection: some View {
        InfoSection("Activity") {
            InfoRow("Last Played", game.lastPlayed.map { $0.formatted(.relative(presentation: .named)) } ?? String(localized: "Never"))
            InfoRow("Play Time", game.playTime > 0 ? Duration.seconds(game.playTime).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) : "–")
            InfoRow("Sessions", game.playCount > 0 ? String(game.playCount) : "–")
            InfoRow("Added", game.dateAdded.formatted(date: .abbreviated, time: .omitted))
            InfoRowLayout("Save States") {
                HStack(spacing: AppSpacing.s) {
                    let count = stateCount
                    Text(count > 0 ? String(count) : "–")
                    if count > 0 {
                        Button("Show…", action: actions.showSaveStates)
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }

    /// Slots and automatic states of all cores; replaced ones are not counted.
    private var stateCount: Int {
        SaveStateStore.allStates(in: AppPaths.states, gameID: game.id)
            .reduce(0) { $0 + $1.slots.count + ($1.autosave == nil ? 0 : 1) }
    }

    /// The discs of a playlist, or the loose discs this one belongs to.
    @ViewBuilder
    private var discsSection: some View {
        if let discs = actions.discs {
            InfoSection("Discs") {
                switch discs.kind {
                case .edit:
                    let entries = DiscPlaylist.read(game.fileURL)?.entries ?? []
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        InfoRow("Disc \(index + 1)", entry.label ?? (entry.path as NSString).lastPathComponent)
                    }
                    let numbers = entries.compactMap { VariantInfo.parse(fileName: ($0.path as NSString).lastPathComponent).disc }
                    let declared = entries.compactMap { VariantInfo.parse(fileName: ($0.path as NSString).lastPathComponent).discCount }.max()
                    let missing = DiscSets.missingDiscs(numbers, declaredCount: declared)
                    if !missing.isEmpty {
                        StatusLabel("Disc \(missing.map(String.init).formatted(.list(type: .and))) isn't in the playlist",
                                    kind: .warning, prominent: true)
                            .font(.callout)
                    }
                case .create:
                    Text("This disc has no playlist yet, so each disc is a game of its own. A playlist lets you change discs from the pause menu.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(discs.title, action: discs.perform)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    private var emulationSection: some View {
        if let system = game.system {
            InfoSection("Emulation") {
                readiness(system)
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
                InfoRowLayout("Controls") {
                    HStack(spacing: AppSpacing.s) {
                        Text(game.inputProfileData == nil ? "Same as System" : "Custom")
                        Button("Edit…") { isEditingControls = true }
                            .buttonStyle(.link)
                    }
                }
                InfoRowLayout("Shader") {
                    GameShaderPicker(gameID: game.id, systemID: system.id)
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 180, alignment: .leading)
                }
            }
            .sheet(isPresented: $isEditingControls) {
                GameControlsEditor(game: game)
            }
        }
    }

    /// What keeps the game from starting, each with the action that fixes it.
    /// "Recognized" is not "ready": a disc may lack tracks, a core a BIOS.
    @ViewBuilder
    private func readiness(_ system: GameSystem) -> some View {
        let missingBIOS = bios.missingRequired(for: system, coreID: game.effectiveCore?.id)
        if !game.missingTracks.isEmpty {
            issueRow(StatusLabel("Disc files missing", kind: .warning, prominent: true,
                                 detail: game.missingTracks.joined(separator: ", ")),
                     action: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.fileURL]) }
        }
        if !missingBIOS.isEmpty {
            issueRow(StatusLabel("BIOS missing", kind: .error, prominent: true,
                                 detail: missingBIOS.map(\.fileName).joined(separator: ", ")),
                     action: "Import…") {
                settingsTab = .bios
                openSettings()
            }
        }
    }

    private func issueRow(_ label: StatusLabel, action: LocalizedStringKey, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
            label
            Spacer(minLength: AppSpacing.s)
            Button(action, action: perform)
                .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.bottom, AppSpacing.xxs)
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

/// Playing a particular version, or making it the one the library shows.
struct VersionActions {
    let play: (Game) -> Void
    let prefer: (Game) -> Void
}

/// One version in the inspector: what sets it apart, and its actions.
private struct VersionRow: View {
    let version: Game
    /// The version this inspector shows.
    let isCurrent: Bool
    /// The version the library's card stands for.
    let isShown: Bool
    /// Another version is the identical file.
    let isDuplicate: Bool
    let actions: VersionActions?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                HStack(spacing: AppSpacing.xs) {
                    Text(verbatim: version.variantLabel)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .lineLimit(2)
                    if version.isFavorite {
                        Image(systemName: "heart.fill")
                            .imageScale(.small)
                            .foregroundStyle(.favorite)
                            .accessibilityLabel("Favorite")
                    }
                }
                Text(verbatim: details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(version.fileName)
            }
            Spacer(minLength: AppSpacing.s)
            if let actions {
                Menu {
                    Button("Play", systemImage: "play.fill") { actions.play(version) }
                    Button("Show This Version", systemImage: "checkmark.circle") { actions.prefer(version) }
                        .disabled(isShown || isCurrent && version.isPreferredVariant)
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([version.fileURL])
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Version Actions")
                .accessibilityLabel(Text("Actions for \(version.variantLabel)"))
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts: [String] = []
        if isShown { parts.append(String(localized: "Shown in Library")) }
        if version.variantInfo.flags.contains(.verified) { parts.append(String(localized: "Verified")) }
        if isDuplicate { parts.append(String(localized: "Identical File")) }
        if version.isMissing { parts.append(String(localized: "File Missing")) }
        parts.append(version.fileName)
        return parts.joined(separator: " · ")
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

/// The game's own filter or preset; "Same as System" when it has none.
private struct GameShaderPicker: View {
    let gameID: UUID
    let systemID: String

    @State private var selection: ShaderSelection?
    /// Bumped when preferences change, e.g. from the player's shader panel.
    @State private var revision = 0

    var body: some View {
        let _ = revision
        ShaderPicker(title: "Shader", selection: Binding(get: { selection }, set: { choose($0) }),
                     inheritTitle: String(localized: "Same as System (\(ShaderSelection.current(for: systemID).title))"))
            .onChange(of: gameID, initial: true) { load() }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                load()
                revision += 1
            }
    }

    private func load() {
        let stored = ShaderScope.game(gameID).selection()
        if stored != selection { selection = stored }
    }

    private func choose(_ value: ShaderSelection?) {
        selection = value
        ShaderScope.game(gameID).setSelection(value)
    }
}
