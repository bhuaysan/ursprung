// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct SidebarView: View {
    let games: [Game]
    @Binding var selection: LibrarySelection?
    /// Retries a failed metadata fetch from the activity footer.
    let retryMetadata: () -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(MetadataService.self) private var metadata
    @Environment(SystemMediaStore.self) private var systemMedia
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if hasActivity {
                activityFooter
                    .transition(.appFade(or: .move(edge: .bottom).combined(with: .opacity), reduceMotion: reduceMotion))
            }
        }
        .appAnimation(AppAnimation.standard, value: hasActivity)
    }

    private var hasActivity: Bool {
        Activity.isPending(library: library, metadata: metadata, systemMedia: systemMedia)
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

    /// Hidden entirely while nothing runs and no error is pending.
    private var activityFooter: some View {
        VStack(spacing: 0) {
            Divider()
            ActivityStatusView(retry: retryMetadata)
                .padding(.horizontal, AppSpacing.m)
                .padding(.vertical, 10)
        }
    }
}
