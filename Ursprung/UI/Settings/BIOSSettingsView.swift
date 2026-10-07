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
                Text("Drop BIOS files or a whole folder here. Ursprung recognizes them by checksum and renames them to what the cores expect; PlayStation 2 BIOS dumps are recognized by their content and keep their names. You must own the original hardware to use its BIOS.")
                    .settingsFootnote()
            }

            ForEach(SystemCatalog.all.filter { !$0.bios.isEmpty || $0.biosFolder != nil }) { system in
                Section(system.name) {
                    let coreID = system.core(withID: Preferences.coreChoice(for: system.id)).id
                    // Needed by the core the system uses; an alternative of
                    // the same group that is present makes a file optional.
                    let needed = Set(bios.missingRequired(for: system, coreID: coreID))
                    ForEach(system.bios) { file in
                        BIOSRow(file: file, status: bios.status(of: file), system: system, isNeeded: needed.contains(file))
                    }
                    if let folder = system.biosFolder {
                        BIOSFolderRows(folder: folder, dumps: bios.dumps(in: folder), system: system,
                                       isNeeded: bios.missingFolder(for: system, coreID: coreID) != nil)
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

/// The dumps found in a BIOS folder, or one row saying that none is there.
private struct BIOSFolderRows: View {
    let folder: BIOSFolder
    let dumps: [PS2BIOS]
    let system: GameSystem
    /// Empty, and the core the system uses cannot start without a dump.
    let isNeeded: Bool

    var body: some View {
        if dumps.isEmpty {
            LabeledContent {
                if isNeeded {
                    StatusLabel("Missing", kind: .error)
                } else {
                    StatusLabel("Missing", systemImage: "circle.dashed", kind: .neutral)
                }
            } label: {
                Text(verbatim: BIOSManager.description(of: folder).capitalizedSentence)
                Text(requirement)
            }
        } else {
            ForEach(dumps, id: \.fileName) { dump in
                LabeledContent {
                    StatusLabel("Recognized", systemImage: "checkmark.circle", kind: .success)
                } label: {
                    Text(verbatim: dump.fileName).monospaced()
                    Text(details(of: dump))
                }
            }
        }
    }

    private var requirement: String {
        let cores = system.cores.filter { folder.isRequired(forCore: $0.id) }.map(\.name)
        guard !cores.isEmpty else { return String(localized: "Optional") }
        return String(localized: "Required for \(cores.formatted(.list(type: .and)))")
    }

    /// "Europe · Version 2.00 · 14 Jun 2004"
    private func details(of dump: PS2BIOS) -> String {
        var parts = [regionName(dump.region), String(localized: "Version \(dump.version)")]
        if let date = dump.date {
            parts.append(date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)))
        }
        return parts.joined(separator: " · ")
    }

    private func regionName(_ region: PS2BIOS.Region) -> String {
        switch region {
        case .japan: String(localized: "Japan")
        case .usa: String(localized: "USA")
        case .europe: String(localized: "Europe")
        case .asia: String(localized: "Asia")
        case .china: String(localized: "China")
        case .other: String(localized: "Other Region")
        }
    }
}

private extension String {
    /// "a PlayStation 2 BIOS" → "A PlayStation 2 BIOS"
    var capitalizedSentence: String { prefix(1).uppercased() + dropFirst() }
}

private struct BIOSRow: View {
    let file: BIOSFile
    let status: BIOSManager.Status
    let system: GameSystem
    /// Missing, and the core the system uses cannot start without it.
    let isNeeded: Bool

    var body: some View {
        LabeledContent {
            statusLabel
        } label: {
            Text(file.fileName).monospaced()
            Text(file.note.map { String(localized: "\(requirement) · \($0)") } ?? requirement)
        }
    }

    private var requirement: String {
        if file.required { return String(localized: "Required") }
        let cores = system.cores.filter { file.requiredBy.contains($0.id) }.map(\.name)
        guard !cores.isEmpty else { return String(localized: "Optional") }
        return String(localized: "Required for \(cores.formatted(.list(type: .and)))")
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
            if isNeeded {
                StatusLabel("Missing", kind: .error)
            } else {
                StatusLabel("Missing", systemImage: "circle.dashed", kind: .neutral)
            }
        }
    }
}
