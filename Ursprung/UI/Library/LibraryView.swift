// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftData
import SwiftUI

nonisolated enum LibrarySelection: Hashable {
    case all, favorites, recent
    case system(String)
}

/// What the content column shows. See docs/DESIGN_SPEC.md, section H.
nonisolated enum LibraryState: Equatable {
    case welcome
    /// The first scan is running and no game is known yet.
    case scanning
    case noGames
    case noResults(query: String)
    case noFavorites
    case nothingPlayed
    case games

    init(hasFolders: Bool, isScanning: Bool, libraryCount: Int, visibleCount: Int, searchText: String,
         selection: LibrarySelection) {
        if !hasFolders {
            self = .welcome
        } else if visibleCount > 0 {
            self = .games
        } else if libraryCount == 0 {
            // A scan with games already known keeps the grid; progress is in the activity footer.
            self = isScanning ? .scanning : .noGames
        } else if !searchText.isEmpty {
            self = .noResults(query: searchText)
        } else {
            switch selection {
            case .favorites: self = .noFavorites
            case .recent: self = .nothingPlayed
            // A system without games has no sidebar row; LibraryView falls back to All Games.
            case .all, .system: self = .games
            }
        }
    }
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
    @Environment(\.openSettings) private var openSettings
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
    @State private var isConfirmingRefetch = false
    @State private var unavailableGame: UnavailableGame?
    @AppStorage(PrefKey.librarySort) private var sort: LibrarySort = .title
    @AppStorage(PrefKey.gridSize) private var gridSize = AppMetrics.defaultCoverStep
    @AppStorage(PrefKey.settingsTab) private var settingsTab = SettingsTab.general

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            SidebarView(games: games, selection: $selection, retryMetadata: fetchMissingMetadata)
                .onGeometryChange(for: Double.self) { $0.size.width } action: { width in
                    columns.update { $0.measure(sidebar: width) }
                }
                // After onGeometryChange, as for the inspector below.
                .navigationSplitViewColumnWidth(min: AppMetrics.sidebarWidth.min, ideal: AppMetrics.sidebarWidth.ideal,
                                                max: AppMetrics.sidebarWidth.max)
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
                    .onGeometryChange(for: Double.self) { $0.size.width } action: { width in
                        columns.update { $0.measure(inspector: width) }
                    }
                    // Must come after onGeometryChange, which otherwise hides the
                    // width from AppKit: the column then opened at its 270 pt default.
                    .inspectorColumnWidth(min: AppMetrics.inspectorWidth.min, ideal: AppMetrics.inspectorWidth.ideal,
                                          max: AppMetrics.inspectorWidth.max)
                }
        }
        .background {
            WindowSizeReader { size in columns.update { $0.resize(to: size.width) } }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search Games")
        .toolbar { toolbar }
        .focusedSceneValue(\.libraryActions, libraryActions)
        .focusedSceneValue(\.isShowingRecentlyPlayed, selection == .recent)
        .focusedSceneValue(\.inspectorToggle, InspectorToggle(isShown: columns.showsInspector, toggle: toggleInspector))
        .focusedSceneValue(\.gameActions, selectedGame.map(actions(for:)))
        .confirmationDialog(Text("Remove “\(gamePendingRemoval?.title ?? "")” from the library?"),
                            isPresented: Binding(get: { gamePendingRemoval != nil },
                                                 set: { if !$0 { gamePendingRemoval = nil } }),
                            presenting: gamePendingRemoval) { game in
            Button("Remove", role: .destructive) { remove(game) }
            // No .defaultAction here: a button has one key equivalent, and Return would replace Escape.
            Button("Cancel", role: .cancel) {}
        } message: { game in
            if game.isMissing {
                Text("Play time and favorite status are lost. Saves stay on disk.")
            } else {
                Text("The file stays on disk. Play time and favorite status are lost, and the next rescan adds the game again.")
            }
        }
        .alert(Text(unavailableGame?.title ?? ""),
               isPresented: Binding(get: { unavailableGame != nil }, set: { if !$0 { unavailableGame = nil } }),
               presenting: unavailableGame) { item in
            if item.volume == nil {
                Button("Locate…") {
                    // After the alert has gone, so the open panel is not stacked on it.
                    Task { library.presentLocatePanel(for: item.game, context: context) }
                }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { item in
            if let volume = item.volume {
                Text("Connect “\(volume)” to play this game.")
            } else {
                Text("The file was moved, renamed or deleted. Locate it to keep favorites, play time and saves with the game.")
            }
        }
        .confirmationDialog("Refetch metadata for all games?", isPresented: $isConfirmingRefetch) {
            // Destructive: it overwrites existing metadata. Cancel keeps Escape.
            Button("Refetch All", role: .destructive) { metadata.enqueue(games, force: true, context: context) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Titles, descriptions and artwork of every game are replaced with the data from ScreenScraper.")
        }
        .onChange(of: library.isScanning) { _, isScanning in
            if !isScanning, let summary = library.lastScanSummary { announce(summary) }
        }
        .onChange(of: metadata.isRunning) { _, isRunning in
            if !isRunning, metadata.lastError == nil { announce(String(localized: "Metadata fetched")) }
        }
        .onChange(of: metadata.lastError) { _, error in
            if let error { announce(String(localized: "Metadata couldn't be fetched. \(error.message)")) }
        }
        .onChange(of: librarySystems.map(\.id)) { _, systemIDs in
            // The sidebar row of a system disappears with its last game.
            if case .system(let id) = selection, !systemIDs.contains(id) { selection = .all }
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
            // Shows the activity footer's error row.
            if let message = ProcessInfo.processInfo.environment["URSPRUNG_METADATA_ERROR"] {
                metadata.lastError = message == "quota" ? MetadataFailure(ScreenScraperError.quotaExceeded)
                    : MetadataFailure(reason: message, message: message)
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
        let visibleGames = filteredGames
        switch LibraryState(hasFolders: !library.folders.isEmpty, isScanning: library.isScanning,
                            libraryCount: games.count, visibleCount: visibleGames.count, searchText: searchText,
                            selection: selection ?? .all) {
        case .games:
            GameGridView(games: visibleGames, selectedGameID: $selectedGameID, coverStep: CoverSize.snapped(gridSize),
                         system: selectedSystem, actions: actions(for:))
        case .welcome:
            ContentUnavailableView {
                Label("Welcome to Ursprung", systemImage: "gamecontroller")
            } description: {
                Text("Add a folder with your games. Ursprung detects the system and fetches covers from ScreenScraper.")
            } actions: {
                Button("Add Folder…", action: libraryActions.addFolder)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
        case .scanning:
            ContentUnavailableView {
                Label {
                    Text("Scanning Library…")
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        case .noGames:
            ContentUnavailableView {
                Label("No Games Found", systemImage: "questionmark.folder")
            } description: {
                Text("Ursprung didn't recognize any games in your library folders.")
            } actions: {
                Button("Rescan", action: libraryActions.rescan)
                    .buttonStyle(.glassProminent)
                Button("Library Folders…", action: libraryActions.showLibraryFolders)
                    .buttonStyle(.glass)
            }
        case .noResults(let query):
            ContentUnavailableView {
                Label("No Results for “\(query)”", systemImage: "magnifyingglass")
            } description: {
                Text("Check the spelling or try a new search.")
            } actions: {
                if selection != .all {
                    Button("Search All Games") { selection = .all }
                        .buttonStyle(.glass)
                }
            }
        case .noFavorites:
            ContentUnavailableView("No Favorites Yet", systemImage: "heart",
                                   description: Text("Mark a game as favorite in its info panel or context menu."))
        case .nothingPlayed:
            ContentUnavailableView("Nothing Played Yet", systemImage: "clock",
                                   description: Text("Games you play appear here."))
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

    // MARK: Toolbar

    /// [Activity] · View · Add Folder · Library Actions · Inspector, then search.
    /// See docs/DESIGN_SPEC.md, section D.
    ///
    /// The spec asks for separate glass capsules and the inspector toggle after
    /// the search field. `ToolbarSpacer` only separates capsules when the toolbar
    /// is declared in the detail column, and there it crowds into the inspector
    /// column and overflows below 1000 pt, or breaks the column yielding; the
    /// search field always stays at the trailing edge. So one toolbar on the
    /// split view, without spacers.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Progress lives in the sidebar footer; only a collapsed sidebar needs a stand-in.
        if !columns.showsSidebar, Activity.isPending(library: library, metadata: metadata, systemMedia: systemMedia) {
            ToolbarItem {
                ActivityToolbarButton(retry: fetchMissingMetadata)
            }
        }

        ToolbarItem {
            Menu {
                LibrarySortPicker(isFixedToRecentlyPlayed: selection == .recent)
                    .pickerStyle(.inline)
                Divider()
                CoverSizeItems()
            } label: {
                Label("View Options", systemImage: "square.grid.2x2")
            }
            .menuIndicator(.hidden)
            .help("View Options")
        }

        ToolbarItemGroup {
            Button("Add Folder to Library…", systemImage: "plus", action: libraryActions.addFolder)
                .help("Add Folder to Library… (⌘O)")
            Menu {
                LibraryActionItems(actions: libraryActions, placement: .toolbar)
            } label: {
                Label("Library Actions", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .help("Library Actions")
        }

        ToolbarItem {
            Button(action: toggleInspector) {
                Label(columns.showsInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
            }
            .help(columns.showsInspector ? "Hide Inspector (⌃⌘I)" : "Show Inspector (⌃⌘I)")
        }
    }

    // MARK: Actions

    private var libraryActions: LibraryActions {
        LibraryActions(
            isScanning: library.isScanning,
            addFolder: { library.presentAddFolderPanel(context: context) },
            rescan: { Task { await library.rescan(context: context) } },
            fetchMissingMetadata: fetchMissingMetadata,
            requestRefetchAllMetadata: { isConfirmingRefetch = true },
            showLibraryFolders: {
                settingsTab = .general
                openSettings()
            }
        )
    }

    /// The toolbar button and the View menu's Show/Hide Inspector (⌃⌘I).
    private func toggleInspector() {
        let visible = !columns.showsInspector
        columns.update { $0.setInspector(visible) }
    }

    private func fetchMissingMetadata() {
        metadata.enqueue(games, context: context)
        Task { await systemMedia.fetchMissing(for: librarySystems, retry: true) }
    }

    private func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }

    private func play(_ game: Game) {
        selectedGameID = game.persistentModelID
        guard FileManager.default.fileExists(atPath: game.path) else {
            if let folder = library.offlineFolder(containing: game) {
                unavailableGame = UnavailableGame(game: game, volume: LibraryPaths.volumeName(of: folder))
            } else {
                if game.missingSince == nil {
                    game.missingSince = .now
                    try? context.save()
                }
                unavailableGame = UnavailableGame(game: game, volume: nil)
            }
            return
        }
        if game.missingSince != nil {
            // The file is back before a rescan noticed it.
            game.missingSince = nil
            try? context.save()
        }
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
            locate: { library.presentLocatePanel(for: game, context: context) },
            importBatterySave: { library.presentBatterySaveImport(for: game) },
            canImportBatterySave: !(session.isActive && session.gameID == game.persistentModelID),
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

/// A game whose file is not there when the user wants to play it.
private struct UnavailableGame: Identifiable {
    let game: Game
    /// The disconnected drive that holds the file; nil when the file is missing.
    let volume: String?
    var id: PersistentIdentifier { game.persistentModelID }

    var title: String {
        volume == nil ? String(localized: "“\(game.title)” can't be found")
                      : String(localized: "“\(game.title)” is on a drive that isn't connected")
    }
}
