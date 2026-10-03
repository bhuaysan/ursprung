// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftData
import SwiftUI

/// The library as a sortable table, to compare details across many games.
/// Shares the selection, sort order and actions with the cover grid.
struct GameTableView: View {
    let games: [Game]
    @Binding var selection: GameSelection<PersistentIdentifier>
    @Binding var sort: LibrarySort
    @Binding var isSortReversed: Bool
    let actions: (Game) -> GameActions
    let batchActions: ([Game]) -> BatchActions
    var versionCount: (Game) -> Int = { _ in 1 }
    /// The latest controller press while the library has the controllers.
    var controllerEvent: MenuEvent?

    @SceneStorage("libraryTableColumns") private var columns = TableColumnCustomization<GameRow>()

    var body: some View {
        Table(of: GameRow.self, selection: tableSelection, sortOrder: sortOrder, columnCustomization: $columns) {
            TableColumn("Title", value: \.title) { row in
                HStack(spacing: AppSpacing.xs) {
                    Text(row.game.title)
                        .lineLimit(1)
                    if row.game.isFavorite {
                        Image(systemName: "heart.fill")
                            .imageScale(.small)
                            .foregroundStyle(.favorite)
                            .accessibilityLabel("Favorite")
                    }
                    let versions = versionCount(row.game)
                    if versions > 1 {
                        Text(verbatim: "\(versions)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(Text("\(versions) versions"))
                    }
                }
                .opacity(row.game.isMissing ? 0.55 : 1)
            }
            .width(min: 160, ideal: 260)
            .customizationID("title")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("System", value: \.systemName) { row in
                Text(row.game.system?.shortName ?? row.game.systemID)
                    .help(row.systemName)
            }
            .width(min: 60, ideal: 90)
            .customizationID("system")

            TableColumn("Year", value: \.releaseDate) { row in
                Text(row.game.releaseYear ?? "")
            }
            .width(min: 44, ideal: 52)
            .customizationID("year")

            TableColumn("Genre") { (row: GameRow) in
                Text(row.game.genre ?? "")
                    .help(row.game.genre ?? "")
            }
            .width(min: 60, ideal: 130)
            .customizationID("genre")

            TableColumn("Players") { (row: GameRow) in
                Text(row.game.players ?? "")
            }
            .width(min: 44, ideal: 60)
            .customizationID("players")

            TableColumn("Developer") { (row: GameRow) in
                Text(row.game.developer ?? "")
                    .help(row.game.developer ?? "")
            }
            .width(min: 60, ideal: 130)
            .customizationID("developer")
            .defaultVisibility(.hidden)

            TableColumn("Status") { (row: GameRow) in
                if row.game.isMissing {
                    StatusLabel("File Missing", kind: .warning)
                } else if let status = row.game.playStatus {
                    Text(status.title)
                }
            }
            .width(min: 60, ideal: 120)
            .customizationID("status")

            TableColumn("Last Played", value: \.lastPlayed) { row in
                Text(row.game.lastPlayed.map { $0.formatted(date: .numeric, time: .omitted) } ?? "")
            }
            .width(min: 70, ideal: 100)
            .customizationID("lastPlayed")

            TableColumn("Play Time", value: \.playTime) { row in
                Text(row.game.playTime > 0
                     ? Duration.seconds(row.game.playTime).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
                     : "")
            }
            .width(min: 60, ideal: 80)
            .customizationID("playTime")

            TableColumn("Added", value: \.dateAdded) { row in
                Text(row.game.dateAdded.formatted(date: .numeric, time: .omitted))
            }
            .width(min: 70, ideal: 100)
            .customizationID("added")
            .defaultVisibility(.hidden)
        } rows: {
            ForEach(games, id: \.persistentModelID) { game in
                TableRow(GameRow(game: game))
            }
        }
        .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
            let chosen = games.filter { ids.contains($0.persistentModelID) }
            if chosen.count == 1, let game = chosen.first {
                GameActionItems(actions: actions(game), placement: .contextMenu)
            } else if chosen.count > 1 {
                BatchActionItems(actions: batchActions(chosen))
            }
        } primaryAction: { ids in
            if ids.count == 1, let game = games.first(where: { ids.contains($0.persistentModelID) }) {
                actions(game).play()
            }
        }
        // The columns' ideal widths add up to more than the content column
        // has; as the column's ideal they squeezed the inspector.
        .frame(minWidth: AppMetrics.contentMinWidth, idealWidth: AppMetrics.contentMinWidth, maxWidth: .infinity,
               maxHeight: .infinity)
        // ⌘⌫ is the Game menu's shortcut while the list has focus, as in the grid.
        .focusedValue(\.isGridFocused, true)
        .onChange(of: controllerEvent) { _, event in
            if let event { handle(event.command) }
        }
        .accessibilityLabel("Games")
    }

    private var order: [PersistentIdentifier] { games.map(\.persistentModelID) }

    private var tableSelection: Binding<Set<PersistentIdentifier>> {
        Binding {
            selection.ids
        } set: { ids in
            selection.replace(with: ids, order: order)
        }
    }

    /// The header shows the library's sort order; clicking a header sets it.
    private var sortOrder: Binding<[KeyPathComparator<GameRow>]> {
        Binding {
            [GameRow.comparator(for: sort, reversed: isSortReversed)]
        } set: { comparators in
            guard let first = comparators.first, let newSort = GameRow.sort(for: first) else { return }
            let reversed = (first.order == .reverse) != newSort.isDescendingByDefault
            if newSort != sort { sort = newSort }
            if reversed != isSortReversed { isSortReversed = reversed }
        }
    }

    /// Controller presses: up and down move, confirm plays.
    private func handle(_ command: MenuCommand) {
        let index = selection.focus.flatMap { order.firstIndex(of: $0) }
        switch command {
        case .up, .down:
            guard !order.isEmpty else { return }
            let next = index.map { command == .up ? max($0 - 1, 0) : min($0 + 1, order.count - 1) } ?? 0
            selection.select(order[next])
        case .confirm:
            if let id = selection.single, let game = games.first(where: { $0.persistentModelID == id }) {
                actions(game).play()
            }
        case .secondary:
            if let id = selection.single, let game = games.first(where: { $0.persistentModelID == id }) {
                actions(game).toggleFavorite()
            }
        default:
            break
        }
    }
}

/// One table row; the sortable values of a game as non-optional keys.
/// Stored rather than computed: a sort comparator needs key paths that are
/// not tied to the main actor.
nonisolated struct GameRow: Identifiable {
    let game: Game
    let id: PersistentIdentifier
    let title: String
    let systemName: String
    let releaseDate: String
    let lastPlayed: Date
    let playTime: Double
    let dateAdded: Date

    @MainActor
    init(game: Game) {
        self.game = game
        id = game.persistentModelID
        title = game.title
        systemName = game.system?.name ?? game.systemID
        releaseDate = game.releaseDate ?? "9999"
        lastPlayed = game.lastPlayed ?? .distantPast
        playTime = game.playTime
        dateAdded = game.dateAdded
    }

    @MainActor
    static func comparator(for sort: LibrarySort, reversed: Bool) -> KeyPathComparator<GameRow> {
        let descending = sort.isDescendingByDefault != reversed
        let order: SortOrder = descending ? .reverse : .forward
        return switch sort {
        case .title: KeyPathComparator(\GameRow.title, order: order)
        case .system: KeyPathComparator(\GameRow.systemName, order: order)
        case .releaseYear: KeyPathComparator(\GameRow.releaseDate, order: order)
        case .recentlyPlayed: KeyPathComparator(\GameRow.lastPlayed, order: order)
        case .playTime: KeyPathComparator(\GameRow.playTime, order: order)
        case .recentlyAdded: KeyPathComparator(\GameRow.dateAdded, order: order)
        }
    }

    @MainActor
    static func sort(for comparator: KeyPathComparator<GameRow>) -> LibrarySort? {
        LibrarySort.allCases.first { comparator.keyPath == Self.comparator(for: $0, reversed: false).keyPath }
    }
}
