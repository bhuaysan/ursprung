// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct SidebarView: View {
    let games: [Game]
    @Binding var selection: LibrarySelection?
    @Environment(LibraryStore.self) private var library
    @Environment(MetadataService.self) private var metadata

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                row("All Games", symbol: "square.grid.2x2", count: games.count, tag: .all)
                row("Favorites", symbol: "heart", count: games.filter(\.isFavorite).count, tag: .favorites)
                row("Recently Played", symbol: "clock", count: games.filter { $0.lastPlayed != nil }.count, tag: .recent)
            }

            if !systems.isEmpty {
                Section("Systems") {
                    ForEach(systems, id: \.system.id) { entry in
                        Label {
                            Text(entry.system.name)
                                .lineLimit(1)
                        } icon: {
                            // Mixed towards the text colour so near-black systems stay visible in dark mode.
                            Circle()
                                .fill(Color(hex: entry.system.accent).mix(with: .primary, by: 0.3).gradient)
                                .frame(width: 10, height: 10)
                        }
                        .badge(entry.count)
                        .tag(LibrarySelection.system(entry.system.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if library.isScanning || metadata.lastError != nil {
                statusFooter
            }
        }
    }

    private func row(_ title: LocalizedStringKey, symbol: String, count: Int, tag: LibrarySelection) -> some View {
        Label(title, systemImage: symbol)
            .badge(count)
            .tag(tag)
    }

    private var systems: [(system: GameSystem, count: Int)] {
        let counts = Dictionary(grouping: games, by: \.systemID).mapValues(\.count)
        return SystemCatalog.all.compactMap { system in
            counts[system.id].map { (system, $0) }
        }
        .sorted { ($0.system.manufacturer, $0.system.year) < ($1.system.manufacturer, $1.system.year) }
    }

    @ViewBuilder
    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if library.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning library…").font(.caption)
                }
            }
            if let error = metadata.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}
