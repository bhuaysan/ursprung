// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct SidebarView: View {
    /// The games that are not hidden.
    let games: [Game]
    let hiddenCount: Int
    @Binding var selection: LibrarySelection?
    /// Every collection, in sidebar order.
    let collections: [String]
    let collectionActions: CollectionActions
    /// Retries a failed metadata fetch from the activity footer.
    let retryMetadata: () -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(MetadataService.self) private var metadata
    @Environment(SystemMediaStore.self) private var systemMedia
    @Environment(ShaderEditor.self) private var shaderEditor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("sidebarSystemsExpanded") private var systemsExpanded = true
    @AppStorage("sidebarCollectionsExpanded") private var collectionsExpanded = true

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                row("All Games", symbol: "square.grid.2x2", count: games.count, tag: .all)
                row("Favorites", symbol: "heart", count: games.filter(\.isFavorite).count, tag: .favorites)
                // No badge: the number of played games says nothing about this list.
                row("Recently Played", symbol: "clock", count: nil, tag: .recent)
                if hiddenCount > 0 {
                    row("Hidden", symbol: "eye.slash", count: hiddenCount, tag: .hidden)
                }
            }

            if !collections.isEmpty {
                Section("Collections", isExpanded: $collectionsExpanded) {
                    ForEach(collections, id: \.self) { collection in
                        Label(collection, systemImage: "rectangle.stack")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                            .help(collection)
                            .badge(collectionCounts[collection] ?? 0)
                            .tag(LibrarySelection.collection(collection))
                            .contextMenu {
                                Button("Rename…") { collectionActions.rename(collection) }
                                Button("Delete Collection…", role: .destructive) { collectionActions.delete(collection) }
                                Divider()
                                Button("New Collection…", action: collectionActions.create)
                            }
                    }
                    .onMove(perform: collectionActions.move)
                }
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
                        .contextMenu {
                            // A standalone emulator applies its own post-processing.
                            if entry.system.cores.contains(where: \.isLibretro) {
                                Button("Edit Shader…") {
                                    shaderEditor.open(.system(entry.system.id))
                                    openWindow(id: WindowID.shaderEditor)
                                }
                            }
                        }
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

    private var collectionCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for game in games {
            for collection in game.collections { counts[collection, default: 0] += 1 }
        }
        return counts
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

/// Creating, renaming, deleting and ordering collections from the sidebar.
struct CollectionActions {
    let create: () -> Void
    let rename: (String) -> Void
    /// Asks first; the games stay in the library.
    let delete: (String) -> Void
    let move: (IndexSet, Int) -> Void
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
