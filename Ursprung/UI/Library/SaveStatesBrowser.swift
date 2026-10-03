// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftData
import SwiftUI

/// Every save state of a game, outside the running game: per core the
/// automatic state, the slots and recently replaced states. States of the
/// game's current core can start the game.
struct SaveStatesBrowser: View {
    let game: Game
    /// Starts the game from a state.
    let play: (SaveStateSlot) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(EmulationSession.self) private var session
    @State private var cores: [SaveStateStore.CoreStates] = []
    @State private var stateToRename: SaveStateSlot?
    @State private var newName = ""
    @State private var stateToDelete: SaveStateSlot?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text("Save States")
                        .font(.headline)
                    Text(game.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isRunning {
                    StatusLabel("Running", systemImage: "play.circle", kind: .neutral)
                        .font(.callout)
                        .help("Open the pause menu to save or load while the game runs.")
                }
            }
            .padding(20)

            if cores.isEmpty {
                ContentUnavailableView("No Save States", systemImage: "square.stack.3d.up",
                                       description: Text("Save states you make in the pause menu appear here."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.xl) {
                        ForEach(cores) { core in
                            coreSection(core)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }

            Divider()
            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [SaveStateStore.gameDirectory(in: AppPaths.states, gameID: game.id)])
                }
                .disabled(cores.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 640, height: 560)
        .onAppear(perform: reload)
        .alert("Name Save State", isPresented: Binding(get: { stateToRename != nil }, set: { if !$0 { stateToRename = nil } }),
               presenting: stateToRename) { state in
            TextField("Name", text: $newName)
            Button("Save") {
                try? SaveStateStore.rename(state, to: newName)
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: { state in
            Text("A name for the state in \(state.slotTitle).")
        }
        .confirmationDialog(stateToDelete?.isHistory == true ? Text("Delete this replaced state?") : Text("Delete this save state?"),
                            isPresented: Binding(get: { stateToDelete != nil }, set: { if !$0 { stateToDelete = nil } }),
                            presenting: stateToDelete) { state in
            Button("Delete", role: .destructive) {
                SaveStateStore.discard(state)
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: { state in
            Text(state.isHistory || state.isAutosave || state.isLegacy ? "This can't be undone."
                                                                        : "You can restore it from Recently Replaced.")
        }
    }

    private func coreSection(_ core: SaveStateStore.CoreStates) -> some View {
        let canPlay = core.coreID != nil && core.coreID == game.effectiveCore?.id && !isRunning
        return VStack(alignment: .leading, spacing: AppSpacing.m) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(coreName(core.coreID))
                    .font(.headline)
                if core.coreID == nil {
                    Text("Saved by an earlier version of Ursprung, possibly with another core.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if core.coreID != game.effectiveCore?.id {
                    Text("The game uses another core now. Choose this core in the inspector to load these states.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: AppSpacing.m, alignment: .top)],
                      alignment: .leading, spacing: AppSpacing.m) {
                ForEach([core.autosave].compactMap { $0 } + core.slots) { state in
                    StateCard(state: state, canPlay: canPlay, play: { start(state) },
                              rename: { beginRenaming(state) }, delete: { stateToDelete = state })
                }
            }
            if !core.history.isEmpty {
                DisclosureGroup {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: AppSpacing.m, alignment: .top)],
                              alignment: .leading, spacing: AppSpacing.m) {
                        ForEach(core.history) { state in
                            StateCard(state: state, canPlay: canPlay, play: { start(state) },
                                      restore: core.coreID.map { coreID in { restore(state, coreID: coreID) } },
                                      delete: { stateToDelete = state })
                        }
                    }
                    .padding(.top, AppSpacing.s)
                } label: {
                    Text("Recently Replaced (\(core.history.count))")
                        .font(.callout.weight(.medium))
                }
            }
        }
    }

    private var isRunning: Bool {
        session.isActive && session.gameID == game.persistentModelID
    }

    private func coreName(_ coreID: String?) -> String {
        guard let coreID else { return String(localized: "Unknown Core") }
        return game.system?.cores.first { $0.id == coreID }?.name
            ?? SystemCatalog.all.flatMap(\.cores).first { $0.id == coreID }?.name ?? coreID
    }

    private func reload() {
        cores = SaveStateStore.allStates(in: AppPaths.states, gameID: game.id)
    }

    private func beginRenaming(_ state: SaveStateSlot) {
        newName = state.name ?? ""
        stateToRename = state
    }

    private func start(_ state: SaveStateSlot) {
        dismiss()
        play(state)
    }

    private func restore(_ state: SaveStateSlot, coreID: String) {
        try? SaveStateStore.restore(state, toSlot: state.slot,
                                    in: SaveStateStore.directory(in: AppPaths.states, gameID: game.id, coreID: coreID))
        reload()
    }
}

/// One state: thumbnail, name or slot, date and its actions.
private struct StateCard: View {
    let state: SaveStateSlot
    let canPlay: Bool
    let play: () -> Void
    var rename: (() -> Void)?
    var restore: (() -> Void)?
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            RoundedRectangle(cornerRadius: AppMetrics.artworkRadius, style: .continuous)
                .fill(.quaternary)
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    ArtworkImage(url: state.thumbnailURL, maxPixel: 360, contentMode: .fill) { Color.clear }
                }
                .clipShape(.rect(cornerRadius: AppMetrics.artworkRadius, style: .continuous))
                .padding(.bottom, AppSpacing.xs)
                .accessibilityHidden(true)
            Text(verbatim: state.name ?? state.slotTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text(verbatim: subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: AppSpacing.s) {
                Button("Play from Here", action: play)
                    .disabled(!canPlay)
                Spacer(minLength: 0)
                if let restore {
                    Button("Restore", systemImage: "arrow.uturn.backward", action: restore)
                        .help(state.slot == 0 ? Text("Restore as Quick Save") : Text("Restore to Slot \(state.slot)"))
                }
                if let rename {
                    Button("Rename…", systemImage: "pencil", action: rename)
                        .disabled(!state.canRename)
                        .help("Rename…")
                }
                Button("Delete…", systemImage: "trash", action: delete)
                    .help("Delete…")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.top, AppSpacing.xxs)
        }
        .contextMenu {
            Button("Play from Here", action: play)
                .disabled(!canPlay)
            if let restore {
                Button(state.slot == 0 ? "Restore as Quick Save" : "Restore to Slot \(state.slot)", action: restore)
            }
            if let rename {
                Button("Rename…", action: rename)
                    .disabled(!state.canRename)
            }
            Divider()
            Button("Delete…", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: [state.name, state.slotTitle].compactMap { $0 }.joined(separator: ", ")))
    }

    private var subtitle: String {
        var parts: [String] = []
        if state.name != nil { parts.append(state.slotTitle) }
        if let replaced = state.replaced {
            parts.append(String(localized: "Replaced \(replaced.formatted(.relative(presentation: .named)))"))
        } else {
            parts.append(state.date.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }
}
