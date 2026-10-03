// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BIOSSettingsView: View {
    @Environment(BIOSManager.self) private var bios
    @State private var importResult: BIOSManager.ImportResult?
    @State private var isTargeted = false

    var body: some View {
        Form {
            Section {
                if let importResult {
                    if importResult.imported.isEmpty && importResult.unknown.isEmpty && importResult.failed.isEmpty {
                        StatusLabel("No files imported.", kind: .neutral, prominent: true)
                    }
                    ForEach(importResult.imported, id: \.self) { name in
                        LabeledContent {
                            StatusLabel("Imported", kind: .success)
                        } label: {
                            Text(verbatim: name).monospaced()
                        }
                    }
                    ForEach(importResult.failed, id: \.self) { name in
                        LabeledContent {
                            StatusLabel("Couldn't Be Copied", kind: .error)
                        } label: {
                            Text(verbatim: name).monospaced()
                        }
                    }
                    // A dropped folder can hold many other files; they share one row.
                    if importResult.unknown.count > 3 {
                        LabeledContent {
                            notRecognized
                        } label: {
                            Text("\(importResult.unknown.count) other files")
                        }
                        .help(importResult.unknown.joined(separator: ", "))
                    } else {
                        ForEach(importResult.unknown, id: \.self) { name in
                            LabeledContent {
                                notRecognized
                            } label: {
                                Text(verbatim: name).monospaced()
                            }
                        }
                    }
                }
                HStack(spacing: AppSpacing.s) {
                    Spacer()
                    if bios.isRefreshing { ProgressView().controlSize(.small) }
                    Button("Open System Folder") { NSWorkspace.shared.open(AppPaths.system) }
                    Button("Import BIOS Files…", action: presentImportPanel)
                }
            } footer: {
                Text("Drop BIOS files or a whole folder here. Ursprung recognizes them by checksum and renames them to what the cores expect. You must own the original hardware to use its BIOS.")
                    .settingsFootnote()
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

    private var notRecognized: some View {
        StatusLabel("Not Recognized", systemImage: "questionmark.circle", kind: .neutral)
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
        Task { importResult = await bios.importFiles(urls) }
    }
}

private struct BIOSRow: View {
    let file: BIOSFile
    let status: BIOSManager.Status

    var body: some View {
        LabeledContent {
            statusLabel
        } label: {
            Text(file.fileName).monospaced()
            Text(file.note.map { String(localized: "\(requirement) · \($0)") } ?? requirement)
        }
    }

    private var requirement: String {
        file.required ? String(localized: "Required") : String(localized: "Optional")
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .verified:
            StatusLabel("Verified", systemImage: "checkmark.seal.fill", kind: .success)
        case .present:
            StatusLabel("Present", systemImage: "checkmark.circle", kind: .neutral)
        case .mismatch:
            StatusLabel("Unknown Version", kind: .warning)
                .help("The checksum does not match the known good dump. It may still work.")
        case .missing:
            if file.required {
                StatusLabel("Missing", kind: .error)
            } else {
                StatusLabel("Missing", systemImage: "circle.dashed", kind: .neutral)
            }
        }
    }
}
