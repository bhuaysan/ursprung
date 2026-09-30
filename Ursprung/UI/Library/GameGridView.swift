// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftData
import SwiftUI

struct GameGridView: View {
    let games: [Game]
    @Binding var selectedGameID: PersistentIdentifier?
    let cardWidth: Double
    /// Shows the system's logo above the grid.
    var system: GameSystem?
    let actions: (Game) -> GameActions

    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let system {
                    SystemBanner(system: system)
                        .padding(.horizontal, 28)
                        .padding(.top, 24)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth * 1.35), spacing: 28, alignment: .top)],
                          alignment: .leading, spacing: 32) {
                    ForEach(games) { game in
                        let actions = actions(game)
                        GameCard(game: game, isSelected: game.persistentModelID == selectedGameID, actions: actions)
                            .id(game.persistentModelID)
                            .onTapGesture(count: 2, perform: actions.play)
                            .simultaneousGesture(TapGesture().onEnded {
                                selectedGameID = game.persistentModelID
                                focused = true
                            })
                            .contextMenu { GameActionItems(actions: actions, placement: .contextMenu) }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                guard let game = selectedGame else { return .ignored }
                actions(game).play()
                return .handled
            }
            .onKeyPress(.delete, phases: .down) { press in
                // ⌘⌫ only in the grid: as a menu shortcut it would also fire
                // while the search field is being edited.
                guard press.modifiers.contains(.command), let game = selectedGame else { return .ignored }
                actions(game).requestRemoval()
                return .handled
            }
            .onKeyPress(.leftArrow) { move(by: -1, proxy: proxy) }
            .onKeyPress(.rightArrow) { move(by: 1, proxy: proxy) }
            .background {
                // Clicking empty space clears the selection.
                Color.clear.contentShape(Rectangle()).onTapGesture { selectedGameID = nil }
            }
        }
    }

    private var selectedGame: Game? {
        games.first { $0.persistentModelID == selectedGameID }
    }

    private func move(by offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !games.isEmpty else { return .ignored }
        let index = games.firstIndex { $0.persistentModelID == selectedGameID } ?? (offset > 0 ? -1 : games.count)
        let next = min(max(index + offset, 0), games.count - 1)
        selectedGameID = games[next].persistentModelID
        withAnimation(.snappy) { proxy.scrollTo(games[next].persistentModelID) }
        return .handled
    }

}

/// Banner above a system's games: the official logo and a console photo on the
/// system's accent colour.
struct SystemBanner: View {
    let system: GameSystem
    @Environment(SystemMediaStore.self) private var systemMedia

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                if let logo = systemMedia.logo(for: system) {
                    ArtworkImage(url: logo, maxPixel: 600, isTemplate: true) { Color.clear }
                        .frame(maxWidth: 300, maxHeight: 64, alignment: .leading)
                } else {
                    Text(system.name)
                        .font(.largeTitle.weight(.bold))
                }
                Text(verbatim: "\(system.manufacturer) · \(system.year)")
                    .font(.callout.weight(.medium))
                    .opacity(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let photo = systemMedia.photo(for: system) {
                ArtworkImage(url: photo, maxPixel: 800) { Color.clear }
                    .frame(maxWidth: 280, maxHeight: 132)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
        .frame(height: 172)
        .background(LinearGradient.system(accent: system.accent), in: .rect(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(system.name)
    }
}

struct GameCard: View {
    let game: Game
    let isSelected: Bool
    let actions: GameActions

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Text(game.system?.shortName ?? game.systemID)
                    if let year = game.releaseYear {
                        Text("·")
                        Text(year)
                    }
                    Spacer(minLength: 0)
                    if game.isFavorite {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.pink)
                            .imageScale(.small)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.18)) { isHovering = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .gameAccessibilityActions(actions)
    }

    /// Box art sits on a common baseline inside a square slot, so rows stay
    /// aligned regardless of each system's box shape.
    private var cover: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .bottom) {
                ArtworkImage(url: game.boxArtURL, maxPixel: 560) {
                    PlaceholderCover(title: game.title, system: game.system)
                        .aspectRatio(game.system?.boxAspect ?? 0.72, contentMode: .fit)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                }
                .overlay(alignment: .center) {
                    if isHovering {
                        Button(action: actions.play) {
                            Image(systemName: "play.fill")
                                .font(.title2)
                                .frame(width: 52, height: 52)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                        .help("Play")
                    }
                }
                .shadow(color: .black.opacity(isHovering ? 0.35 : 0.22), radius: isHovering ? 14 : 8, y: isHovering ? 8 : 4)
                .scaleEffect(isHovering ? 1.025 : 1, anchor: .bottom)
                .padding(4)
                .background(alignment: .bottom) {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
            }
    }
}
