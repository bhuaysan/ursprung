// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct CoresSettingsView: View {
    @Environment(CoreManager.self) private var cores
    @State private var failure: DownloadFailure?
    @State private var coreToRemove: CoreDefinition?

    struct DownloadFailure {
        var core: CoreDefinition
        var message: String
    }

    var body: some View {
        Form {
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
                    CoreRow(core: core, install: install, remove: remove)
                }
            } header: {
                Text("libretro Cores")
            } footer: {
                Text("Cores are downloaded automatically from the libretro buildbot the first time you play a game. They are separate open source projects with their own licenses.")
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

private struct CoreRow: View {
    let core: CoreDefinition
    let install: (CoreDefinition) -> Void
    let remove: (CoreDefinition) -> Void
    @Environment(CoreManager.self) private var cores

    var body: some View {
        LabeledContent {
            HStack(spacing: AppSpacing.m) {
                if let progress = cores.downloads[core.id] {
                    ProgressView(value: progress)
                        .frame(width: 120)
                        .accessibilityLabel("Downloading")
                } else if cores.isInstalled(core) {
                    if let date = cores.installedDate(core) {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Menu {
                        Button("Update") { install(core) }
                        Button("Remove", role: .destructive) { remove(core) }
                    } label: {
                        HStack(spacing: AppSpacing.xs) {
                            StatusLabel("Installed", kind: .success)
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
}
