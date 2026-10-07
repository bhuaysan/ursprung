// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Status and collections for one or more games. Single games and
/// multiple selections share these items.
struct OrganizeActions {
    let games: [Game]
    /// Every collection, in sidebar order.
    let collections: [String]
    let setStatus: (PlayStatus?) -> Void
    /// Adds the games to the collection (true) or removes them (false).
    let setCollection: (String, Bool) -> Void
    /// Asks for a name and creates a collection with the games in it.
    let newCollection: () -> Void

    /// The status all games share; nil when they have none or differ.
    var commonStatus: PlayStatus? {
        let statuses = Set(games.map(\.playStatusRaw))
        return statuses.count == 1 ? games.first?.playStatus : nil
    }

    func containsAll(_ collection: String) -> Bool {
        !games.isEmpty && games.allSatisfy { $0.collections.contains(collection) }
    }
}

/// The Status and Collections submenus.
struct OrganizeItems: View {
    let actions: OrganizeActions

    var body: some View {
        Menu("Status", systemImage: "flag") {
            StatusItems(actions: actions)
        }
        Menu("Collections", systemImage: "rectangle.stack") {
            ForEach(actions.collections, id: \.self) { collection in
                Toggle(collection, isOn: Binding(get: { actions.containsAll(collection) },
                                                 set: { actions.setCollection(collection, $0) }))
            }
            if !actions.collections.isEmpty { Divider() }
            Button("New Collection…", action: actions.newCollection)
        }
    }
}

/// A checkmark item per status, then No Status.
struct StatusItems: View {
    let actions: OrganizeActions

    var body: some View {
        ForEach(PlayStatus.allCases) { status in
            Toggle(isOn: Binding(get: { actions.commonStatus == status },
                                 set: { actions.setStatus($0 ? status : nil) })) {
                Label(status.title, systemImage: status.symbol)
            }
        }
        Divider()
        Button("No Status") { actions.setStatus(nil) }
            .disabled(actions.games.allSatisfy { $0.playStatus == nil })
    }
}

/// What the user can do with several selected games at once.
struct BatchActions {
    let games: [Game]
    let organize: OrganizeActions
    let setFavorite: (Bool) -> Void
    let refetchMetadata: () -> Void
    let setHidden: (Bool) -> Void
    /// Only when every selected game is missing; asks first.
    let requestRemoval: () -> Void

    var allFavorite: Bool { games.allSatisfy(\.isFavorite) }
    var allHidden: Bool { games.allSatisfy(\.isHidden) }
    var allMissing: Bool { games.allSatisfy(\.isMissing) }
}

extension FocusedValues {
    /// The selected games' actions while more than one is selected.
    @Entry var batchActions: BatchActions?
}

/// Menu items for a multiple selection, in the order of `GameActionItems`.
struct BatchActionItems: View {
    let actions: BatchActions
    /// Menu bar only: registers the shortcuts of the single-game items.
    var showsShortcuts = false
    var removesWithDeleteKey = false

    var body: some View {
        Button(actions.allFavorite ? "Remove from Favorites" : "Add to Favorites",
               systemImage: actions.allFavorite ? "heart.slash" : "heart") {
            actions.setFavorite(!actions.allFavorite)
        }
        .keyboardShortcut(showsShortcuts ? KeyboardShortcut("d") : nil)
        OrganizeItems(actions: actions.organize)
        Divider()
        Button("Refetch Metadata", systemImage: "arrow.triangle.2.circlepath", action: actions.refetchMetadata)
        Divider()
        if actions.allMissing {
            Button("Remove from Library…", systemImage: "trash", role: .destructive, action: actions.requestRemoval)
                .keyboardShortcut(removesWithDeleteKey ? KeyboardShortcut(.delete) : nil)
        } else {
            Button(actions.allHidden ? "Show in Library" : "Hide from Library",
                   systemImage: actions.allHidden ? "eye" : "eye.slash") {
                actions.setHidden(!actions.allHidden)
            }
            .keyboardShortcut(removesWithDeleteKey ? KeyboardShortcut(.delete) : nil)
        }
    }
}

// MARK: - View mode

nonisolated enum LibraryViewMode: String, CaseIterable, Identifiable {
    case grid, list
    var id: String { rawValue }
}

/// as Covers / as List, Group Versions: the View menu and the toolbar's view options.
struct LibraryViewModeItems: View {
    var showsShortcuts = false

    @AppStorage(PrefKey.libraryViewMode) private var viewMode: LibraryViewMode = .grid
    @AppStorage(PrefKey.groupsVariants) private var groupsVariants = true

    var body: some View {
        if showsShortcuts {
            // Items of a picker cannot carry shortcuts; toggles show the same checkmark.
            Toggle("as Covers", isOn: Binding(get: { viewMode == .grid }, set: { if $0 { viewMode = .grid } }))
                .keyboardShortcut("1")
            Toggle("as List", isOn: Binding(get: { viewMode == .list }, set: { if $0 { viewMode = .list } }))
                .keyboardShortcut("2")
        } else {
            Picker("View", selection: $viewMode) {
                Label("as Covers", systemImage: "square.grid.2x2").tag(LibraryViewMode.grid)
                Label("as List", systemImage: "list.bullet").tag(LibraryViewMode.list)
            }
            .pickerStyle(.inline)
        }
        Toggle("Group Versions", isOn: $groupsVariants)
            .help("Show regions, revisions and translations of a game as one entry.")
    }
}

// MARK: - Filter

/// The filter as the View menu sees it.
struct LibraryFilterControl {
    let filter: Binding<LibraryFilter>
    let options: LibraryFilterOptions
}

extension FocusedValues {
    /// Published by the library window for the View menu.
    @Entry var libraryFilter: LibraryFilterControl?
}

/// Pickers for every filter criterion, plus Clear Filters.
struct LibraryFilterItems: View {
    let control: LibraryFilterControl

    private var filter: Binding<LibraryFilter> { control.filter }

    var body: some View {
        Picker("Status", selection: filter.status) {
            Text("Any Status").tag(LibraryFilter.Status?.none)
            Text("No Status").tag(LibraryFilter.Status?.some(.none))
            Divider()
            ForEach(PlayStatus.allCases) { status in
                Label(status.title, systemImage: status.symbol).tag(LibraryFilter.Status?.some(.status(status)))
            }
        }
        Picker("Genre", selection: filter.genre) {
            Text("Any Genre").tag(String?.none)
            if !control.options.genres.isEmpty { Divider() }
            ForEach(control.options.genres, id: \.self) { genre in
                Text(genre).tag(String?.some(genre))
            }
        }
        Picker("Players", selection: filter.players) {
            Text("Any Number of Players").tag(LibraryFilter.Players?.none)
            Divider()
            ForEach(LibraryFilter.Players.allCases) { players in
                Text(players.title).tag(LibraryFilter.Players?.some(players))
            }
        }
        Picker("Decade", selection: filter.decade) {
            Text("Any Decade").tag(Int?.none)
            if !control.options.decades.isEmpty { Divider() }
            ForEach(control.options.decades, id: \.self) { decade in
                Text("\(String(decade))s").tag(Int?.some(decade))
            }
        }
        Picker("Metadata", selection: filter.metadata) {
            Text("Any Metadata").tag(LibraryFilter.Metadata?.none)
            Divider()
            ForEach(LibraryFilter.Metadata.allCases) { metadata in
                Text(metadata.title).tag(LibraryFilter.Metadata?.some(metadata))
            }
        }
        Picker("Availability", selection: filter.availability) {
            Text("Any Availability").tag(LibraryFilter.Availability?.none)
            Divider()
            ForEach(LibraryFilter.Availability.allCases) { availability in
                Text(availability.title).tag(LibraryFilter.Availability?.some(availability))
            }
        }
        Divider()
        Button("Clear Filters") { filter.wrappedValue = LibraryFilter() }
            .disabled(!filter.wrappedValue.isActive)
    }
}
