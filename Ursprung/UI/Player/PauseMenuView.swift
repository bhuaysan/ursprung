// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct PauseMenuView: View {
    let close: () -> Void

    @Environment(EmulationSession.self) private var session
    @State private var page: Page = .main

    enum Page { case main, states, options }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.45))
                .ignoresSafeArea()
                .onTapGesture { session.isMenuVisible = false }

            GlassEffectContainer {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    switch page {
                    case .main: mainPage
                    case .states: SaveStatesPage()
                    case .options: CoreOptionsPage()
                    }
                }
                .padding(26)
                .frame(width: page == .main ? 360 : 560)
                .frame(maxHeight: 620)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
            }
        }
        .environment(\.colorScheme, .dark)
        .onExitCommand { page == .main ? (session.isMenuVisible = false) : (page = .main) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if page != .main {
                Button {
                    withAnimation(.smooth) { page = .main }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .font(.title3.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.gameTitle)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                Text(session.coreName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var mainPage: some View {
        VStack(spacing: 10) {
            MenuButton("Resume", symbol: "play.fill", prominent: true) { session.isMenuVisible = false }
                .keyboardShortcut(.defaultAction)
            MenuButton("Quick Save", symbol: "square.and.arrow.down") { session.saveState(slot: 0) }
            MenuButton("Quick Load", symbol: "square.and.arrow.up") { session.loadState(slot: 0) }
                .disabled(!session.slots.contains { $0.slot == 0 })
            MenuButton("Save States…", symbol: "square.stack.3d.up") { withAnimation(.smooth) { page = .states } }
            if session.diskCount > 1 {
                Menu {
                    ForEach(0..<session.diskCount, id: \.self) { index in
                        Button {
                            session.insertDisk(index)
                        } label: {
                            if index == session.currentDisk {
                                Label("Disc \(index + 1)", systemImage: "checkmark")
                            } else {
                                Text("Disc \(index + 1)")
                            }
                        }
                    }
                } label: {
                    Label("Change Disc (\(session.currentDisk + 1)/\(session.diskCount))", systemImage: "opticaldisc")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            MenuButton("Core Options…", symbol: "slider.horizontal.3") { withAnimation(.smooth) { page = .options } }
            MenuButton("Reset", symbol: "arrow.counterclockwise") { session.reset() }
            MenuButton("Quit Game", symbol: "xmark", role: .destructive, action: close)
        }
    }
}

private struct MenuButton: View {
    let title: LocalizedStringKey
    let symbol: String
    var prominent = false
    var role: ButtonRole?
    let action: () -> Void

    init(_ title: LocalizedStringKey, symbol: String, prominent: Bool = false, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.prominent = prominent
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.large)
        .modifier(ProminenceModifier(prominent: prominent))
    }
}

private struct ProminenceModifier: ViewModifier {
    let prominent: Bool
    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.glass)
        }
    }
}

private struct SaveStatesPage: View {
    @Environment(EmulationSession.self) private var session

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                ForEach(1...9, id: \.self) { slot in
                    SlotCard(slot: slot, state: session.slots.first { $0.slot == slot })
                }
            }
        }
        .frame(maxHeight: 460)
    }
}

private struct SlotCard: View {
    let slot: Int
    let state: SaveStateSlot?
    @Environment(EmulationSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.06))
                if let state {
                    ArtworkImage(url: state.thumbnailURL, maxPixel: 320) { Color.clear }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .id(state.date)
                } else {
                    Image(systemName: "plus")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)

            Text("Slot \(slot)")
                .font(.caption.weight(.semibold))
            Text(state.map { $0.date.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "Empty"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Button("Save") { session.saveState(slot: slot) }
                Button("Load") { session.loadState(slot: slot) }
                    .disabled(state == nil)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .contextMenu {
            if let state {
                Button("Delete", role: .destructive) { session.deleteState(slot: state) }
            }
        }
    }
}

private struct CoreOptionsPage: View {
    @Environment(EmulationSession.self) private var session
    @State private var values: [String: String] = [:]
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Filter Options", text: $filter)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(options, id: \.key) { option in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .font(.callout)
                                if let info = option.info {
                                    Text(info)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                            }
                            Spacer(minLength: 12)
                            Picker(option.title, selection: binding(for: option)) {
                                ForEach(Array(zip(option.values, option.labels)), id: \.0) { value, label in
                                    Text(label).tag(value)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 200)
                        }
                        Divider().opacity(0.4)
                    }
                }
            }
            .frame(maxHeight: 420)
            HStack {
                Text("Some options take effect after a reset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Defaults") {
                    session.resetCoreOptions()
                    values = [:]
                }
                .buttonStyle(.glass)
            }
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
