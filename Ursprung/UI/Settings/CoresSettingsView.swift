// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct CoresSettingsView: View {
    @Environment(CoreManager.self) private var cores
    @Environment(EmulatorManager.self) private var emulators
    @Environment(EmulationSession.self) private var session
    @State private var failure: DownloadFailure?
    @State private var coreToRemove: CoreDefinition?
    @State private var updateCheckFailure: String?
    @AppStorage(PrefKey.standaloneFullscreen) private var standaloneFullscreen = true

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
                if let failure, failure.core.isLibretro { failureRow(failure) }
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
                if let failure, !failure.core.isLibretro { failureRow(failure) }
                ForEach(CoreManager.standaloneEmulators) { emulator in
                    if let standalone = emulator.standalone {
                        StandaloneEmulatorRow(definition: emulator, emulator: standalone, install: install, remove: remove,
                                              isInUse: session.isActive && session.coreName == emulator.name
                                                  || session.standaloneSettingsID == standalone.id)
                        LabeledContent {
                            StandaloneSettingsButton(emulator: standalone, isShort: true)
                        } label: {
                            Text("\(standalone.name) Settings")
                            Text("Graphics, achievements and more, in \(standalone.name)'s own window. Ursprung sets its folders, BIOS, renderer, controls and hotkeys again before every game.")
                        }
                    }
                }
                Toggle("Play in full screen", isOn: $standaloneFullscreen)
            } header: {
                Text("Standalone Emulators")
            } footer: {
                Text("Standalone emulators run games in their own window, for systems no libretro core plays well on this Mac. They are separate open source projects with their own licenses. Ursprung downloads the release it was tested with and checks its signature; the version before an update stays available.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            Text("Remove “\(coreToRemove?.name ?? "")”?"),
            isPresented: Binding(get: { coreToRemove != nil }, set: { if !$0 { coreToRemove = nil } }),
            presenting: coreToRemove
        ) { core in
            if let emulator = core.standalone {
                Button("Remove Emulator", role: .destructive) { emulators.remove(emulator) }
            } else {
                Button("Remove Core", role: .destructive) { cores.remove(core) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { core in
            let systems = uncoveredSystems(core).map(\.name).formatted(.list(type: .and))
            if core.isLibretro {
                Text("No other installed core plays \(systems) games. The core downloads again the next time you play one.")
            } else {
                Text("\(core.name) is needed for \(systems) games. It downloads again the next time you play one; its settings are kept.")
            }
        }
    }

    private func failureRow(_ failure: DownloadFailure) -> some View {
        HStack(alignment: .firstTextBaseline) {
            StatusLabel("“\(failure.core.name)” couldn't be downloaded.", kind: .error,
                        prominent: true, detail: failure.message)
            Spacer(minLength: AppSpacing.s)
            Button("Retry") { install(failure.core) }
                .buttonStyle(.link)
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
                if let emulator = core.standalone {
                    try await emulators.install(emulator)
                } else {
                    try await cores.install(core)
                }
            } catch {
                failure = DownloadFailure(core: core, message: error.localizedDescription)
            }
        }
    }

    /// Asks first when the core is the only installed one for a system.
    private func remove(_ core: CoreDefinition) {
        if !uncoveredSystems(core).isEmpty {
            coreToRemove = core
        } else if let emulator = core.standalone {
            emulators.remove(emulator)
        } else {
            cores.remove(core)
        }
    }

    /// Systems that no other installed core plays.
    private func uncoveredSystems(_ core: CoreDefinition) -> [GameSystem] {
        SystemCatalog.all.filter { system in
            system.cores.contains(core) && !system.cores.contains { $0 != core && isInstalled($0) }
        }
    }

    private func isInstalled(_ core: CoreDefinition) -> Bool {
        if let emulator = core.standalone { emulators.isInstalled(emulator) } else { cores.isInstalled(core) }
    }
}

private struct StandaloneEmulatorRow: View {
    let definition: CoreDefinition
    let emulator: StandaloneEmulator
    let install: (CoreDefinition) -> Void
    let remove: (CoreDefinition) -> Void
    /// A game runs in the emulator: its app can't be swapped now.
    let isInUse: Bool
    @Environment(EmulatorManager.self) private var emulators
    @State private var size: Int64?

    var body: some View {
        LabeledContent {
            HStack(spacing: AppSpacing.m) {
                if let progress = emulators.downloads[emulator.id] {
                    ProgressView(value: progress)
                        .frame(width: 120)
                        .accessibilityLabel("Downloading")
                } else if emulators.isInstalled(emulator) {
                    Text(verbatim: installedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Menu {
                        if emulators.isUpdateAvailable(emulator) {
                            Button("Update to \(emulator.release.tag)") { install(definition) }
                                .disabled(isInUse)
                        }
                        if emulators.hasPreviousVersion(emulator), let previous = emulators.versions[emulator.id]?.previous {
                            Button("Go Back to \(previous.tag)") { emulators.restorePreviousVersion(emulator) }
                                .disabled(isInUse)
                        }
                        if let app = emulators.installedApp(for: emulator) {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app]) }
                        }
                        Link("Source Code", destination: emulator.sourceURL)
                        Divider()
                        Button("Remove", role: .destructive) { remove(definition) }
                            .disabled(isInUse)
                    } label: {
                        HStack(spacing: AppSpacing.xs) {
                            if emulators.isUpdateAvailable(emulator) {
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
                    Button("Download") { install(definition) }
                }
            }
        } label: {
            Text(emulator.name)
            Text(SystemCatalog.all.filter { $0.cores.contains(definition) }.map(\.shortName).joined(separator: ", "))
                .lineLimit(1)
        }
        .task(id: emulators.revision) {
            size = await emulators.installedSize(of: emulator)
        }
    }

    /// "nightly-20261006 · 46c06fe7ca · 320 MB": the active release and the
    /// space all kept versions take.
    private var installedDescription: String {
        let record = emulators.versions[emulator.id]?.current
        let bytes = size.flatMap { $0 > 0 ? $0.formatted(.byteCount(style: .file)) : nil }
        return [record?.tag, record?.commit, bytes].compactMap { $0 }.joined(separator: " · ")
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
