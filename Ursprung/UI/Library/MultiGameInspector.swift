// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The inspector while several games are selected: what they have in
/// common and the actions that apply to all of them.
struct MultiGameInspector: View {
    let actions: BatchActions

    private var games: [Game] { actions.games }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                covers
                    .padding(.top, AppSpacing.l)
                    .padding(.horizontal, AppSpacing.l)
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("\(games.count) Games Selected")
                        .font(.title3.weight(.semibold))
                    Text(verbatim: systemSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, AppSpacing.m)
                .padding(.horizontal, AppSpacing.l)
                actionRow
                    .padding(.top, AppSpacing.l)
                    .padding(.horizontal, AppSpacing.l)
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    organizeSection
                    activitySection
                }
                .padding(.top, AppSpacing.xl)
                .padding(.horizontal, AppSpacing.l)
                .padding(.bottom, AppSpacing.xl)
            }
        }
    }

    /// Up to three covers, fanned out.
    private var covers: some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(Array(games.prefix(3).enumerated().reversed()), id: \.offset) { index, game in
                ArtworkImage(url: game.boxArtURL, maxPixel: 300) {
                    PlaceholderCover(title: game.title, system: game.system)
                        .aspectRatio(game.system?.boxAspect ?? 0.72, contentMode: .fit)
                }
                .artworkFrame(radius: AppMetrics.smallArtworkRadius)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                .frame(maxWidth: 84, maxHeight: 112, alignment: .bottomLeading)
                .rotationEffect(.degrees(Double(index) * 6), anchor: .bottom)
                .offset(x: CGFloat(index) * 26)
            }
        }
        .frame(height: 124, alignment: .bottomLeading)
        .accessibilityHidden(true)
    }

    private var actionRow: some View {
        HStack(spacing: AppSpacing.s) {
            Button {
                actions.setFavorite(!actions.allFavorite)
            } label: {
                Label(actions.allFavorite ? "Remove from Favorites" : "Add to Favorites",
                      systemImage: actions.allFavorite ? "heart.slash" : "heart")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)

            Menu {
                BatchActionItems(actions: actions)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body)
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help("More Actions")
            .accessibilityLabel("More Actions")
        }
    }

    private var organizeSection: some View {
        InfoSection("Organize") {
            InfoRowLayout("Status") {
                Picker("Status", selection: Binding(get: { actions.organize.commonStatus },
                                                    set: { actions.organize.setStatus($0) })) {
                    Text(verbatim: "–").tag(PlayStatus?.none)
                    Divider()
                    ForEach(PlayStatus.allCases) { status in
                        Text(status.title).tag(PlayStatus?.some(status))
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

    private var activitySection: some View {
        let playTime = games.reduce(0) { $0 + $1.playTime }
        let favorites = games.filter(\.isFavorite).count
        let missing = games.filter(\.isMissing).count
        return InfoSection("Activity") {
            InfoRow("Play Time", playTime > 0
                    ? Duration.seconds(playTime).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) : "–")
            InfoRow("Favorites", String(favorites))
            if missing > 0 {
                InfoRow("Missing", String(missing))
            }
        }
    }

    private var systemSummary: String {
        let systems = Set(games.map(\.systemID)).compactMap(SystemCatalog.system(withID:)).map(\.shortName).sorted()
        return systems.count <= 3 ? systems.joined(separator: ", ")
            : String(localized: "\(systems.count) systems")
    }
}

/// A checkbox per collection, plus New Collection…, for the inspectors.
struct CollectionToggles: View {
    let actions: OrganizeActions

    var body: some View {
        InfoRowLayout("Collections") {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                ForEach(actions.collections, id: \.self) { collection in
                    Toggle(collection, isOn: Binding(get: { actions.containsAll(collection) },
                                                     set: { actions.setCollection(collection, $0) }))
                        .toggleStyle(.checkbox)
                        .lineLimit(1)
                }
                Button("New Collection…", action: actions.newCollection)
                    .buttonStyle(.link)
            }
        }
    }
}
