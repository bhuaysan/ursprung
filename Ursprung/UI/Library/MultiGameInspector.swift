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
                    // Set like a single game's title in its inspector.
                    Text("\(games.count) Games Selected")
                        .font(.title2.bold().width(.expanded))
                    Group {
                        if systems.count <= 3 {
                            FlowLayout(horizontalSpacing: AppSpacing.m, verticalSpacing: AppSpacing.xs) {
                                ForEach(systems, id: \.id) { system in
                                    HStack(spacing: AppSpacing.xs) {
                                        SystemIcon(system: system, isInline: true)
                                        Text(verbatim: system.shortName)
                                    }
                                }
                            }
                        } else {
                            Text("\(systems.count) systems")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, AppSpacing.xxs)
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

    /// What the selection adds up to, in sentences like a single game's activity.
    private var activitySection: some View {
        InfoSection("Activity") {
            Text(verbatim: activityText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    /// “2 h 2 min played in total. One of them is a favorite.”
    private var activityText: String {
        let playTime = games.reduce(0) { $0 + $1.playTime }
        let favorites = games.filter(\.isFavorite).count
        let missing = games.filter(\.isMissing).count
        var sentences = [playTime > 0
            ? String(localized: "\(Duration.seconds(playTime).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) played in total.")
            : String(localized: "None of them played yet.")]
        if favorites > 0 {
            sentences.append(favorites == 1 ? String(localized: "One of them is a favorite.")
                                            : String(localized: "\(favorites) of them are favorites."))
        }
        if missing > 0 {
            sentences.append(missing == 1 ? String(localized: "One file is missing.")
                                          : String(localized: "\(missing) files are missing."))
        }
        return sentences.joined(separator: " ")
    }

    /// The selected games' systems, in sidebar order.
    private var systems: [GameSystem] {
        let ids = Set(games.map(\.systemID))
        return SystemCatalog.all.filter { ids.contains($0.id) }
            .sorted { ($0.manufacturer, $0.year) < ($1.manufacturer, $1.year) }
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
