// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftData
import SwiftUI

/// A shelf of box art with an explicit column count, so the selection moves
/// in all four directions. See docs/DESIGN_SPEC.md, section E.
struct GameGridView: View {
    let games: [Game]
    @Binding var selectedGameID: PersistentIdentifier?
    /// One of `AppMetrics.coverSteps`.
    let coverStep: Double
    /// Shows the system's logo above the grid.
    var system: GameSystem?
    let actions: (Game) -> GameActions

    @Environment(\.appearsActive) private var appearsActive
    @FocusState private var focused: Bool
    @State private var visible = VisibleGames()
    /// Height of the toolbar the content scrolls under.
    @State private var topInset = 0.0
    @State private var typeSelect = TypeSelect()
    /// Set when a click focuses the grid, so focus entry does not select a game.
    @State private var isFocusingByClick = false

    var body: some View {
        // A GeometryReader rather than a measured @State width: writing the
        // width into state on every layout pass keeps AppKit from narrowing
        // the column when the inspector opens.
        GeometryReader { geometry in
            let metrics = GridMetrics(width: geometry.size.width, coverStep: coverStep)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let system {
                            SystemBanner(system: system, gameCount: games.count)
                                .padding(.top, 20)
                        }
                        grid(metrics.layout)
                            .padding(.top, system == nil ? 20 : AppSpacing.l)
                            .padding(.bottom, AppSpacing.xxl)
                    }
                    .padding(.horizontal, metrics.padding)
                    .background(alignment: .top) {
                        // Reaches up under the toolbar, so scrolling to it reaches the very top.
                        Color.clear
                            .id(ScrollAnchor.top)
                            .frame(height: 1)
                            .padding(.top, -topInset)
                    }
                }
                .onScrollGeometryChange(for: Double.self) { $0.contentInsets.top } action: { topInset = $1 }
                .onScrollTargetVisibilityChange(idType: PersistentIdentifier.self) { visible.ids = $0 }
                .focusable()
                .focused($focused)
                // ⌘⌫ is the Game menu's shortcut while the grid has focus;
                // an onKeyPress handler here never received it.
                .focusedValue(\.isGridFocused, true)
                .focusEffectDisabled()
                .onChange(of: focused) { _, isFocused in
                    // Tabbing into the grid selects the first visible game.
                    if isFocused, !isFocusingByClick, selectedGameID == nil, let index = firstVisibleIndex {
                        select(index, columns: metrics.layout.columns, proxy: proxy)
                    }
                    isFocusingByClick = false
                }
                .onKeyPress(.return) {
                    guard let game = selectedGame else { return .ignored }
                    actions(game).play()
                    return .handled
                }
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end, .pageUp, .pageDown]) { press in
                    guard press.modifiers.isDisjoint(with: [.command, .option, .control]),
                          let move = GridMove(press.key) else { return .ignored }
                    return perform(move, columns: metrics.layout.columns, proxy: proxy)
                }
                .onKeyPress(characters: .alphanumerics.union(.punctuationCharacters).union(.whitespaces), phases: .down) { press in
                    guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
                    return handleTypeSelect(press.characters, columns: metrics.layout.columns, proxy: proxy)
                }
                .background {
                    // Clicking empty space clears the selection.
                    Color.clear.contentShape(Rectangle()).onTapGesture {
                        focusByClick()
                        selectedGameID = nil
                    }
                }
            }
        }
    }

    private func grid(_ layout: GridLayout) -> some View {
        let columns = Array(repeating: GridItem(.fixed(layout.slotWidth), spacing: layout.spacing, alignment: .top),
                            count: layout.columns)
        let isActive = focused && appearsActive
        return LazyVGrid(columns: columns, alignment: .leading, spacing: AppMetrics.gridRowSpacing) {
            ForEach(games, id: \.persistentModelID) { game in
                let id = game.persistentModelID
                let actions = actions(game)
                GameCard(game: game, slotWidth: layout.slotWidth, showsSystem: system == nil,
                         selection: id == selectedGameID ? (isActive ? .focused : .unfocused) : nil,
                         actions: actions, select: { selectedGameID = id })
                    .id(id)
                    .background {
                        // The card plus room for the toolbar above and a margin below:
                        // scrolling to it keeps the whole card and its ring in the clear.
                        Color.clear
                            .id(ScrollAnchor.card(id))
                            .padding(.top, -(topInset + AppSpacing.m))
                            .padding(.bottom, -AppSpacing.m)
                    }
                    .onTapGesture(count: 2, perform: actions.play)
                    .simultaneousGesture(TapGesture().onEnded {
                        focusByClick()
                        selectedGameID = id
                    })
                    .contextMenu { GameActionItems(actions: actions, placement: .contextMenu) }
            }
        }
        .scrollTargetLayout()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Games")
        .accessibilityValue(games.count == 1 ? String(localized: "1 game") : String(localized: "\(games.count) games"))
    }

    private var selectedGame: Game? {
        games.first { $0.persistentModelID == selectedGameID }
    }

    private var selectedIndex: Int? {
        games.firstIndex { $0.persistentModelID == selectedGameID }
    }

    private var firstVisibleIndex: Int? {
        let ids = Set(visible.ids)
        return games.firstIndex { ids.contains($0.persistentModelID) } ?? (games.isEmpty ? nil : 0)
    }

    private func focusByClick() {
        guard !focused else { return }
        isFocusingByClick = true
        focused = true
    }

    private func perform(_ move: GridMove, columns: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let index = GridNavigation.target(of: move, from: selectedIndex, count: games.count, columns: columns,
                                                pageRows: visible.ids.count / columns,
                                                entry: firstVisibleIndex ?? 0) else { return .ignored }
        select(index, columns: columns, proxy: proxy)
        return .handled
    }

    private func handleTypeSelect(_ characters: String, columns: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let prefix = typeSelect.append(characters) else { return .ignored }
        if let index = TypeSelect.firstMatch(for: prefix, in: games.lazy.map(\.title)) {
            select(index, columns: columns, proxy: proxy)
        }
        return .handled
    }

    /// Selects a game and scrolls it into view without animation, so key repeat stays fluid.
    private func select(_ index: Int, columns: Int, proxy: ScrollViewProxy) {
        let id = games[index].persistentModelID
        selectedGameID = id
        if index < columns {
            // The first row also shows the header and top padding.
            proxy.scrollTo(ScrollAnchor.top)
        } else {
            // A far-away card is only laid out once it has been scrolled to.
            proxy.scrollTo(id)
            Task { proxy.scrollTo(ScrollAnchor.card(id)) }
        }
    }
}

/// The games on screen, read only by key handlers. A plain reference rather
/// than view state: updating state on every scroll or resize re-renders the
/// grid and keeps AppKit from narrowing the column when the inspector opens.
private final class VisibleGames {
    var ids: [PersistentIdentifier] = []
}

/// Padding and columns for one content width.
private struct GridMetrics {
    let padding: CGFloat
    let layout: GridLayout

    init(width: CGFloat, coverStep: Double) {
        padding = width < AppMetrics.compactContentWidth ? AppMetrics.compactGridPadding : AppMetrics.gridPadding
        layout = GridLayout(availableWidth: width - 2 * padding, coverStep: coverStep)
    }
}

private enum ScrollAnchor: Hashable {
    case top
    case card(PersistentIdentifier)
}

private extension GridMove {
    init?(_ key: KeyEquivalent) {
        switch key {
        case .leftArrow: self = .left
        case .rightArrow: self = .right
        case .upArrow: self = .up
        case .downArrow: self = .down
        case .home: self = .home
        case .end: self = .end
        case .pageUp: self = .pageUp
        case .pageDown: self = .pageDown
        default: return nil
        }
    }
}

/// Larger Covers, Smaller Covers and Default Size, for the View menu and the
/// toolbar's view options.
struct CoverSizeItems: View {
    /// Only the menu bar registers the ⌘+ / ⌘− / ⌘0 shortcuts.
    var showsShortcuts = false

    @AppStorage(PrefKey.gridSize) private var gridSize = AppMetrics.defaultCoverStep

    var body: some View {
        let larger = CoverSize.larger(than: gridSize)
        let smaller = CoverSize.smaller(than: gridSize)
        Button("Larger Covers", systemImage: "plus.magnifyingglass") { if let larger { gridSize = larger } }
            .keyboardShortcut(showsShortcuts ? KeyboardShortcut("+") : nil)
            .disabled(larger == nil)
        Button("Smaller Covers", systemImage: "minus.magnifyingglass") { if let smaller { gridSize = smaller } }
            .keyboardShortcut(showsShortcuts ? KeyboardShortcut("-") : nil)
            .disabled(smaller == nil)
        Button("Default Size", systemImage: "1.magnifyingglass") { gridSize = CoverSize.defaultStep }
            .keyboardShortcut(showsShortcuts ? KeyboardShortcut("0") : nil)
            .disabled(CoverSize.snapped(gridSize) == CoverSize.defaultStep)
    }
}

/// Banner above a system's games: the official logo and a console photo on the
/// system's accent colour. Kept instead of the spec's plain header (section F)
/// at the user's request.
struct SystemBanner: View {
    let system: GameSystem
    let gameCount: Int
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
        .accessibilityLabel(Text(verbatim: [system.name, system.manufacturer, String(system.year), countText]
            .joined(separator: ", ")))
        .accessibilityAddTraits(.isHeader)
    }

    private var countText: String {
        gameCount == 1 ? String(localized: "1 game") : String(localized: "\(gameCount) games")
    }
}

/// One game on the shelf: box art on a common baseline, title and a metadata line.
struct GameCard: View {
    enum Selection {
        /// Accent ring: the grid has focus in the key window.
        case focused
        /// Grey ring: focus is elsewhere or the window is inactive.
        case unfocused
    }

    let game: Game
    /// The slot's actual width: the cover step, or less when two columns only fit smaller.
    let slotWidth: Double
    /// Inside a system the header already names it, so the metadata line shows the developer instead.
    let showsSystem: Bool
    let selection: Selection?
    let actions: GameActions
    /// VoiceOver's default action selects, as in Finder.
    let select: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            slot
            Text(game.title)
                .font(.body.weight(.medium))
                .lineLimit(2)
                .padding(.top, AppSpacing.s)
            HStack(spacing: AppSpacing.xs) {
                Text(verbatim: metadataLine)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if game.isFavorite {
                    Image(systemName: "heart.fill")
                        .imageScale(.small)
                        .foregroundStyle(.favorite)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.top, AppSpacing.xxs)
        }
        .contentShape(Rectangle())
        .help(game.title)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(game.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(selection != nil ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
        .gameAccessibilityActions(actions)
    }

    /// “SNES · 1992”, or “1992 · Developer” inside a system.
    private var metadataLine: String {
        let parts = showsSystem ? [game.system?.shortName ?? game.systemID, game.releaseYear]
                                : [game.releaseYear, game.developer]
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var accessibilityValue: String {
        [game.system?.name, game.releaseYear, game.isFavorite ? String(localized: "Favorite") : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private var isHighContrast: Bool { contrast == .increased }

    private var radius: CGFloat {
        slotWidth <= 150 ? AppMetrics.smallArtworkRadius : AppMetrics.artworkRadius
    }

    /// Box art sits on a common baseline inside a square slot, so rows stay
    /// aligned regardless of each system's box shape.
    private var slot: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .bottom) { artwork }
    }

    private var artwork: some View {
        ArtworkImage(url: game.boxArtURL, maxPixel: 560) { placeholder }
            .artworkFrame(radius: radius)
            .shadow(color: .black.opacity(isHovering ? 0.28 : 0.18), radius: isHovering ? 10 : 4, y: isHovering ? 5 : 2)
            .overlay(alignment: .bottomTrailing) {
                // Permanent on the selected card, so Play is never hover-only.
                if isHovering || selection != nil {
                    playButton
                        .transition(.opacity)
                }
            }
            .appAnimation(AppAnimation.quick, value: isHovering)
            // Outside the animation: selection changes are instant.
            .overlay { selectionRing }
    }

    /// Neutral while the art loads; the generated cover only when there is no art at all.
    @ViewBuilder
    private var placeholder: some View {
        let aspect = game.system?.boxAspect ?? 0.72
        if game.boxArtURL == nil {
            PlaceholderCover(title: game.title, system: game.system)
                .aspectRatio(aspect, contentMode: .fit)
        } else {
            Rectangle()
                .fill(.quaternary)
                .aspectRatio(aspect, contentMode: .fit)
        }
    }

    private var playButton: some View {
        Button(action: actions.play) {
            Image(systemName: "play.fill")
                .frame(width: AppMetrics.coverPlayButton, height: AppMetrics.coverPlayButton)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .padding(AppSpacing.s)
        .help("Play")
    }

    /// A ring around the art itself, separated by a gap of window background so
    /// it stays visible on red or coral box art.
    @ViewBuilder
    private var selectionRing: some View {
        if let selection {
            let lineWidth = isHighContrast ? AppMetrics.highContrastSelectionRingWidth : AppMetrics.selectionRingWidth
            let inset = AppMetrics.selectionRingGap + lineWidth / 2
            RoundedRectangle(cornerRadius: radius + inset, style: .continuous)
                .stroke(selection == .focused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary), lineWidth: lineWidth)
                .padding(-inset)
                .allowsHitTesting(false)
        }
    }
}
