// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// One glass panel with menu-like rows, operable by pointer, keyboard and
/// controller. See docs/DESIGN_SPEC.md, section J.
struct PauseMenuView: View {
    /// The smaller of 600 pt and the window height minus 80 pt.
    let maxHeight: CGFloat
    let close: () -> Void

    @Environment(EmulationSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @FocusState private var isFocused: Bool
    // Reset every time the menu opens: focus starts on Resume.
    @State private var page = Page.main
    @State private var focusedRow = Row.resume
    @State private var focusedSlot = 1
    @State private var slotToDelete: SaveStateSlot?

    enum Page {
        case main, states, discs, options

        var width: CGFloat { self == .main || self == .discs ? 340 : 560 }

        /// The main page row that opens this page.
        var opener: Row {
            switch self {
            case .main: .resume
            case .states: .saveStates
            case .discs: .changeDisc
            case .options: .coreOptions
            }
        }
    }

    enum Row: Hashable {
        case resume, quickSave, quickLoad, saveStates, changeDisc, coreOptions, reset, quit
        case disc(Int)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            PanelDivider()
                .padding(.top, AppSpacing.l)
                .padding(.bottom, AppSpacing.s)
            ScrollViewReader { proxy in
                Group {
                    switch page {
                    case .main: FittingScrollView { mainPage }
                    case .states: FittingScrollView { statesPage }
                    case .discs: FittingScrollView { discsPage }
                    case .options: CoreOptionsPage()
                    }
                }
                .id(page)
                .transition(.opacity)
                .onChange(of: focusedRow) { proxy.scrollTo(focusedRow) }
                .onChange(of: focusedSlot) { proxy.scrollTo(focusedSlot) }
            }
        }
        .padding(20)
        .frame(width: page.width)
        .modifier(HeightLimit(maxHeight: maxHeight))
        .glassEffect(.regular, in: .rect(cornerRadius: AppMetrics.pausePanelRadius))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .space]) { press in
            guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
            let command: MenuCommand = switch press.key {
            case .upArrow: .up
            case .downArrow: .down
            case .leftArrow: .left
            case .rightArrow: .right
            default: .confirm
            }
            return perform(command) ? .handled : .ignored
        }
        .onDeleteCommand {
            // The Delete key arrives as the delete: action, not as a key press.
            guard page == .states, let state = slotState(focusedSlot) else { return }
            slotToDelete = state
        }
        .onExitCommand(perform: back)
        .onChange(of: session.input.menuEvent) { _, event in
            if let event { perform(event.command) }
        }
        .onAppear { isFocused = true }
        .focusedSceneValue(\.saveStateSlot, page == .states ? focusedSlot : nil)
        .confirmationDialog(Text("Delete the save state in slot \(slotToDelete?.slot ?? 0)?"),
                            isPresented: Binding(get: { slotToDelete != nil }, set: { if !$0 { slotToDelete = nil } }),
                            presenting: slotToDelete) { state in
            Button("Delete", role: .destructive) { session.deleteState(slot: state) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This can't be undone.")
        }
    }

    /// Focus highlights disappear when the panel is not where keys go.
    private var showsFocus: Bool { isFocused && appearsActive }

    private var header: some View {
        HStack(spacing: AppSpacing.s) {
            if page != .main {
                Button(action: back) {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .background(.white.opacity(0.1), in: .circle)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back")
            }
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(session.gameTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(session.coreName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Main page

    private var mainPage: some View {
        VStack(spacing: 0) {
            ResumeRow(isFocused: showsFocus && focusedRow == .resume, action: resume)
                .id(Row.resume)
                .onHover { if $0 { focusedRow = .resume } }
            GroupDivider()
            row(.quickSave, "Quick Save", symbol: "square.and.arrow.down", hint: .keys("F2"))
            row(.quickLoad, "Quick Load", symbol: "square.and.arrow.up", hint: .keys("F4"))
            row(.saveStates, "Save States…", symbol: "square.stack.3d.up", hint: .chevron)
            GroupDivider()
            if session.diskCount > 1 {
                row(.changeDisc, "Change Disc (\(session.currentDisk + 1)/\(session.diskCount))", symbol: "opticaldisc", hint: .chevron)
            }
            row(.coreOptions, "Core Options…", symbol: "slider.horizontal.3", hint: .chevron)
            GroupDivider()
            row(.reset, "Reset", symbol: "arrow.counterclockwise", hint: .keys("⌥⌘R"))
            row(.quit, "Quit Game", symbol: "xmark", isDestructive: true)
        }
    }

    private var discsPage: some View {
        VStack(spacing: 0) {
            ForEach(0..<session.diskCount, id: \.self) { index in
                row(.disc(index), "Disc \(index + 1)", symbol: "opticaldisc",
                    hint: index == session.currentDisk ? .checkmark : nil)
            }
        }
    }

    private func row(_ row: Row, _ title: LocalizedStringKey, symbol: String, hint: MenuRow.Hint? = nil,
                     isDestructive: Bool = false) -> some View {
        MenuRow(title: title, symbol: symbol, hint: hint, isDestructive: isDestructive,
                isFocused: showsFocus && focusedRow == row) { activate(row) }
            .disabled(!isEnabled(row))
            .id(row)
            .onHover { inside in
                // The pointer moves the focus, so hover and focus never show on different rows.
                if inside, isEnabled(row) { focusedRow = row }
            }
    }

    /// The focusable rows of the current page, top to bottom.
    private var rows: [Row] {
        switch page {
        case .main:
            [.resume, .quickSave, .quickLoad, .saveStates] + (session.diskCount > 1 ? [.changeDisc] : [])
                + [.coreOptions, .reset, .quit]
        case .discs:
            (0..<session.diskCount).map(Row.disc)
        case .states, .options:
            []
        }
    }

    private func isEnabled(_ row: Row) -> Bool {
        row != .quickLoad || session.slots.contains { $0.slot == 0 }
    }

    private func activate(_ row: Row) {
        switch row {
        case .resume: resume()
        case .quickSave: session.saveState(slot: 0)
        case .quickLoad: session.loadState(slot: 0)
        case .saveStates: show(.states)
        case .changeDisc:
            focusedRow = .disc(session.currentDisk)
            show(.discs)
        case .coreOptions: show(.options)
        case .reset: session.reset()
        case .quit: close()
        case .disc(let index):
            session.insertDisk(index)
            back()
        }
    }

    // MARK: Save states page

    private var statesPage: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AppSpacing.m, alignment: .top), count: 3),
                  spacing: AppSpacing.m) {
            ForEach(1...9, id: \.self) { slot in
                let state = slotState(slot)
                SlotView(slot: slot, state: state, isFocused: focusedSlot == slot, showsFocus: showsFocus,
                         save: { session.saveState(slot: slot) },
                         load: { session.loadState(slot: slot) },
                         delete: { slotToDelete = state })
                    .id(slot)
                    .onHover { if $0 { focusedSlot = slot } }
            }
        }
        // Room for the focus ring, which the scroll view would clip.
        .padding(6)
    }

    private func slotState(_ slot: Int) -> SaveStateSlot? {
        session.slots.first { $0.slot == slot }
    }

    // MARK: Navigation

    /// Handles a key or controller command; false when the page has no use for it.
    @discardableResult
    private func perform(_ command: MenuCommand) -> Bool {
        if command == .back {
            back()
            return true
        }
        switch page {
        case .main, .discs:
            switch command {
            case .up, .down:
                if let next = PauseMenuFocus.row(after: focusedRow, by: command == .up ? -1 : 1, in: rows.filter(isEnabled)) {
                    focusedRow = next
                }
            case .confirm:
                activate(focusedRow)
            default:
                return false
            }
        case .states:
            if command == .confirm {
                // Return loads an occupied slot and saves into an empty one.
                if slotState(focusedSlot) != nil {
                    session.loadState(slot: focusedSlot)
                } else {
                    session.saveState(slot: focusedSlot)
                }
            } else {
                focusedSlot = PauseMenuFocus.slot(from: focusedSlot, moving: command)
            }
        case .options:
            return false
        }
        return true
    }

    private func show(_ page: Page) {
        withAppAnimation(AppAnimation.panel, reduceMotion: reduceMotion) { self.page = page }
    }

    /// Main page: resume. Sub-page: back to the row that opened it.
    private func back() {
        guard page != .main else { return resume() }
        focusedRow = page.opener
        show(.main)
        isFocused = true
    }

    private func resume() {
        session.isMenuVisible = false
    }
}

extension FocusedValues {
    /// The focused slot on the Save States page; ⌘S saves into it.
    @Entry var saveStateSlot: Int?
}

/// Focus movement in the pause menu.
nonisolated enum PauseMenuFocus {
    /// The row `step` rows away from `current`, wrapping around. Starts at
    /// the first row when `current` is not in `rows`.
    static func row<Row: Equatable>(after current: Row, by step: Int, in rows: [Row]) -> Row? {
        guard let index = rows.firstIndex(of: current) else { return rows.first }
        let count = rows.count
        return rows[((index + step) % count + count) % count]
    }

    /// The slot (1–9) an arrow moves to in the 3 × 3 save-state grid; the
    /// edges stop the move.
    static func slot(from slot: Int, moving command: MenuCommand) -> Int {
        let column = (slot - 1) % 3
        let row = (slot - 1) / 3
        return switch command {
        case .left where column > 0: slot - 1
        case .right where column < 2: slot + 1
        case .up where row > 0: slot - 3
        case .down where row < 2: slot + 3
        default: slot
        }
    }
}

// MARK: - Rows

/// A plain row with a highlight shape: 36 pt high, 24 pt symbol column.
private struct MenuRow: View {
    enum Hint {
        case keys(String)
        case chevron
        case checkmark
    }

    let title: LocalizedStringKey
    let symbol: String
    let hint: Hint?
    let isDestructive: Bool
    let isFocused: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: symbol)
                    .frame(width: 24, alignment: .leading)
                Text(title)
                Spacer(minLength: AppSpacing.s)
                hintView
                    .font(.subheadline)
                    .foregroundStyle(isFocused ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
            .font(.body)
            .foregroundStyle(isFocused ? AnyShapeStyle(.white) : isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background {
                if isFocused {
                    RoundedRectangle(cornerRadius: AppMetrics.rowHighlightRadius, style: .continuous)
                        .fill(Color.accentColor)
                }
            }
            .contentShape(.rect)
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    @ViewBuilder private var hintView: some View {
        switch hint {
        case .keys(let keys):
            Text(verbatim: keys)
        case .chevron:
            Image(systemName: "chevron.right")
                .accessibilityHidden(true)
        case .checkmark:
            Image(systemName: "checkmark")
                .accessibilityLabel("Current")
        case nil:
            EmptyView()
        }
    }
}

/// The one prominent button in the panel, with a ring when it has the focus.
private struct ResumeRow: View {
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: "play.fill")
                    .frame(width: 24, alignment: .leading)
                Text("Resume")
                Spacer(minLength: AppSpacing.s)
                Text(verbatim: "esc")
                    .font(.subheadline)
                    .opacity(0.8)
            }
            .font(.body)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .focusable(false)
        .overlay {
            if isFocused {
                Capsule()
                    .strokeBorder(.white.opacity(0.85), lineWidth: 3)
                    .padding(-5)
                    .allowsHitTesting(false)
            }
        }
        // Keeps the ring inside the scroll view, which would clip it.
        .padding(5)
    }
}

/// 8 pt gap with a hairline between row groups.
private struct GroupDivider: View {
    var body: some View {
        PanelDivider()
            .padding(.vertical, AppSpacing.xs)
    }
}

// MARK: - Save state slot

private struct SlotView: View {
    let slot: Int
    let state: SaveStateSlot?
    let isFocused: Bool
    let showsFocus: Bool
    let save: () -> Void
    let load: () -> Void
    let delete: () -> Void

    private let radius = AppMetrics.artworkRadius

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            thumbnail
                .padding(.bottom, AppSpacing.xs)
            Text("Slot \(slot)")
                .font(.subheadline.weight(.semibold))
            Text(state.map { $0.date.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "Empty"))
                .font(.caption)
                .foregroundStyle(.secondary)
            // Shown on the focused slot (the pointer moves the focus), so
            // nothing is context-menu-only.
            HStack(spacing: AppSpacing.s) {
                Button("Save", action: save)
                Button("Load", action: load)
                    .disabled(state == nil)
                Spacer(minLength: 0)
                Button("Delete…", systemImage: "trash", action: delete)
                    .labelStyle(.iconOnly)
                    .disabled(state == nil)
                    .help("Delete…")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.top, AppSpacing.xs)
            .opacity(isFocused ? 1 : 0)
        }
        .contentShape(.rect)
        .contextMenu {
            Button("Save", action: save)
            Button("Load", action: load)
                .disabled(state == nil)
            Divider()
            Button("Delete…", role: .destructive, action: delete)
                .disabled(state == nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Slot \(slot)"))
    }

    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.white.opacity(0.06))
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay {
                if let state {
                    ArtworkImage(url: state.thumbnailURL, maxPixel: 320, contentMode: .fill) { Color.clear }
                        .id(state.date)
                } else {
                    Image(systemName: "plus")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .artworkFrame(radius: radius)
            .overlay {
                if isFocused, showsFocus {
                    let inset = AppMetrics.selectionRingGap + AppMetrics.selectionRingWidth
                    RoundedRectangle(cornerRadius: radius + inset, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: AppMetrics.selectionRingWidth)
                        .padding(-inset)
                }
            }
    }
}

// MARK: - Core options page

private struct CoreOptionsPage: View {
    @Environment(EmulationSession.self) private var session
    @State private var values: [String: String] = [:]
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FilterField(text: $filter)
                .padding(.bottom, AppSpacing.m)
            FittingScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(options, id: \.key) { option in
                        optionRow(option)
                        PanelDivider()
                    }
                    if options.isEmpty {
                        Text(filter.isEmpty ? "This core has no options." : "No options match “\(filter)”.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Text("Some options apply after a reset.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: AppSpacing.m)
                Button("Reset Game") { session.reset() }
                Button("Restore Defaults") {
                    session.resetCoreOptions()
                    values = [:]
                }
            }
            .buttonStyle(.borderless)
            .padding(.top, AppSpacing.m)
        }
    }

    private func optionRow(_ option: CoreOption) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(option.title)
                    .font(.body)
                if let info = option.info {
                    Text(info)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(info)
                }
            }
            Spacer(minLength: AppSpacing.m)
            Picker(option.title, selection: binding(for: option)) {
                ForEach(Array(zip(option.values, option.labels)), id: \.0) { value, label in
                    Text(label).tag(value)
                }
            }
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: 200, alignment: .trailing)
        }
    }

    private var options: [CoreOption] {
        let all = session.core?.options ?? []
        guard !filter.isEmpty else { return all }
        return all.filter { $0.title.localizedStandardContains(filter) || $0.key.localizedStandardContains(filter) }
    }

    private func binding(for option: CoreOption) -> Binding<String> {
        Binding(
            get: { values[option.key] ?? session.core?.value(forOption: option.key) ?? option.defaultValue },
            set: { value in
                values[option.key] = value
                session.setCoreOption(value, for: option.key)
            }
        )
    }
}

/// A text field drawn like a search field; `.searchable` only exists for toolbars.
private struct FilterField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Filter Options", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AppSpacing.s)
        .padding(.vertical, 5)
        .background(.white.opacity(0.08), in: .capsule)
    }
}

/// Offers the content at most `maxHeight` and takes the content's size;
/// `frame(maxHeight:)` would grow a short panel to the full limit.
private struct HeightLimit: ViewModifier {
    let maxHeight: CGFloat

    func body(content: Content) -> some View {
        HeightLimitLayout(maxHeight: maxHeight) { content }
    }
}

private struct HeightLimitLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = min(proposal.height ?? .infinity, maxHeight)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// A scroll view as tall as its content, up to the height it is offered,
/// so short pages keep the panel small and long ones scroll inside it.
private struct FittingScrollView<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: height)
    }
}
