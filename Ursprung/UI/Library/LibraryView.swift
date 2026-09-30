// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftData
import SwiftUI

enum LibrarySelection: Hashable {
    case all, favorites, recent
    case system(String)
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case title, recentlyAdded, recentlyPlayed, releaseYear
    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .title: "Title"
        case .recentlyAdded: "Recently Added"
        case .recentlyPlayed: "Recently Played"
        case .releaseYear: "Release Year"
        }
    }
}

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @Environment(LibraryStore.self) private var library
    @Environment(MetadataService.self) private var metadata
    @Environment(EmulationSession.self) private var session
    @Environment(SystemMediaStore.self) private var systemMedia

    @Query(sort: \Game.title) private var games: [Game]

    @State private var selection: LibrarySelection? = .all
    @State private var selectedGameID: PersistentIdentifier?
    @State private var searchText = ""
    @State private var columns = ColumnLayoutState()
    @State private var gamePendingRemoval: Game?
    @AppStorage(PrefKey.librarySort) private var sort: LibrarySort = .title
    @AppStorage(PrefKey.gridSize) private var gridSize = AppMetrics.defaultCoverStep

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            SidebarView(games: games, selection: $selection)
                .navigationSplitViewColumnWidth(min: AppMetrics.sidebarWidth.min, ideal: AppMetrics.sidebarWidth.ideal,
                                                max: AppMetrics.sidebarWidth.max)
                .onGeometryChange(for: Double.self) { $0.size.width } action: { width in
                    columns.update { $0.measure(sidebar: width) }
                }
        } detail: {
            content
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .inspector(isPresented: inspectorPresented) {
                    Group {
                        if let game = selectedGame {
                            GameInspector(game: game, actions: actions(for: game))
                        } else {
                            ContentUnavailableView("No Game Selected", systemImage: "square.stack",
                                                   description: Text("Select a game to see its details."))
                        }
                    }
                    .inspectorColumnWidth(min: AppMetrics.inspectorWidth.min, ideal: AppMetrics.inspectorWidth.ideal,
                                          max: AppMetrics.inspectorWidth.max)
                    .onGeometryChange(for: Double.self) { $0.size.width } action: { width in
                        columns.update { $0.measure(inspector: width) }
                    }
                }
        }
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width in columns.update { $0.resize(to: width) } }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search Games")
        .toolbar { toolbar }
        .focusedSceneValue(\.modelContext, context)
        .focusedSceneValue(\.gameActions, selectedGame.map(actions(for:)))
        .confirmationDialog(Text("Remove “\(gamePendingRemoval?.title ?? "")” from the library?"),
                            isPresented: Binding(get: { gamePendingRemoval != nil },
                                                 set: { if !$0 { gamePendingRemoval = nil } }),
                            presenting: gamePendingRemoval) { game in
            Button("Remove", role: .destructive) { remove(game) }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { _ in
            Text("The file stays on disk. Play time and favorite status are lost, and the next rescan adds the game again.")
        }
        .task(id: librarySystems.map(\.id)) {
            if Preferences.autoScrape { await systemMedia.fetchMissing(for: librarySystems) }
        }
        .task {
            if !library.folders.isEmpty { await library.rescan(context: context) }
            #if DEBUG
            // Development aid: URSPRUNG_AUTOPLAY=<title substring> starts a game on launch.
            if let query = ProcessInfo.processInfo.environment["URSPRUNG_AUTOPLAY"],
               let game = games.first(where: { $0.title.localizedStandardContains(query) || $0.fileName.localizedStandardContains(query) }) {
                play(game)
            }
            if let systemID = ProcessInfo.processInfo.environment["URSPRUNG_SYSTEM"] {
                selection = .system(systemID)
            }
            if let query = ProcessInfo.processInfo.environment["URSPRUNG_SELECT"] {
                selectedGameID = games.first { $0.title.localizedStandardContains(query) }?.persistentModelID
            }
            #endif
        }
    }

    // MARK: Columns

    /// The user's sidebar toggle; automatic changes do not go through the binding.
    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding {
            columns.showsSidebar ? .all : .detailOnly
        } set: { visibility in
            let visible = visibility != .detailOnly
            if visible != columns.showsSidebar { columns.update { $0.setSidebar(visible) } }
        }
    }

    private var inspectorPresented: Binding<Bool> {
        Binding {
            columns.showsInspector
        } set: { visible in
            if visible != columns.showsInspector { columns.update { $0.setInspector(visible) } }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if library.folders.isEmpty {
            EmptyLibraryView { library.presentAddFolderPanel(context: context) }
        } else if filteredGames.isEmpty {
            if library.isScanning {
                ProgressView("Scanning library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ContentUnavailableView(emptyTitle, systemImage: "gamecontroller",
                                       description: Text(emptyDescription))
            }
        } else {
            GameGridView(games: filteredGames, selectedGameID: $selectedGameID, coverStep: CoverSize.snapped(gridSize),
                         system: selectedSystem, actions: actions(for:))
        }
    }

    private var filteredGames: [Game] {
        var result: [Game]
        switch selection ?? .all {
        case .all: result = games
        case .favorites: result = games.filter(\.isFavorite)
        case .recent: result = games.filter { $0.lastPlayed != nil }
        case .system(let id): result = games.filter { $0.systemID == id }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedStandardContains(searchText)
                    || ($0.developer?.localizedStandardContains(searchText) ?? false)
                    || ($0.genre?.localizedStandardContains(searchText) ?? false)
            }
        }
        if selection == .recent {
            return result.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        }
        switch sort {
        case .title: return result
        case .recentlyAdded: return result.sorted { $0.dateAdded > $1.dateAdded }
        case .recentlyPlayed: return result.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        case .releaseYear: return result.sorted { ($0.releaseDate ?? "9999") < ($1.releaseDate ?? "9999") }
        }
    }

    private var selectedSystem: GameSystem? {
        if case .system(let id) = selection { SystemCatalog.system(withID: id) } else { nil }
    }

    /// Systems with at least one game, in catalog order.
    private var librarySystems: [GameSystem] {
        let ids = Set(games.map(\.systemID))
        return SystemCatalog.all.filter { ids.contains($0.id) }
    }

    private var selectedGame: Game? {
        guard let selectedGameID else { return nil }
        return games.first { $0.persistentModelID == selectedGameID }
    }

    private var title: String {
        switch selection ?? .all {
        case .all: String(localized: "All Games")
        case .favorites: String(localized: "Favorites")
        case .recent: String(localized: "Recently Played")
        case .system(let id): SystemCatalog.system(withID: id)?.name ?? id
        }
    }

    private var subtitle: String {
        let count = filteredGames.count
        return count == 1 ? String(localized: "1 game") : String(localized: "\(count) games")
    }

    private var emptyTitle: LocalizedStringKey {
        switch selection ?? .all {
        case .favorites: "No Favorites Yet"
        case .recent: "Nothing Played Yet"
        default: "No Games Found"
        }
    }

    private var emptyDescription: LocalizedStringKey {
        switch selection ?? .all {
        case .favorites: "Mark games with the heart button to find them here."
        case .recent: "Games you play will show up here."
        default: "Ursprung didn't find any games in your library folders."
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if metadata.isRunning {
                ScrapeProgressView()
            }
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                CoverSizeItems()
            } label: {
                Label("View Options", systemImage: "line.3.horizontal.decrease")
            }
            .menuIndicator(.hidden)

            Menu {
                Button("Add Folder…", systemImage: "folder.badge.plus") { library.presentAddFolderPanel(context: context) }
                Button("Rescan Library", systemImage: "arrow.clockwise") { Task { await library.rescan(context: context) } }
                    .disabled(library.isScanning)
                Divider()
                Button("Fetch Missing Metadata", systemImage: "sparkles") {
                    metadata.enqueue(games, context: context)
                    Task { await systemMedia.fetchMissing(for: librarySystems, retry: true) }
                }
                Button("Refetch All Metadata", systemImage: "arrow.triangle.2.circlepath") {
                    metadata.enqueue(games, force: true, context: context)
                }
            } label: {
                Label("Library", systemImage: "plus")
            }
            .menuIndicator(.hidden)

            Button {
                let visible = !columns.showsInspector
                columns.update { $0.setInspector(visible) }
            } label: {
                Label("Info", systemImage: "info.circle")
            }
        }
    }

    // MARK: Actions

    private func play(_ game: Game) {
        selectedGameID = game.persistentModelID
        openWindow(id: WindowID.player)
        Task { await session.launch(game, context: context) }
    }

    private func actions(for game: Game) -> GameActions {
        GameActions(
            game: game,
            play: { play(game) },
            toggleFavorite: {
                game.isFavorite.toggle()
                try? context.save()
            },
            refetchMetadata: { metadata.enqueue([game], force: true, context: context) },
            showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([game.fileURL]) },
            setCore: { coreID in
                game.coreID = coreID
                try? context.save()
            },
            requestRemoval: { gamePendingRemoval = game }
        )
    }

    private func remove(_ game: Game) {
        if selectedGameID == game.persistentModelID { selectedGameID = nil }
        library.remove(game, context: context)
    }
}

struct ScrapeProgressView: View {
    @Environment(MetadataService.self) private var metadata

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: metadata.progress)
                .progressViewStyle(.circular)
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 0) {
                Text("Fetching metadata")
                    .font(.caption.weight(.medium))
                Text("\(metadata.completed + 1) of \(metadata.total)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button {
                metadata.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Stop fetching metadata")
        }
        .padding(.horizontal, 6)
        .help(metadata.currentTitle ?? "")
    }
}

struct EmptyLibraryView: View {
    let addFolder: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Welcome to Ursprung", systemImage: "gamecontroller")
        } description: {
            Text("Add a folder with your games to get started. Ursprung recognises the system from file types and folder names, and fetches covers and details from ScreenScraper.")
        } actions: {
            Button("Add Folder…", action: addFolder)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
    }
}
