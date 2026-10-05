// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
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
    @Environment(\.openWindow) private var openWindow
    @FocusState private var isFocused: Bool
    // Reset every time the menu opens: focus starts on Resume.
    @State private var page = Page.main
    /// Follows `page`; set apart so it can jump under Reduce Motion.
    @State private var width = Page.main.width
    @State private var focusedRow = Row.resume
    @State private var focusedSlot = 1
    @State private var slotToDelete: SaveStateSlot?
    @State private var stateToRename: SaveStateSlot?
    @State private var newStateName = ""
    @State private var isAddingCheat = false
    @State private var newCheatName = ""
    @State private var newCheatCode = ""
    @State private var achievementList: [AchievementInfo] = []
    @State private var pointer = PointerAnchor()

    enum Page {
        case main, states, history, discs, options, cheats, achievements

        var width: CGFloat { self == .main || self == .discs ? 340 : 560 }

        /// The main page row that opens this page.
        var opener: Row {
            switch self {
            case .main: .resume
            case .states, .history: .saveStates
            case .discs: .changeDisc
            case .options: .coreOptions
            case .cheats: .cheats
            case .achievements: .achievements
            }
        }

        /// The page Back returns to.
        var parent: Page { self == .history ? .states : .main }
    }

    enum Row: Hashable {
        case resume, quickSave, quickLoad, saveStates, screenshot, changeDisc, cheats, achievements, manual, typing
        case coreOptions, reset, quit
        case disc(Int)
        case history(Int)
        case cheat(Int)
        case addCheat
        case achievement(Int)
    }

    /// The Recently Replaced row below the 3 × 3 slot grid, as a focus position.
    private static let historySlot = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            PanelDivider()
                .padding(.top, AppSpacing.l)
                .padding(.bottom, AppSpacing.s)
            ScrollViewReader { proxy in
                // Old and new page overlap while they cross-fade; stacked,
                // they briefly made the panel as tall as both together.
                ZStack(alignment: .topLeading) {
                    Group {
                        switch page {
                        case .main: FittingScrollView { mainPage }
                        case .states: FittingScrollView { statesPage }
                        case .history: FittingScrollView { historyPage }
                        case .discs: FittingScrollView { discsPage }
                        case .options: CoreOptionsPage()
                        case .cheats: FittingScrollView { cheatsPage }
                        case .achievements: FittingScrollView { achievementsPage }
                        }
                    }
                    .id(page)
                    .transition(.opacity)
                }
                .onChange(of: focusedRow) { proxy.scrollTo(focusedRow) }
                .onChange(of: focusedSlot) { proxy.scrollTo(focusedSlot) }
            }
        }
        .padding(20)
        .frame(width: width)
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
            if page == .states, let state = slotState(focusedSlot) {
                slotToDelete = state
            } else if page == .history, case .history(let index) = focusedRow, session.history.indices.contains(index) {
                slotToDelete = session.history[index]
            }
        }
        .onExitCommand(perform: back)
        .onChange(of: session.input.menuEvent) { _, event in
            if let event { perform(event.command) }
        }
        .onAppear { isFocused = true }
        .focusedSceneValue(\.saveStateSlot, page == .states ? focusedSlot : nil)
        .confirmationDialog(deleteTitle,
                            isPresented: Binding(get: { slotToDelete != nil }, set: { if !$0 { slotToDelete = nil } }),
                            presenting: slotToDelete) { state in
            Button("Delete", role: .destructive) { session.deleteState(slot: state) }
            Button("Cancel", role: .cancel) {}
        } message: { state in
            Text(state.isHistory ? "This can't be undone." : "You can restore it from Recently Replaced.")
        }
        .alert("Name Save State", isPresented: Binding(get: { stateToRename != nil }, set: { if !$0 { stateToRename = nil } }),
               presenting: stateToRename) { state in
            TextField("Name", text: $newStateName)
            Button("Save") { session.renameState(state, to: newStateName) }
            if state.name != nil {
                Button("Remove Name") { session.renameState(state, to: nil) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { state in
            Text("A name for the state in \(state.slotTitle).")
        }
        .alert("Add Cheat", isPresented: $isAddingCheat) {
            TextField("Name", text: $newCheatName)
            TextField("Code", text: $newCheatCode)
            Button("Add") { addCheat() }
                .disabled(newCheatCode.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Game Genie, Action Replay or GameShark codes, as the core understands them. Join several codes with “+”.")
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
                .onHover { if $0, pointer.hasMoved { focusedRow = .resume } }
            GroupDivider()
            row(.quickSave, "Quick Save", symbol: "square.and.arrow.down", hint: .keys(session.input.hotkeys.bindings[.quickSave]?.label ?? ""))
            row(.quickLoad, "Quick Load", symbol: "square.and.arrow.up", hint: .keys(session.input.hotkeys.bindings[.quickLoad]?.label ?? ""))
            row(.saveStates, "Save States…", symbol: "square.stack.3d.up", hint: .chevron)
            GroupDivider()
            row(.screenshot, "Take Screenshot", symbol: "camera", hint: .keys(session.input.hotkeys.bindings[.screenshot]?.label ?? ""))
            if session.diskCount > 1 {
                row(.changeDisc, "Change Disc (\(session.currentDisk + 1)/\(session.diskCount))", symbol: "opticaldisc", hint: .chevron)
            }
            if session.achievementGame != nil {
                row(.achievements, "Achievements…", symbol: "trophy", hint: .chevron)
            }
            row(.cheats, "Cheats…", symbol: "wand.and.stars", hint: .chevron)
            if hasManual {
                row(.manual, "Manual", symbol: "book")
            }
            if session.hasComputerKeyboard {
                row(.typing, "Type on Keyboard", symbol: "keyboard", hint: session.isTyping ? .checkmark : nil)
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
                row(.disc(index), discTitle(index), symbol: "opticaldisc",
                    hint: index == session.currentDisk ? .checkmark : nil)
            }
        }
    }

    /// “Disc 2”, or “Disc 2: Label” when the playlist labels it.
    private func discTitle(_ index: Int) -> LocalizedStringKey {
        if session.discLabels.indices.contains(index), let label = session.discLabels[index] {
            return "Disc \(index + 1): \(label)"
        }
        return "Disc \(index + 1)"
    }

    private var deleteTitle: Text {
        guard let slotToDelete else { return Text(verbatim: "") }
        if slotToDelete.isHistory { return Text("Delete this replaced state?") }
        return Text("Delete the save state in slot \(slotToDelete.slot)?")
    }

    private func row(_ row: Row, _ title: LocalizedStringKey, symbol: String, hint: MenuRow.Hint? = nil,
                     isDestructive: Bool = false) -> some View {
        self.row(row, Text(title), symbol: symbol, hint: hint, isDestructive: isDestructive)
    }

    private func row(_ row: Row, _ title: Text, symbol: String, hint: MenuRow.Hint? = nil,
                     isDestructive: Bool = false) -> some View {
        MenuRow(title: title, symbol: symbol, hint: hint, isDestructive: isDestructive,
                isFocused: showsFocus && focusedRow == row) { activate(row) }
            .disabled(!isEnabled(row))
            .id(row)
            .onHover { inside in
                // The pointer moves the focus, so hover and focus never show on different rows.
                if inside, isEnabled(row), pointer.hasMoved { focusedRow = row }
            }
    }

    /// The focusable rows of the current page, top to bottom.
    private var rows: [Row] {
        switch page {
        case .main:
            [.resume, .quickSave, .quickLoad, .saveStates, .screenshot] + (session.diskCount > 1 ? [.changeDisc] : [])
                + (session.achievementGame != nil ? [.achievements] : []) + [.cheats]
                + (hasManual ? [.manual] : []) + (session.hasComputerKeyboard ? [.typing] : [])
                + [.coreOptions, .reset, .quit]
        case .discs:
            (0..<session.diskCount).map(Row.disc)
        case .history:
            session.history.indices.map(Row.history)
        case .cheats:
            canUseCheats ? session.cheats.indices.map(Row.cheat) + [.addCheat] : []
        case .achievements:
            achievementList.indices.map(Row.achievement)
        case .states, .options:
            []
        }
    }

    private func isEnabled(_ row: Row) -> Bool {
        switch row {
        case .quickLoad: session.slots.contains { $0.slot == 0 } && !session.isHardcore
        default: true
        }
    }

    private var hasManual: Bool {
        session.runningGameID.map { ManualStore.manual(in: AppPaths.extras, gameID: $0) != nil } ?? false
    }

    private var canUseCheats: Bool { session.supportsCheats && !session.isHardcore }

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
        case .screenshot: session.takeScreenshot()
        case .cheats:
            focusedRow = canUseCheats ? (session.cheats.isEmpty ? .addCheat : .cheat(0)) : .cheats
            show(.cheats)
        case .achievements:
            achievementList = session.achievementList()
            focusedRow = .achievement(0)
            show(.achievements)
        case .manual:
            if let id = session.runningGameID { openWindow(id: WindowID.manual, value: id) }
        case .typing:
            session.toggleTyping()
            if session.isTyping { resume() }
        case .cheat(let index):
            guard session.cheats.indices.contains(index) else { return }
            var cheats = session.cheats
            cheats[index].isEnabled.toggle()
            session.setCheats(cheats)
        case .addCheat:
            newCheatName = ""
            newCheatCode = ""
            isAddingCheat = true
        case .achievement:
            break
        case .reset: session.reset()
        case .quit: close()
        case .disc(let index):
            session.insertDisk(index)
            back()
        case .history(let index):
            if session.history.indices.contains(index) { session.loadState(session.history[index]) }
        }
    }

    // MARK: Save states page

    private var statesPage: some View {
        VStack(spacing: AppSpacing.m) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AppSpacing.m, alignment: .top), count: 3),
                      spacing: AppSpacing.m) {
                ForEach(1...9, id: \.self) { slot in
                    let state = slotState(slot)
                    SlotView(slot: slot, state: state, issues: state.map(session.issues(for:)) ?? [],
                             isFocused: focusedSlot == slot, showsFocus: showsFocus,
                             save: { session.saveState(slot: slot) },
                             load: { session.loadState(slot: slot) },
                             rename: { state.map(startRenaming) },
                             delete: { slotToDelete = state })
                        .id(slot)
                        .onHover { if $0, pointer.hasMoved { focusedSlot = slot } }
                }
            }
            if !session.history.isEmpty {
                MenuRow(title: Text("Recently Replaced (\(session.history.count))"), symbol: "clock.arrow.circlepath",
                        hint: .chevron, isDestructive: false,
                        isFocused: showsFocus && focusedSlot == Self.historySlot) { openHistory() }
                    .id(Self.historySlot)
                    .onHover { if $0, pointer.hasMoved { focusedSlot = Self.historySlot } }
            }
        }
        // Room for the focus ring, which the scroll view would clip.
        .padding(6)
    }

    /// States replaced by newer ones or deleted, newest first.
    private var historyPage: some View {
        VStack(spacing: 0) {
            Text("Saving into a slot or deleting a state keeps the previous state here for a while.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, AppSpacing.s)
            ForEach(Array(session.history.enumerated()), id: \.element.id) { index, entry in
                HistoryRow(entry: entry, issues: session.issues(for: entry),
                           isFocused: showsFocus && focusedRow == .history(index),
                           load: { session.loadState(entry) },
                           restore: { session.restoreState(entry) },
                           delete: { slotToDelete = entry })
                    .id(Row.history(index))
                    .onHover { if $0, pointer.hasMoved { focusedRow = .history(index) } }
            }
        }
    }

    // MARK: Cheats page

    @ViewBuilder
    private var cheatsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if session.isHardcore {
                pageNote("Cheats are off in hardcore mode.")
            } else if !session.supportsCheats {
                pageNote("\(session.coreName) doesn't support cheats.")
            } else {
                if session.cheats.isEmpty {
                    pageNote("Add a code, or import a cheat file (.cht) in the game's info panel.")
                }
                ForEach(Array(session.cheats.enumerated()), id: \.element.id) { index, cheat in
                    row(.cheat(index), Text(verbatim: cheat.name),
                        symbol: cheat.isEnabled ? "checkmark.circle.fill" : "circle")
                        .help(cheat.code)
                        .accessibilityValue(cheat.isEnabled ? Text("On") : Text("Off"))
                }
                row(.addCheat, "Add Cheat…", symbol: "plus")
                pageNote("Cheats can make games misbehave; if one does, switch the cheat off and load a state.")
                    .padding(.top, AppSpacing.s)
            }
        }
    }

    private func addCheat() {
        let code = newCheatCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        let name = newCheatName.trimmingCharacters(in: .whitespacesAndNewlines)
        session.setCheats(session.cheats + [Cheat(name: name.isEmpty ? code : name, code: code, isEnabled: true)])
        focusedRow = .cheat(session.cheats.count - 1)
    }

    // MARK: Achievements page

    @ViewBuilder
    private var achievementsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let game = session.achievementGame {
                pageNote("\(game.unlockedCount) of \(game.achievementCount) unlocked · \(game.unlockedPoints) of \(game.points) points")
            }
            ForEach(Array(achievementList.enumerated()), id: \.element.achievementID) { index, achievement in
                AchievementRow(achievement: achievement, isFocused: showsFocus && focusedRow == .achievement(index))
                    .id(Row.achievement(index))
                    .onHover { if $0, pointer.hasMoved { focusedRow = .achievement(index) } }
            }
        }
    }

    private func pageNote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, AppSpacing.s)
    }

    private func openHistory() {
        focusedRow = .history(0)
        show(.history)
    }

    private func startRenaming(_ state: SaveStateSlot) {
        newStateName = state.name ?? ""
        stateToRename = state
    }

    private func slotState(_ slot: Int) -> SaveStateSlot? {
        session.slots.first { $0.slot == slot }
    }

    // MARK: Navigation

    /// Handles a key or controller command; false when the page has no use for it.
    @discardableResult
    private func perform(_ command: MenuCommand) -> Bool {
        pointer.anchor()
        if command == .back {
            back()
            return true
        }
        switch page {
        case .main, .discs, .history, .cheats, .achievements:
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
            if focusedSlot == Self.historySlot {
                switch command {
                case .confirm: openHistory()
                case .up: focusedSlot = 8
                default: return false
                }
            } else if command == .confirm {
                // Return loads an occupied slot and saves into an empty one.
                if slotState(focusedSlot) != nil {
                    session.loadState(slot: focusedSlot)
                } else {
                    session.saveState(slot: focusedSlot)
                }
            } else if command == .secondary, let state = slotState(focusedSlot), state.canRename {
                startRenaming(state)
            } else if command == .down, focusedSlot > 6, !session.history.isEmpty {
                focusedSlot = Self.historySlot
            } else {
                focusedSlot = PauseMenuFocus.slot(from: focusedSlot, moving: command)
            }
        case .options:
            return false
        }
        return true
    }

    /// Cross-fades to `page`. The width animates with it, or jumps under
    /// Reduce Motion (section O).
    private func show(_ page: Page) {
        pointer.anchor()
        if reduceMotion {
            withTransaction(\.disablesAnimations, true) { width = page.width }
        }
        withAppAnimation(AppAnimation.panel, reduceMotion: reduceMotion) {
            self.page = page
            width = page.width
        }
    }

    /// Main page: resume. Sub-page: back to the row that opened it.
    private func back() {
        guard page != .main else { return resume() }
        if page == .history {
            focusedSlot = Self.historySlot
        } else {
            focusedRow = page.opener
        }
        show(page.parent)
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

    let title: Text
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
                title
                    .lineLimit(1)
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
    /// Why the state may not load as expected; shown as a warning.
    let issues: [SaveStateIssue]
    let isFocused: Bool
    let showsFocus: Bool
    let save: () -> Void
    let load: () -> Void
    let rename: () -> Void
    let delete: () -> Void

    private let radius = AppMetrics.artworkRadius

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            thumbnail
                .padding(.bottom, AppSpacing.xs)
            (state?.name.map { Text(verbatim: $0) } ?? Text("Slot \(slot)"))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .help(state?.name.map { String(localized: "Slot \(slot): \($0)") } ?? "")
            HStack(spacing: AppSpacing.xxs) {
                if !issues.isEmpty {
                    Image(systemName: StatusKind.warning.defaultSymbol)
                        .foregroundStyle(StatusKind.warning.color)
                        .accessibilityHidden(true)
                }
                Text(state.map { $0.date.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "Empty"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(issueText ?? "")
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text(verbatim: issueText ?? ""))
            // Shown on the focused slot (the pointer moves the focus), so
            // nothing is context-menu-only.
            HStack(spacing: AppSpacing.s) {
                Button("Save", action: save)
                Button("Load", action: load)
                    .disabled(state == nil)
                Spacer(minLength: 0)
                Button("Rename…", systemImage: "pencil", action: rename)
                    .labelStyle(.iconOnly)
                    .disabled(state?.canRename != true)
                    .help("Rename…")
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
            Button("Rename…", action: rename)
                .disabled(state?.canRename != true)
            Divider()
            Button("Delete…", role: .destructive, action: delete)
                .disabled(state == nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state?.name.map { Text("Slot \(slot): \($0)") } ?? Text("Slot \(slot)"))
    }

    private var issueText: String? {
        issues.isEmpty ? nil : issues.map(EmulationSession.describe).joined(separator: " ")
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

// MARK: - History

/// A replaced or deleted state: thumbnail, where it was, when it was
/// replaced, and Load / Restore / Delete on the focused row.
private struct HistoryRow: View {
    let entry: SaveStateSlot
    let issues: [SaveStateIssue]
    let isFocused: Bool
    let load: () -> Void
    let restore: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.m) {
            RoundedRectangle(cornerRadius: AppMetrics.smallArtworkRadius, style: .continuous)
                .fill(.white.opacity(0.06))
                .frame(width: 64, height: 48)
                .overlay {
                    ArtworkImage(url: entry.thumbnailURL, maxPixel: 160, contentMode: .fill) { Color.clear }
                }
                .clipShape(.rect(cornerRadius: AppMetrics.smallArtworkRadius, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(verbatim: [entry.slotTitle, entry.name].compactMap { $0 }.joined(separator: " · "))
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: AppSpacing.xxs) {
                    if !issues.isEmpty {
                        Image(systemName: StatusKind.warning.defaultSymbol)
                            .foregroundStyle(StatusKind.warning.color)
                            .accessibilityHidden(true)
                    }
                    Text("Replaced \((entry.replaced ?? entry.date).formatted(.relative(presentation: .named)))")
                }
                .font(.caption)
                .foregroundStyle(isFocused ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                .help(Text("Saved \(entry.date.formatted(date: .abbreviated, time: .shortened))"))
            }
            Spacer(minLength: AppSpacing.s)
            HStack(spacing: AppSpacing.s) {
                Button("Load", action: load)
                Button(restoreTitle, action: restore)
                Button("Delete…", systemImage: "trash", action: delete)
                    .labelStyle(.iconOnly)
                    .help("Delete…")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .opacity(isFocused ? 1 : 0)
        }
        .foregroundStyle(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            if isFocused {
                RoundedRectangle(cornerRadius: AppMetrics.rowHighlightRadius, style: .continuous)
                    .fill(Color.accentColor)
            }
        }
        .contentShape(.rect)
        .contextMenu {
            Button("Load", action: load)
            Button(restoreTitle, action: restore)
            Divider()
            Button("Delete…", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: [entry.slotTitle, entry.name].compactMap { $0 }.joined(separator: ", ")))
    }

    private var restoreTitle: LocalizedStringKey {
        entry.slot == 0 ? "Restore as Quick Save" : "Restore to Slot \(entry.slot)"
    }
}

// MARK: - Achievements

/// One achievement: badge, title, description, progress and points.
private struct AchievementRow: View {
    let achievement: AchievementInfo
    let isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.m) {
            Group {
                if let url = achievement.imageURL.flatMap(URL.init(string:)) {
                    RemoteBadge(url: url, size: 40)
                } else {
                    Image(systemName: "trophy").frame(width: 40, height: 40)
                }
            }
            .opacity(achievement.isUnlocked ? 1 : 0.6)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(achievement.title)
                    .font(.body.weight(.semibold))
                Text(achievement.detail)
                    .font(.subheadline)
                    .foregroundStyle(isFocused ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                if !achievement.isUnlocked, !achievement.progress.isEmpty {
                    HStack(spacing: AppSpacing.s) {
                        ProgressView(value: Double(achievement.progressFraction))
                            .frame(maxWidth: 160)
                        Text(achievement.progress)
                            .font(.caption.monospacedDigit())
                    }
                }
                if let date = achievement.unlockDate {
                    Text("Unlocked \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(isFocused ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                } else if achievement.isUnsupported {
                    Text("Not supported by this version of Ursprung")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: AppSpacing.s)
            Text("\(achievement.points) pts")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(isFocused ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
        }
        .foregroundStyle(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            if isFocused {
                RoundedRectangle(cornerRadius: AppMetrics.rowHighlightRadius, style: .continuous)
                    .fill(Color.accentColor)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(achievement.isUnlocked ? Text("Unlocked") : Text("Locked"))
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
                .padding(.bottom, AppSpacing.s)
            Toggle("Only for This Game", isOn: Binding(
                get: { session.usesGameCoreOptions },
                set: { enabled in
                    session.setUsesGameCoreOptions(enabled)
                    values = [:]
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Changes apply to this game only. Off: they apply to every game of this core.")
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

/// The content as tall as it is, or in a scroll view when it is taller than
/// the height it is offered, so short pages keep the panel small and long
/// ones scroll inside it. Decided in one layout pass: a measured height
/// started each new page at zero and made the panel jump while it animated.
private struct FittingScrollView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
                .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// Where the pointer was when the keyboard, a controller or a page change
/// last moved the focus. A panel that opens or changes size under a resting
/// pointer sends hover events too; only a pointer that has moved since may
/// take the focus. Not observed: only event handlers read it.
private final class PointerAnchor {
    private var location = NSEvent.mouseLocation

    var hasMoved: Bool { NSEvent.mouseLocation != location }

    func anchor() {
        location = NSEvent.mouseLocation
    }
}
