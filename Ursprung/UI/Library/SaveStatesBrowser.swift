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
    @State private var failure: Failure?

    /// An action on a state that did not work.
    private struct Failure {
        let title: LocalizedStringKey
        let message: String
    }

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
                if isRunningExternally {
                    // The game has no pause menu in Ursprung; its emulator saves on request.
                    Menu("Save State", systemImage: "square.and.arrow.down") {
                        ForEach(SaveStateStore.slotRange, id: \.self) { slot in
                            Button(slot == 0 ? "Quick Save" : "Slot \(slot)") { session.saveState(slot: slot) }
                        }
                    }
                    .fixedSize()
                    .disabled(!session.canUseExternalStates)
                    .help(session.externalStatesNote.map { Text($0) } ?? Text("Save the running game into a slot"))
                } else if isRunning {
                    StatusLabel("Running", systemImage: "play.circle", kind: .neutral)
                        .font(.callout)
                        .help(standalone.map { Text("Save and load in \($0.name) while the game runs.") }
                            ?? Text("Open the pause menu to save or load while the game runs."))
                }
            }
            .padding(20)

            if cores.isEmpty {
                ContentUnavailableView("No Save States", systemImage: "square.stack.3d.up",
                                       description: standalone.map { Text("Save states you make in \($0.name) appear here.") }
                                           ?? Text("Save states you make in the pause menu appear here."))
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
        // A save through the running emulator lands while the sheet is open.
        .onChange(of: session.slots) { reload() }
        .alert("Name Save State", isPresented: Binding(get: { stateToRename != nil }, set: { if !$0 { stateToRename = nil } }),
               presenting: stateToRename) { state in
            TextField("Name", text: $newName)
            Button("Save") {
                let origin = state.isARMSX2
                    ? ARMSX2States.context(for: state, gameFileName: game.fileName, gameFileSize: game.fileSize) : nil
                try? SaveStateStore.rename(state, to: newName, origin: origin)
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
                do {
                    try SaveStateStore.discard(state)
                } catch {
                    failure = Failure(title: "The save state couldn't be deleted", message: error.localizedDescription)
                }
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: { state in
            Text(state.isHistory || state.isAutosave || state.isLegacy ? "This can't be undone."
                                                                        : "You can restore it from Recently Replaced.")
        }
        .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
               presenting: failure) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
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
                    if loadsInRunningEmulator(core) {
                        StateCard(state: state, canPlay: canLoad(state), playTitle: "Load State", play: { load(state) },
                                  rename: { beginRenaming(state) }, delete: { stateToDelete = state })
                    } else {
                        StateCard(state: state, canPlay: canPlay, play: { start(state) },
                                  rename: { beginRenaming(state) }, delete: { stateToDelete = state })
                    }
                }
            }
            if !core.history.isEmpty {
                DisclosureGroup {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: AppSpacing.m, alignment: .top)],
                              alignment: .leading, spacing: AppSpacing.m) {
                        ForEach(core.history) { state in
                            StateCard(state: state, canPlay: canPlay, play: { start(state) },
                                      restore: core.coreID.map { coreID in { restore(state, coreID: coreID) } },
                                      restoreBlockedBy: restoreBlocker(core),
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

    /// The game runs in its standalone emulator, which loads its slots on request.
    private var isRunningExternally: Bool {
        session.phase == .external && session.gameID == game.persistentModelID
    }

    /// The standalone emulator that may write into these states' slots right
    /// now, on a request from Ursprung or by its own hotkeys: a restore could
    /// then be overwritten without a copy in the history.
    private func restoreBlocker(_ core: SaveStateStore.CoreStates) -> StandaloneEmulator? {
        guard session.standaloneMayWriteStates(of: game.id), let standalone, core.coreID == standalone.id else { return nil }
        return standalone
    }

    private func loadsInRunningEmulator(_ core: SaveStateStore.CoreStates) -> Bool {
        isRunningExternally && core.coreID != nil && core.coreID == standalone?.id
    }

    /// The emulator loads states by slot, so the automatic state and copies wait until it quits.
    private func canLoad(_ state: SaveStateSlot) -> Bool {
        ARMSX2States.isSlotFile(state) && session.canUseExternalStates
    }

    private func load(_ state: SaveStateSlot) {
        dismiss()
        session.loadState(state)
    }

    /// The emulator a game of a standalone system runs in, which makes its states.
    private var standalone: StandaloneEmulator? {
        game.effectiveCore?.standalone
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
        guard let core = cores.first(where: { $0.coreID == coreID }), restoreBlocker(core) == nil else { return }
        do {
            try SaveStateStore.restore(state, toSlot: state.slot,
                                       in: SaveStateStore.directory(in: AppPaths.states, gameID: game.id, coreID: coreID))
        } catch {
            failure = Failure(title: "The save state couldn't be restored", message: error.localizedDescription)
        }
        reload()
    }
}

/// One state: thumbnail, name or slot, date and its actions.
private struct StateCard: View {
    let state: SaveStateSlot
    let canPlay: Bool
    var playTitle: LocalizedStringKey = "Play from Here"
    let play: () -> Void
    var rename: (() -> Void)?
    var restore: (() -> Void)?
    /// Restoring waits until this emulator has quit.
    var restoreBlockedBy: StandaloneEmulator?
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
                Button(playTitle, action: play)
                    .disabled(!canPlay)
                Spacer(minLength: 0)
                if let restore {
                    Button("Restore", systemImage: "arrow.uturn.backward", action: restore)
                        .disabled(restoreBlockedBy != nil)
                        .help(restoreHelp)
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
            Button(playTitle, action: play)
                .disabled(!canPlay)
            if let restore {
                Button(state.slot == 0 ? "Restore as Quick Save" : "Restore to Slot \(state.slot)", action: restore)
                    .disabled(restoreBlockedBy != nil)
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

    private var restoreHelp: Text {
        if let emulator = restoreBlockedBy { return Text("Quit \(emulator.name) to restore this state.") }
        return state.slot == 0 ? Text("Restore as Quick Save") : Text("Restore to Slot \(state.slot)")
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
