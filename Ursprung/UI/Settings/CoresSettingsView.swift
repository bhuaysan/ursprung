// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct CoresSettingsView: View {
    @Environment(CoreManager.self) private var cores
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                ForEach(CoreManager.allCores) { core in
                    CoreRow(core: core, error: $error)
                }
            } header: {
                Text("libretro Cores")
            } footer: {
                Text("Cores are downloaded automatically from the libretro buildbot the first time you play a game. They are separate open source projects with their own licenses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Download Failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}

private struct CoreRow: View {
    let core: CoreDefinition
    @Binding var error: String?
    @Environment(CoreManager.self) private var cores

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(core.name)
                    if core.experimental {
                        Text("Experimental")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: .capsule)
                            .foregroundStyle(.orange)
                    }
                }
                Text(systems)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let progress = cores.downloads[core.id] {
                ProgressView(value: progress).frame(width: 90)
            } else if cores.isInstalled(core) {
                if let date = cores.installedDate(core) {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Menu {
                    Button("Update") { install() }
                    Button("Remove", role: .destructive) { cores.remove(core) }
                } label: {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
            } else {
                Button("Download", action: install)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var systems: String {
        SystemCatalog.all.filter { $0.cores.contains(core) }.map(\.shortName).joined(separator: ", ")
    }

    private func install() {
        Task {
            do {
                try await cores.install(core)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
