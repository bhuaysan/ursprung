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
    @AppStorage("sidebarSystemsExpanded") private var systemsExpanded = true

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                row("All Games", symbol: "square.grid.2x2", count: games.count, tag: .all)
                row("Favorites", symbol: "heart", count: games.filter(\.isFavorite).count, tag: .favorites)
                // No badge: the number of played games says nothing about this list.
                row("Recently Played", symbol: "clock", count: nil, tag: .recent)
            }

            if !systems.isEmpty {
                Section("Systems", isExpanded: $systemsExpanded) {
                    ForEach(systems, id: \.system.id) { entry in
                        Label {
                            Text(entry.system.name)
                                .lineLimit(1)
                        } icon: {
                            SystemDot(color: entry.system.identityColor)
                        }
                        // The tooltip only covers the label's frame; widen it to the whole row.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                        .help(entry.system.name)
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

    private func row(_ title: LocalizedStringKey, symbol: String, count: Int?, tag: LibrarySelection) -> some View {
        Label(title, systemImage: symbol)
            .lineLimit(1)
            .badge(count ?? 0) // 0 hides the badge
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

/// Flat system identity dot, centred in the sidebar's icon slot. Decorative:
/// the row label already names the system.
private struct SystemDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            // Keeps near-white and near-black systems visible on the sidebar material.
            .strokeBorder(.separator, lineWidth: 0.5)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}
