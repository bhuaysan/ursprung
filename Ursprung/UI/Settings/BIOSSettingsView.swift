// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BIOSSettingsView: View {
    @Environment(BIOSManager.self) private var bios
    @State private var importMessage: String?
    @State private var isTargeted = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Import BIOS Files…", action: presentImportPanel)
                    Button("Open System Folder") { NSWorkspace.shared.open(AppPaths.system) }
                    Spacer()
                    if bios.isRefreshing { ProgressView().controlSize(.small) }
                }
                if let importMessage {
                    Text(importMessage).font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Drop BIOS files or a whole folder here. Ursprung recognises them by checksum and renames them to what the cores expect. You must own the original hardware to use its BIOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(SystemCatalog.all.filter { !$0.bios.isEmpty }) { system in
                Section(system.name) {
                    ForEach(system.bios) { file in
                        BIOSRow(file: file, status: bios.status(of: file))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            importFiles(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .task { await bios.refresh() }
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    private func importFiles(_ urls: [URL]) {
        Task {
            let result = await bios.importFiles(urls)
            var parts: [String] = []
            if !result.imported.isEmpty { parts.append(String(localized: "Imported: \(result.imported.joined(separator: ", "))")) }
            if !result.unknown.isEmpty { parts.append(String(localized: "Not recognised: \(result.unknown.joined(separator: ", "))")) }
            importMessage = parts.isEmpty ? String(localized: "No files imported.") : parts.joined(separator: "\n")
        }
    }
}

private struct BIOSRow: View {
    let file: BIOSFile
    let status: BIOSManager.Status

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName).monospaced()
                HStack(spacing: 4) {
                    Text(file.required ? String(localized: "Required") : String(localized: "Optional"))
                    if let note = file.note {
                        Text("·")
                        Text(note)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            statusLabel
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .verified:
            Label("Verified", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .present:
            Label("Present", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .mismatch:
            Label("Unknown Version", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .help("The checksum does not match the known good dump. It may still work.")
        case .missing:
            Label("Missing", systemImage: file.required ? "xmark.circle.fill" : "circle.dashed")
                .foregroundStyle(file.required ? .red : .secondary)
        }
    }
}
