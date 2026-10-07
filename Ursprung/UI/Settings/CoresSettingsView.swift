// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct CoresSettingsView: View {
    @Environment(CoreManager.self) private var cores
    @Environment(EmulationSession.self) private var session
    @State private var failure: DownloadFailure?
    @State private var coreToRemove: CoreDefinition?
    @State private var updateCheckFailure: String?

    struct DownloadFailure {
        var core: CoreDefinition
        var message: String
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
                    updateStatus
                    Spacer(minLength: AppSpacing.s)
                    if cores.isCheckingForUpdates { ProgressView().controlSize(.small) }
                    if !cores.updatesAvailable.isEmpty {
                        Button("Update All") {
                            for core in CoreManager.allCores where cores.updatesAvailable.contains(core.id) { install(core) }
                        }
                        .disabled(session.isActive)
                    }
                    Button("Check for Updates", action: checkForUpdates)
                        .disabled(cores.isCheckingForUpdates)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("The buildbot builds cores every night. A newer build can fix games, and occasionally break save states; Ursprung warns when a state comes from another core version.")
                    .settingsFootnote()
            }
            Section {
                if let failure {
                    HStack(alignment: .firstTextBaseline) {
                        StatusLabel("“\(failure.core.name)” couldn't be downloaded.", kind: .error,
                                    prominent: true, detail: failure.message)
                        Spacer(minLength: AppSpacing.s)
                        Button("Retry") { install(failure.core) }
                            .buttonStyle(.link)
                    }
                }
                ForEach(CoreManager.allCores) { core in
                    CoreRow(core: core, install: install, remove: remove, restorePrevious: restorePrevious,
                            isInUse: session.isActive && session.coreName == core.name)
                }
            } header: {
                Text("libretro Cores")
            } footer: {
                Text("Cores are downloaded automatically from the libretro buildbot the first time you play a game. They are separate open source projects with their own licenses. After an update, the version before stays available: if a game no longer works, go back to it.")
                    .settingsFootnote()
            }
            Section {
                ForEach(CoreManager.standaloneEmulators) { emulator in
                    StandaloneEmulatorRow(emulator: emulator)
                }
            } header: {
                Text("Standalone Emulators")
            } footer: {
                Text("Standalone emulators run games in their own window, for systems no libretro core plays well on this Mac. They are separate open source projects with their own licenses.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            Text("Remove “\(coreToRemove?.name ?? "")”?"),
            isPresented: Binding(get: { coreToRemove != nil }, set: { if !$0 { coreToRemove = nil } }),
            presenting: coreToRemove
        ) { core in
            Button("Remove Core", role: .destructive) { cores.remove(core) }
            Button("Cancel", role: .cancel) {}
        } message: { core in
            Text("No other installed core plays \(uncoveredSystems(core).map(\.name).formatted(.list(type: .and))) games. The core downloads again the next time you play one.")
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        if let updateCheckFailure {
            StatusLabel("Couldn't check for updates", kind: .error, detail: updateCheckFailure)
        } else if let date = cores.lastUpdateCheck {
            if cores.updatesAvailable.isEmpty {
                StatusLabel("All installed cores are up to date", kind: .success,
                            detail: String(localized: "Checked \(date.formatted(date: .omitted, time: .shortened))"))
            } else {
                StatusLabel("Newer builds for \(cores.updatesAvailable.count) cores", systemImage: "arrow.down.circle.fill", kind: .neutral)
            }
        } else {
            Text("Not checked yet")
                .foregroundStyle(.secondary)
        }
    }

    private func checkForUpdates() {
        updateCheckFailure = nil
        Task {
            do {
                try await cores.checkForUpdates()
            } catch {
                updateCheckFailure = error.localizedDescription
            }
        }
    }

    private func restorePrevious(_ core: CoreDefinition) {
        do {
            try cores.restorePreviousVersion(core)
        } catch {
            failure = DownloadFailure(core: core, message: error.localizedDescription)
        }
    }

    private func install(_ core: CoreDefinition) {
        if failure?.core == core { failure = nil }
        Task {
            do {
                try await cores.install(core)
            } catch {
                failure = DownloadFailure(core: core, message: error.localizedDescription)
            }
        }
    }

    /// Asks first when the core is the only installed one for a system.
    private func remove(_ core: CoreDefinition) {
        if uncoveredSystems(core).isEmpty {
            cores.remove(core)
        } else {
            coreToRemove = core
        }
    }

    /// Systems that no other installed core plays.
    private func uncoveredSystems(_ core: CoreDefinition) -> [GameSystem] {
        SystemCatalog.all.filter { system in
            system.cores.contains(core) && !system.cores.contains { $0 != core && cores.isInstalled($0) }
        }
    }
}

/// Installing comes with phase 2 of docs/STANDALONE_PLAN.md.
private struct StandaloneEmulatorRow: View {
    let emulator: CoreDefinition

    var body: some View {
        LabeledContent {
            StatusLabel("Not Installed", systemImage: "circle.dashed", kind: .neutral)
        } label: {
            Text(emulator.name)
            Text(SystemCatalog.all.filter { $0.cores.contains(emulator) }.map(\.shortName).joined(separator: ", "))
                .lineLimit(1)
        }
    }
}

private struct CoreRow: View {
    let core: CoreDefinition
    let install: (CoreDefinition) -> Void
    let remove: (CoreDefinition) -> Void
    let restorePrevious: (CoreDefinition) -> Void
    /// The running game uses the core: its file can't be swapped now.
    let isInUse: Bool
    @Environment(CoreManager.self) private var cores

    var body: some View {
        LabeledContent {
            HStack(spacing: AppSpacing.m) {
                if let progress = cores.downloads[core.id] {
                    ProgressView(value: progress)
                        .frame(width: 120)
                        .accessibilityLabel("Downloading")
                } else if cores.isInstalled(core) {
                    Text(verbatim: installedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Menu {
                        Button("Update") { install(core) }
                            .disabled(isInUse)
                        if cores.hasPreviousVersion(core) {
                            Button(previousTitle) { restorePrevious(core) }
                                .disabled(isInUse)
                        }
                        Divider()
                        Button("Remove", role: .destructive) { remove(core) }
                            .disabled(isInUse)
                    } label: {
                        HStack(spacing: AppSpacing.xs) {
                            if cores.updatesAvailable.contains(core.id) {
                                StatusLabel("Update Available", systemImage: "arrow.down.circle.fill", kind: .neutral)
                            } else {
                                StatusLabel("Installed", kind: .success)
                            }
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    // A plain button keeps the green symbol; borderless renders the label monochrome.
                    .buttonStyle(.plain)
                    .fixedSize()
                } else {
                    Button("Download") { install(core) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(core.name)
                if core.experimental {
                    Text("Experimental")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.15), in: .capsule)
                        .foregroundStyle(.orange)
                }
            }
            Text(systems)
                .lineLimit(1)
        }
    }

    private var systems: String {
        SystemCatalog.all.filter { $0.cores.contains(core) }.map(\.shortName).joined(separator: ", ")
    }

    /// "1.17.0 · 3 Oct 2026": the version once known, and the install date.
    private var installedDescription: String {
        let record = cores.versions[core.id]?.current
        let date = record?.installed ?? cores.installedDate(core)
        return [record?.version, date?.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }.joined(separator: " · ")
    }

    private var previousTitle: String {
        let previous = cores.versions[core.id]?.previous
        if let version = previous?.version {
            return String(localized: "Go Back to Version \(version)")
        }
        if let date = previous?.installed {
            return String(localized: "Go Back to Version from \(date.formatted(date: .abbreviated, time: .omitted))")
        }
        return String(localized: "Go Back to Previous Version")
    }
}
