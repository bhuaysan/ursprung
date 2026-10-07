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

    /// What the selection adds up to, in sentences like a single game's activity.
    private var activitySection: some View {
        InfoSection("Activity") {
            Text(verbatim: activityText)
                .fixedSize(horizontal: false, vertical: true)
            OrganizeTags(actions: actions.organize)
                .padding(.top, AppSpacing.xs)
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

/// Status and collections as tags, like the labels on a shelf: a menu for
/// the status, a tag per collection the games are in, and a menu that adds
/// them to more.
struct OrganizeTags: View {
    let actions: OrganizeActions

    var body: some View {
        FlowLayout(horizontalSpacing: AppSpacing.xs, verticalSpacing: AppSpacing.xs) {
            Menu {
                StatusItems(actions: actions)
            } label: {
                statusLabel
            }
            .modifier(TagMenu())
            .accessibilityLabel(Text("Status"))
            ForEach(memberships, id: \.self) { collection in
                Menu {
                    Button("Remove from Collection", systemImage: "minus.circle") {
                        actions.setCollection(collection, false)
                    }
                } label: {
                    Tag { Label(collection, systemImage: "rectangle.stack") }
                }
                .modifier(TagMenu())
                .help(Text("Collection “\(collection)”"))
            }
            Menu {
                ForEach(others, id: \.self) { collection in
                    Button(collection) { actions.setCollection(collection, true) }
                }
                if !others.isEmpty { Divider() }
                Button("New Collection…", action: actions.newCollection)
            } label: {
                Tag(isQuiet: true) {
                    if memberships.isEmpty {
                        Label("Add to Collection", systemImage: "plus")
                    } else {
                        Image(systemName: "plus")
                    }
                }
            }
            .modifier(TagMenu())
            .help("Add to Collection")
            .accessibilityLabel(Text("Add to Collection"))
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let status = actions.commonStatus {
            Tag { Label(status.title, systemImage: status.symbol) }
        } else if Set(actions.games.map(\.playStatusRaw)).count > 1 {
            Tag(isQuiet: true) { Label("Mixed Status", systemImage: "flag") }
        } else {
            Tag(isQuiet: true) { Label("No Status", systemImage: "flag") }
        }
    }

    /// Collections every game is in.
    private var memberships: [String] {
        actions.collections.filter(actions.containsAll)
    }

    /// Collections at least one game is not in yet.
    private var others: [String] {
        actions.collections.filter { !actions.containsAll($0) }
    }
}

/// A capsule around a label; quiet tags offer something rather than show it.
private struct Tag<Content: View>: View {
    var isQuiet = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .lineLimit(1)
            .foregroundStyle(isQuiet ? .secondary : .primary)
            .padding(.horizontal, AppSpacing.s)
            .padding(.vertical, 3)
            .background(isQuiet ? AnyShapeStyle(.clear) : AnyShapeStyle(.fill.tertiary), in: .capsule)
            .overlay {
                if isQuiet {
                    Capsule().strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            .contentShape(.capsule)
    }
}

/// A menu drawn as its tag only, without a button frame or arrow.
private struct TagMenu: ViewModifier {
    func body(content: Content) -> some View {
        content
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
    }
}
