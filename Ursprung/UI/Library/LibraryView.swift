// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftData
import SwiftUI

nonisolated enum LibrarySelection: Hashable {
    case all, favorites, recent, hidden
    case system(String)
    case collection(String)
}

/// What the content column shows. See docs/DESIGN_SPEC.md, section H.
nonisolated enum LibraryState: Equatable {
    case welcome
    /// The first scan is running and no game is known yet.
    case scanning
    case noGames
    /// The library is the empty folder structure: games still need to be copied in.
    case awaitingGames
    case noResults(query: String)
    case noFilterResults
    case noFavorites
    case nothingPlayed
    case emptyCollection
    case games

    init(hasFolders: Bool, isScanning: Bool, libraryCount: Int, visibleCount: Int, searchText: String,
         selection: LibrarySelection, isFiltered: Bool = false, usesFolderStructure: Bool = false) {
        if !hasFolders {
            self = .welcome
        } else if visibleCount > 0 {
            self = .games
        } else if libraryCount == 0 {
            // A scan with games already known keeps the grid; progress is in the activity footer.
            self = isScanning ? .scanning : usesFolderStructure ? .awaitingGames : .noGames
        } else if !searchText.isEmpty {
            self = .noResults(query: searchText)
        } else if isFiltered {
            self = .noFilterResults
        } else {
            switch selection {
            case .favorites: self = .noFavorites
            case .recent: self = .nothingPlayed
            case .collection: self = .emptyCollection
            // A system without games has no sidebar row; LibraryView falls back to All Games.
            case .all, .system, .hidden: self = .games
            }
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case title, recentlyAdded, recentlyPlayed, releaseYear, system, playTime
    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .title: "Title"
        case .recentlyAdded: "Recently Added"
        case .recentlyPlayed: "Recently Played"
        case .releaseYear: "Release Year"
        case .system: "System"
        case .playTime: "Play Time"
        }
    }

    /// Dates and play time list the latest and longest first.
    var isDescendingByDefault: Bool {
        self == .recentlyAdded || self == .recentlyPlayed || self == .playTime
    }

    /// `games` in this order; `games` comes sorted by title, which breaks ties.
    func sorted(_ games: [Game]) -> [Game] {
        switch self {
        case .title: games
        case .recentlyAdded: games.sorted { $0.dateAdded > $1.dateAdded }
        case .recentlyPlayed: games.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        case .releaseYear: games.sorted { ($0.releaseDate ?? "9999") < ($1.releaseDate ?? "9999") }
        case .system: games.sorted { ($0.system?.name ?? $0.systemID) < ($1.system?.name ?? $1.systemID) }
        case .playTime: games.sorted { $0.playTime > $1.playTime }
        }
    }
}

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.appearsActive) private var appearsActive
    @Environment(LibraryStore.self) private var library
    @Environment(MetadataService.self) private var metadata
    @Environment(EmulationSession.self) private var session
    @Environment(ShaderEditor.self) private var shaderEditor
    @Environment(SystemMediaStore.self) private var systemMedia
    @Environment(BIOSManager.self) private var bios

    @Query(sort: \Game.title) private var games: [Game]

    @State private var selection: LibrarySelection? = .all
    @State private var gameSelection = GameSelection<PersistentIdentifier>()
    @State private var searchText = ""
    @State private var filter = LibraryFilter()
    @State private var isSortReversed = false
    @State private var columns = ColumnLayoutState()
    @State private var gamesPendingRemoval: [Game] = []
    @State private var isConfirmingRefetch = false
    @State private var unavailableGame: UnavailableGame?
    @State private var editingGame: Game?
    @State private var matchingGame: Game?
    @State private var isShowingScanReport = false
    @State private var isShowingFolderSetup = false
    @State private var collectionPrompt: CollectionPrompt?
    @State private var collectionName = ""
    @State private var collectionPendingDeletion: String?
    /// Bumped when collections change without any game changing (a new
    /// empty collection, a new order), so the sidebar redraws.
    @State private var collectionsRevision = 0
    @State private var discEditor: DiscPlaylistRequest?
    @State private var statesGame: Game?
    @State private var isDropTargeted = false
    @State private var externalOpen = ExternalOpen.shared
    @AppStorage(PrefKey.librarySort) private var sort: LibrarySort = .title
    @AppStorage(PrefKey.gridSize) private var gridSize = AppMetrics.defaultCoverStep
    @AppStorage(PrefKey.settingsTab) private var settingsTab = SettingsTab.general
    @AppStorage(PrefKey.libraryViewMode) private var viewMode: LibraryViewMode = .grid
    @AppStorage(PrefKey.groupsVariants) private var groupsVariants = true

    var body: some View {
        let shelf = makeShelf()
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            // With versions grouped, the counts are games, not files, as in the grid.
            SidebarView(games: sidebarGames(shelf),
                        hiddenCount: games.count - libraryGames.count, selection: $selection,
                        collections: collections, collectionActions: collectionActions,
                        retryMetadata: fetchMissingMetadata)
                .onGeometryChange(for: Double.self) { $0.size.width } action: { width in
                    columns.update { $0.measure(sidebar: width) }
                }
                // After onGeometryChange, as for the inspector below.
                .navigationSplitViewColumnWidth(min: AppMetrics.sidebarWidth.min, ideal: AppMetrics.sidebarWidth.ideal,
                                                max: AppMetrics.sidebarWidth.max)
        } detail: {
            content(shelf)
                .overlay { dropHighlight }
                .overlay(alignment: .bottom) {
                    // A game in a standalone emulator has no player window for its toasts.
                    if session.phase == .external {
                        ToastStack(toasts: session.toasts)
                            .padding(.bottom, AppSpacing.l)
                    }
                }
                .appAnimation(AppAnimation.standard, value: session.toasts)
                .dropDestination(for: URL.self) { urls, _ in
                    importItems(urls, playsSingleGame: false)
                    return !urls.isEmpty
                } isTargeted: { isDropTargeted = $0 }
                .navigationTitle(title)
                .navigationSubtitle(subtitle(shelf))
                .inspector(isPresented: inspectorPresented) {
                    inspector(shelf)
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
        .toolbar { toolbar(shelf) }
        .focusedSceneValue(\.libraryActions, libraryActions)
        .focusedSceneValue(\.isShowingRecentlyPlayed, selection == .recent)
        .focusedSceneValue(\.inspectorToggle, InspectorToggle(isShown: columns.showsInspector, toggle: toggleInspector))
        .focusedSceneValue(\.gameActions, singleSelectedGame(shelf).map { actions(for: $0, shelf: shelf) })
        .focusedSceneValue(\.batchActions, selectedGames(shelf).count > 1 ? batchActions(for: selectedGames(shelf)) : nil)
        .focusedSceneValue(\.libraryFilter, LibraryFilterControl(filter: $filter, options: shelf.filterOptions))
        .modifier(DialogsModifier(view: self))
        .modifier(ObserversModifier(view: self, shelf: shelf))
    }

    // MARK: Dialogs and observers

    /// The library's sheets, alerts and confirmations. Apart from `body`,
    /// which is otherwise too large to type-check.
    private struct DialogsModifier: ViewModifier {
        let view: LibraryView

        func body(content: Content) -> some View {
            view.dialogs(content)
        }
    }

    private struct ObserversModifier: ViewModifier {
        let view: LibraryView
        let shelf: Shelf

        func body(content: Content) -> some View {
            view.observers(content, shelf: shelf)
        }
    }

    private func dialogs(_ content: some View) -> some View {
        content
            .confirmationDialog(removalTitle, isPresented: Binding(get: { !gamesPendingRemoval.isEmpty },
                                                                   set: { if !$0 { gamesPendingRemoval = [] } })) {
                Button("Remove", role: .destructive) { remove(gamesPendingRemoval) }
                // No .defaultAction here: a button has one key equivalent, and Return would replace Escape.
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Play time and favorite status are lost. Saves stay on disk.")
            }
            .confirmationDialog(Text("Delete the collection “\(collectionPendingDeletion ?? "")”?"),
                                isPresented: Binding(get: { collectionPendingDeletion != nil },
                                                     set: { if !$0 { collectionPendingDeletion = nil } }),
                                presenting: collectionPendingDeletion) { collection in
                Button("Delete Collection", role: .destructive) { deleteCollection(collection) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The games stay in the library.")
            }
            .alert(collectionPrompt?.title ?? "", isPresented: Binding(get: { collectionPrompt != nil },
                                                                         set: { if !$0 { collectionPrompt = nil } }),
                   presenting: collectionPrompt) { prompt in
                TextField("Name", text: $collectionName)
                Button(prompt.confirmTitle) { commit(prompt) }
                    .disabled(LibraryCollections.validName(collectionName, existing: collections,
                                                           renaming: prompt.renaming) == nil)
                Button("Cancel", role: .cancel) {}
            } message: { prompt in
                Text(prompt.message)
            }
            .sheet(item: $editingGame) { game in
                GameInfoEditor(game: game)
            }
            .sheet(item: $matchingGame) { game in
                MatchPicker(game: game)
            }
            .sheet(isPresented: $isShowingScanReport) {
                ScanReportView()
            }
            .sheet(isPresented: $isShowingFolderSetup, onDismiss: { Preferences.folderStructureOffered = true }) {
                FolderStructureSheet()
            }
            .sheet(item: $discEditor) { request in
                DiscPlaylistEditor(request: request) { game in
                    if let game { gameSelection.select(game.persistentModelID) }
                }
            }
            .sheet(item: $statesGame) { game in
                SaveStatesBrowser(game: game) { state in play(game, from: state) }
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
            // A standalone emulator's game has no player window to show why it failed.
            .alert(standaloneFailureTitle,
                   isPresented: Binding(get: { standaloneFailure != nil }, set: { if !$0 { session.dismissFailure() } }),
                   presenting: standaloneFailure) { failure in
                if let tab = failure.settingsTab {
                    Button("Open Settings") {
                        settingsTab = tab
                        openSettings()
                    }
                }
                if let log = failure.logURL {
                    Button("Show Log") { NSWorkspace.shared.open(log) }
                }
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure.message)
            }
            .confirmationDialog("Refetch metadata for all games?", isPresented: $isConfirmingRefetch) {
                // Destructive: it overwrites existing metadata. Cancel keeps Escape.
                Button("Refetch All", role: .destructive) { metadata.enqueue(games, force: true, context: context) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Titles, descriptions and artwork of every game are replaced with the data from ScreenScraper. Details you edited yourself are kept.")
            }
    }

    private var standaloneFailure: EmulationSession.Failure? {
        guard session.standaloneName != nil, case .failed(let failure) = session.phase else { return nil }
        return failure
    }

    private var standaloneFailureTitle: Text {
        // Only a run that ended has a log.
        standaloneFailure?.hasStarted == true ? Text("“\(session.gameTitle)” stopped")
                                              : Text("“\(session.gameTitle)” couldn't be started")
    }

    private func observers(_ content: some View, shelf: Shelf) -> some View {
        content
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
            .onChange(of: collections) { _, collections in
                if case .collection(let name) = selection, !collections.contains(name) { selection = .all }
            }
            .onChange(of: games.count - libraryGames.count) { _, hidden in
                // So does Hidden once nothing is hidden.
                if hidden == 0, selection == .hidden { selection = .all }
            }
            .onChange(of: shelf.games.map(\.persistentModelID)) { _, ids in
                // Games that leave the view (hidden, filtered, removed) leave the selection.
                gameSelection.keep(only: Set(ids))
            }
            .onChange(of: sort) { isSortReversed = false }
            .onChange(of: controllersDriveLibrary, initial: true) { _, drives in
                session.input.routesToLibrary = drives
            }
            .onChange(of: session.input.libraryEvent) { _, event in
                if let event { handleController(event.command) }
            }
            .onChange(of: externalOpen.requests) { _, requests in
                guard let request = requests.first else { return }
                externalOpen.requests.removeFirst()
                importItems(request, playsSingleGame: true)
            }
            .task(id: librarySystems.map(\.id)) {
                if Preferences.autoScrape { await systemMedia.fetchMissing(for: librarySystems) }
            }
            .task {
                // The inspector shows missing BIOS files; their status must be known.
                await bios.refresh()
                if !library.folders.isEmpty { await library.rescan(context: context) }
                library.startWatching(context: context)
                if let root = library.folderStructure {
                    await library.updateFolderStructure()
                    bios.watch(FolderStructure.bios(in: root))
                }
                // The first launch offers folders for games and BIOS files.
                // Who has a library already is not asked.
                if !Preferences.folderStructureOffered {
                    if library.folders.isEmpty, games.isEmpty {
                        isShowingFolderSetup = true
                    } else {
                        Preferences.folderStructureOffered = true
                    }
                }
                // Files opened from the Finder before the library was ready.
                if let request = externalOpen.requests.first {
                    externalOpen.requests.removeFirst()
                    importItems(request, playsSingleGame: true)
                }
                #if DEBUG
                // Development aid: URSPRUNG_AUTOPLAY=<title substring> starts a game on launch.
                if let query = ProcessInfo.processInfo.environment["URSPRUNG_AUTOPLAY"],
                   let game = games.first(where: { $0.title.localizedStandardContains(query) || $0.fileName.localizedStandardContains(query) }) {
                    play(game)
                }
                if let systemID = ProcessInfo.processInfo.environment["URSPRUNG_SYSTEM"] {
                    selection = .system(systemID)
                }
                // URSPRUNG_FOLDER_SETUP=1 offers the folder structure as on the first launch.
                if ProcessInfo.processInfo.environment["URSPRUNG_FOLDER_SETUP"] == "1" { isShowingFolderSetup = true }
                // URSPRUNG_SELECT=<title substring>[|<title substring>…] selects one or several games.
                if let query = ProcessInfo.processInfo.environment["URSPRUNG_SELECT"] {
                    let ids = query.split(separator: "|").compactMap { part in
                        games.first { $0.title.localizedStandardContains(part) }?.persistentModelID
                    }
                    if ids.count > 1 {
                        gameSelection.replace(with: Set(ids), order: games.map(\.persistentModelID))
                    } else {
                        gameSelection.select(ids.first)
                    }
                }
                // URSPRUNG_SHADER_EDITOR=<preset:library/…|preset:user/…|system id|new> opens the shader editor.
                if let request = ProcessInfo.processInfo.environment["URSPRUNG_SHADER_EDITOR"] {
                    if case .preset(let preset)? = ShaderSelection(rawValue: request) {
                        shaderEditor.open(.preset(preset))
                    } else if request == "new" {
                        shaderEditor.open(.newPreset)
                    } else if SystemCatalog.system(withID: request) != nil {
                        shaderEditor.open(.system(request))
                    }
                    openWindow(id: WindowID.shaderEditor)
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

    /// The games in view and what the views around them need to know.
    private struct Shelf {
        /// Sidebar selection, search, filter and sort applied; one game per
        /// group when versions are grouped.
        let games: [Game]
        let groups: VariantGroups
        let filterOptions: LibraryFilterOptions
        let isGrouped: Bool
    }

    private func makeShelf() -> Shelf {
        let scope = scopeGames
        let groups = VariantGroups(selection == .hidden ? games.filter(\.isHidden) : libraryGames)
        var result = scope
        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedStandardContains(searchText)
                    || ($0.developer?.localizedStandardContains(searchText) ?? false)
                    || ($0.genre?.localizedStandardContains(searchText) ?? false)
                    || $0.collections.contains { $0.localizedStandardContains(searchText) }
            }
        }
        if filter.isActive { result = result.filter(filter.matches) }
        if selection == .recent {
            result = LibrarySort.recentlyPlayed.sorted(result)
        } else {
            result = sort.sorted(result)
            if isSortReversed { result.reverse() }
        }
        // Hidden lists every hidden file; elsewhere one card stands for all versions.
        let isGrouped = groupsVariants && selection != .hidden
        if isGrouped { result = groups.collapse(result) }
        return Shelf(games: result, groups: groups, filterOptions: LibraryFilter.options(for: scope), isGrouped: isGrouped)
    }

    /// The games the sidebar counts: one per group when versions are grouped.
    private func sidebarGames(_ shelf: Shelf) -> [Game] {
        guard groupsVariants else { return libraryGames }
        // Under Hidden the shelf groups hidden games; the sidebar counts the others.
        let groups = selection == .hidden ? VariantGroups(libraryGames) : shelf.groups
        return groups.collapse(libraryGames)
    }

    @ViewBuilder
    private func content(_ shelf: Shelf) -> some View {
        let visibleGames = shelf.games
        switch LibraryState(hasFolders: !library.folders.isEmpty || !games.isEmpty, isScanning: library.isScanning,
                            libraryCount: games.count, visibleCount: visibleGames.count, searchText: searchText,
                            selection: selection ?? .all, isFiltered: filter.isActive,
                            usesFolderStructure: library.folderStructureROMs != nil) {
        case .games:
            switch viewMode {
            case .grid:
                GameGridView(games: visibleGames, selection: $gameSelection, coverStep: CoverSize.snapped(gridSize),
                             system: selectedSystem, actions: { actions(for: $0, shelf: shelf) },
                             batchActions: selectedGames(shelf).count > 1 ? batchActions(for: selectedGames(shelf)) : nil,
                             versionCount: { shelf.isGrouped ? shelf.groups.versionCount(of: $0) : 1 },
                             controllerEvent: session.input.libraryEvent)
            case .list:
                GameTableView(games: visibleGames, selection: $gameSelection, sort: $sort, isSortReversed: $isSortReversed,
                              actions: { actions(for: $0, shelf: shelf) }, batchActions: batchActions(for:),
                              versionCount: { shelf.isGrouped ? shelf.groups.versionCount(of: $0) : 1 },
                              controllerEvent: session.input.libraryEvent)
            }
        case .welcome:
            ContentUnavailableView {
                Label("Welcome to Ursprung", systemImage: "gamecontroller")
            } description: {
                Text("Add a folder with your games, or drop games here. Ursprung detects the system and fetches covers from ScreenScraper.")
            } actions: {
                Button("Add Folder…", action: libraryActions.addFolder)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                Button("Set Up Game Folders…", action: libraryActions.setUpFolders)
                    .buttonStyle(.glass)
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
        case .awaitingGames:
            ContentUnavailableView {
                Label("Copy Your Games into the Folders", systemImage: "folder.badge.plus")
            } description: {
                Text("Put each game into the folder of its system in “ROMs”, and BIOS files into “BIOS”. Ursprung adds them as soon as they arrive.")
            } actions: {
                Button("Show in Finder") {
                    if let roms = library.folderStructureROMs { NSWorkspace.shared.open(roms) }
                }
                .buttonStyle(.glassProminent)
                Button("Rescan", action: libraryActions.rescan)
                    .buttonStyle(.glass)
            }
        case .noResults(let query):
            ContentUnavailableView {
                Label("No Results for “\(query)”", systemImage: "magnifyingglass")
            } description: {
                Text("Check the spelling or try a new search.")
            } actions: {
                if selection != .all || filter.isActive {
                    Button("Search All Games") {
                        selection = .all
                        filter = LibraryFilter()
                    }
                    .buttonStyle(.glass)
                }
            }
        case .noFilterResults:
            ContentUnavailableView {
                Label("No Games Match the Filter", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Try other filter settings.")
            } actions: {
                Button("Clear Filters") { filter = LibraryFilter() }
                    .buttonStyle(.glass)
            }
        case .noFavorites:
            ContentUnavailableView("No Favorites Yet", systemImage: "heart",
                                   description: Text("Mark a game as favorite in its info panel or context menu."))
        case .nothingPlayed:
            ContentUnavailableView("Nothing Played Yet", systemImage: "clock",
                                   description: Text("Games you play appear here."))
        case .emptyCollection:
            ContentUnavailableView("This Collection Is Empty", systemImage: "rectangle.stack",
                                   description: Text("Add games with Collections in their context menu or info panel."))
        }
    }

    @ViewBuilder
    private func inspector(_ shelf: Shelf) -> some View {
        let selected = selectedGames(shelf)
        if selected.count > 1 {
            MultiGameInspector(actions: batchActions(for: selected))
        } else if let game = singleSelectedGame(shelf) {
            GameInspector(game: game, actions: actions(for: game, shelf: shelf),
                          versions: shelf.groups.versions(of: game),
                          showsGroupedVersions: shelf.isGrouped,
                          versionActions: versionActions(shelf))
        } else {
            ContentUnavailableView("No Game Selected", systemImage: "square.stack",
                                   description: Text("Select a game to see its details."))
        }
    }

    /// Shown over the content while files are dragged over it.
    @ViewBuilder
    private var dropHighlight: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
                .overlay {
                    Label("Add to Library", systemImage: "plus.circle")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, AppSpacing.l)
                        .padding(.vertical, AppSpacing.s)
                        .glassEffect(.regular, in: .capsule)
                }
                .padding(AppSpacing.s)
                .allowsHitTesting(false)
        }
    }

    /// Every game that is not hidden.
    private var libraryGames: [Game] {
        games.filter { !$0.isHidden }
    }

    /// The games of the sidebar selection, before search and filters.
    private var scopeGames: [Game] {
        let games = libraryGames
        return switch selection ?? .all {
        case .all: games
        case .favorites: games.filter(\.isFavorite)
        case .recent: games.filter { $0.lastPlayed != nil }
        case .hidden: self.games.filter(\.isHidden)
        case .system(let id): games.filter { $0.systemID == id }
        case .collection(let name): games.filter { $0.collections.contains(name) }
        }
    }

    private func selectedGames(_ shelf: Shelf) -> [Game] {
        guard !gameSelection.isEmpty else { return [] }
        let visible = shelf.games.filter { gameSelection.contains($0.persistentModelID) }
        // A game selected from outside the view (e.g. after an import) still has an inspector.
        return visible.isEmpty ? games.filter { gameSelection.contains($0.persistentModelID) } : visible
    }

    private func singleSelectedGame(_ shelf: Shelf) -> Game? {
        let selected = selectedGames(shelf)
        return selected.count == 1 ? selected[0] : nil
    }

    private var selectedSystem: GameSystem? {
        if case .system(let id) = selection { SystemCatalog.system(withID: id) } else { nil }
    }

    /// Systems with at least one game, in catalog order.
    private var librarySystems: [GameSystem] {
        let ids = Set(libraryGames.map(\.systemID))
        return SystemCatalog.all.filter { ids.contains($0.id) }
    }

    private var collections: [String] {
        _ = collectionsRevision
        return LibraryCollections().all(in: games)
    }

    private var title: String {
        switch selection ?? .all {
        case .all: String(localized: "All Games")
        case .favorites: String(localized: "Favorites")
        case .recent: String(localized: "Recently Played")
        case .hidden: String(localized: "Hidden")
        case .system(let id): SystemCatalog.system(withID: id)?.name ?? id
        case .collection(let name): name
        }
    }

    private func subtitle(_ shelf: Shelf) -> String {
        let count = shelf.games.count
        let games = count == 1 ? String(localized: "1 game") : String(localized: "\(count) games")
        return filter.isActive ? String(localized: "\(games), filtered") : games
    }

    // MARK: Toolbar

    /// [Activity] · View · Filter · Add Folder · Library Actions · Inspector,
    /// then search. See docs/DESIGN_SPEC.md, section D.
    ///
    /// The spec asks for separate glass capsules and the inspector toggle after
    /// the search field. `ToolbarSpacer` only separates capsules when the toolbar
    /// is declared in the detail column, and there it crowds into the inspector
    /// column and overflows below 1000 pt, or breaks the column yielding; the
    /// search field always stays at the trailing edge. So one toolbar on the
    /// split view, without spacers.
    @ToolbarContentBuilder
    private func toolbar(_ shelf: Shelf) -> some ToolbarContent {
        // Progress lives in the sidebar footer; only a collapsed sidebar needs a stand-in.
        if !columns.showsSidebar, Activity.isPending(library: library, metadata: metadata, systemMedia: systemMedia) {
            ToolbarItem {
                ActivityToolbarButton(retry: fetchMissingMetadata)
            }
        }

        if session.phase == .external {
            ToolbarItem {
                Menu {
                    Button("Switch to \(session.coreName)", systemImage: "macwindow") { session.showExternalWindow() }
                    Divider()
                    Button("Quick Save", systemImage: "square.and.arrow.down") { session.saveState(slot: 0) }
                        .disabled(!session.canUseExternalStates)
                    Button("Quick Load", systemImage: "square.and.arrow.up") { session.loadState(slot: 0) }
                        .disabled(!session.canUseExternalStates || !session.slots.contains { $0.slot == 0 })
                    Divider()
                    Button("Quit “\(session.gameTitle)”", systemImage: "stop.fill") {
                        Task { await session.stop(context: context) }
                    }
                } label: {
                    Label("Running in \(session.coreName)", systemImage: "gamecontroller.fill")
                }
                .menuIndicator(.hidden)
                .help("“\(session.gameTitle)” is running in \(session.coreName)")
            }
        }

        ToolbarItemGroup {
            Menu {
                LibraryViewModeItems()
                Divider()
                LibrarySortPicker(isFixedToRecentlyPlayed: selection == .recent)
                    .pickerStyle(.inline)
                if viewMode == .grid {
                    Divider()
                    CoverSizeItems()
                }
            } label: {
                Label("View Options", systemImage: viewMode == .grid ? "square.grid.2x2" : "list.bullet")
            }
            .menuIndicator(.hidden)
            .help("View Options")

            Menu {
                LibraryFilterItems(control: LibraryFilterControl(filter: $filter, options: shelf.filterOptions))
            } label: {
                Label("Filter", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill"
                                                             : "line.3.horizontal.decrease.circle")
            }
            .menuIndicator(.hidden)
            .help(filter.isActive ? Text("Filter (\(filter.activeCount) active)") : Text("Filter"))
            .accessibilityValue(filter.isActive ? Text("\(filter.activeCount) active") : Text("Off"))
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
            showScanReport: { isShowingScanReport = true },
            fetchMissingMetadata: fetchMissingMetadata,
            requestRefetchAllMetadata: { isConfirmingRefetch = true },
            showLibraryFolders: {
                settingsTab = .general
                openSettings()
            },
            newCollection: { promptForCollection(with: []) },
            addGames: presentAddGamesPanel,
            setUpFolders: { isShowingFolderSetup = true }
        )
    }

    private var collectionActions: CollectionActions {
        CollectionActions(
            create: { promptForCollection(with: []) },
            rename: { name in
                collectionName = name
                collectionPrompt = CollectionPrompt(kind: .rename(name))
            },
            delete: { collectionPendingDeletion = $0 },
            move: { offsets, destination in
                LibraryCollections().move(fromOffsets: offsets, toOffset: destination, library: games)
                collectionsRevision += 1
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

    /// `resume` nil follows the setting: continue from the automatic state if
    /// there is one. `state` starts from a save state instead.
    private func play(_ game: Game, resume: Bool? = nil, from state: SaveStateSlot? = nil) {
        if !gameSelection.contains(game.persistentModelID) || gameSelection.count > 1 {
            gameSelection.select(game.persistentModelID)
        }
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
        // A standalone emulator opens its own window.
        if game.effectiveCore?.isLibretro != false { openWindow(id: WindowID.player) }
        let resume = resume ?? Preferences.resumeAutomatically
        Task { await session.launch(game, context: context, resume: resume, state: state) }
    }

    private func actions(for game: Game, shelf: Shelf) -> GameActions {
        let resumes = Preferences.resumeAutomatically
        return GameActions(
            game: game,
            play: { play(game) },
            playAlternate: { play(game, resume: !resumes) },
            hasAutosave: game.effectiveCore.map { core in
                core.isLibretro ? SaveStateStore.autosave(in: AppPaths.states, gameID: game.id, coreID: core.id) != nil
                    : ARMSX2States.resumeState(in: SaveStateStore.directory(in: AppPaths.states, gameID: game.id,
                                                                            coreID: core.id)) != nil
            } ?? false,
            resumesAutomatically: resumes,
            toggleFavorite: {
                game.isFavorite.toggle()
                try? context.save()
            },
            refetchMetadata: { metadata.enqueue([game], force: true, context: context) },
            editInfo: { editingGame = game },
            chooseMatch: { matchingGame = game },
            showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([game.fileURL]) },
            locate: { library.presentLocatePanel(for: game, context: context) },
            toggleHidden: { setHidden([game], !game.isHidden) },
            importBatterySave: { library.presentBatterySaveImport(for: game) },
            canImportBatterySave: !(session.isActive && session.gameID == game.persistentModelID),
            setCore: { coreID in
                game.coreID = coreID
                try? context.save()
            },
            requestRemoval: { gamesPendingRemoval = [game] },
            organize: organizeActions(for: [game]),
            showSaveStates: { statesGame = game },
            editShader: {
                shaderEditor.open(.game(game.id, systemID: game.system?.id))
                openWindow(id: WindowID.shaderEditor)
            },
            discs: discAction(for: game)
        )
    }

    private func organizeActions(for games: [Game]) -> OrganizeActions {
        OrganizeActions(
            games: games,
            collections: collections,
            setStatus: { status in
                for game in games { game.playStatus = status }
                try? context.save()
            },
            setCollection: { name, isMember in
                if isMember {
                    LibraryCollections.add(games, to: name)
                } else {
                    LibraryCollections.remove(games, from: name)
                }
                try? context.save()
            },
            newCollection: { promptForCollection(with: games) }
        )
    }

    private func batchActions(for games: [Game]) -> BatchActions {
        BatchActions(
            games: games,
            organize: organizeActions(for: games),
            setFavorite: { favorite in
                for game in games { game.isFavorite = favorite }
                try? context.save()
            },
            refetchMetadata: { metadata.enqueue(games, force: true, context: context) },
            setHidden: { setHidden(games, $0) },
            requestRemoval: { gamesPendingRemoval = games.filter(\.isMissing) }
        )
    }

    private func versionActions(_ shelf: Shelf) -> VersionActions {
        VersionActions(
            play: { play($0) },
            prefer: { game in
                shelf.groups.prefer(game)
                try? context.save()
                gameSelection.select(game.persistentModelID)
            }
        )
    }

    private func discAction(for game: Game) -> DiscAction? {
        if game.fileURL.pathExtension.lowercased() == "m3u" {
            return DiscAction(kind: .edit) { discEditor = .edit(game) }
        }
        let set = DiscSets.set(containing: game, in: libraryGames)
        guard set.count > 1 else { return nil }
        return DiscAction(kind: .create) { discEditor = .create(set) }
    }

    private func setHidden(_ games: [Game], _ hidden: Bool) {
        for game in games { game.isHidden = hidden }
        try? context.save()
        guard hidden, selection != .hidden else { return }
        // The games leave the view; the selection follows by itself.
        if games.count == 1, let game = games.first {
            announce(String(localized: "“\(game.title)” is hidden. Find it under Hidden in the sidebar."))
        } else {
            announce(String(localized: "\(games.count) games are hidden. Find them under Hidden in the sidebar."))
        }
    }

    private var removalTitle: Text {
        if gamesPendingRemoval.count == 1, let game = gamesPendingRemoval.first {
            Text("Remove “\(game.title)” from the library?")
        } else {
            Text("Remove \(gamesPendingRemoval.count) games from the library?")
        }
    }

    private func remove(_ games: [Game]) {
        for game in games {
            gameSelection.keep(only: gameSelection.ids.subtracting([game.persistentModelID]))
            library.remove(game, context: context)
        }
    }

    // MARK: Collections

    private func promptForCollection(with games: [Game]) {
        collectionName = ""
        collectionPrompt = CollectionPrompt(kind: .new(games))
    }

    private func commit(_ prompt: CollectionPrompt) {
        switch prompt.kind {
        case .new(let members):
            guard let name = LibraryCollections().create(collectionName, with: members, library: games) else { return }
            if members.isEmpty { selection = .collection(name) }
        case .rename(let old):
            guard let name = LibraryCollections().rename(old, to: collectionName, library: games) else { return }
            if selection == .collection(old) { selection = .collection(name) }
        }
        try? context.save()
        collectionsRevision += 1
    }

    private func deleteCollection(_ name: String) {
        LibraryCollections().delete(name, library: games)
        try? context.save()
        collectionsRevision += 1
    }

    // MARK: Importing

    /// Imports dropped or opened files and folders and selects the games.
    /// Opening a single game from the Finder starts it.
    private func importItems(_ urls: [URL], playsSingleGame: Bool) {
        Task {
            let result = await library.importItems(urls, context: context)
            let ids = result.games.map(\.persistentModelID)
            guard !ids.isEmpty else {
                if result.unrecognized > 0 { isShowingScanReport = true }
                return
            }
            if let first = result.games.first, !scopeGames.contains(where: { $0 === first }) {
                selection = .all
                filter = LibraryFilter()
                searchText = ""
            }
            gameSelection.replace(with: Set(ids), order: ids)
            if playsSingleGame, result.games.count == 1, let game = result.games.first {
                play(game)
            } else if result.unrecognized > 0 {
                isShowingScanReport = true
            }
        }
    }

    private func presentAddGamesPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add to Library")
        panel.message = String(localized: "Choose games or folders. Games outside your library folders are added one by one.")
        guard panel.runModal() == .OK else { return }
        importItems(panel.urls, playsSingleGame: false)
    }

    // MARK: Controllers

    /// Controllers move through the library while its window is key and no
    /// game runs.
    private var controllersDriveLibrary: Bool {
        appearsActive && !session.isActive
    }

    /// The sidebar's lists in order, for the shoulder buttons.
    private var sidebarEntries: [LibrarySelection] {
        var entries: [LibrarySelection] = [.all, .favorites, .recent]
        if games.count != libraryGames.count { entries.append(.hidden) }
        entries += collections.map(LibrarySelection.collection)
        entries += librarySystems.map { .system($0.id) }
        return entries
    }

    private func handleController(_ command: MenuCommand) {
        switch command {
        case .previousPage, .nextPage:
            let entries = sidebarEntries
            let index = entries.firstIndex(of: selection ?? .all) ?? 0
            let next = (index + (command == .nextPage ? 1 : -1) + entries.count) % entries.count
            selection = entries[next]
            gameSelection.select(nil)
        case .back:
            if !gameSelection.isEmpty { gameSelection.select(nil) }
        default:
            // Moving and playing are up to the grid or list.
            break
        }
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

/// Naming a new collection or renaming one.
private struct CollectionPrompt: Identifiable {
    enum Kind {
        /// A new collection with these games in it.
        case new([Game])
        case rename(String)
    }

    let id = UUID()
    let kind: Kind

    var renaming: String? {
        if case .rename(let name) = kind { name } else { nil }
    }

    var title: String {
        switch kind {
        case .new: String(localized: "New Collection")
        case .rename: String(localized: "Rename Collection")
        }
    }

    var confirmTitle: LocalizedStringKey {
        switch kind {
        case .new: "Create"
        case .rename: "Rename"
        }
    }

    var message: String {
        switch kind {
        case .new(let games) where games.count == 1:
            String(localized: "“\(games[0].title)” is added to it.")
        case .new(let games) where games.count > 1:
            String(localized: "The \(games.count) selected games are added to it.")
        case .new:
            String(localized: "Add games with Collections in their context menu.")
        case .rename:
            String(localized: "Enter a new name.")
        }
    }
}
