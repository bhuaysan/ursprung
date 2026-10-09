// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftData
import SwiftUI

/// Offers the folder structure for games and BIOS files (`FolderStructure`):
/// on the first launch and from the File menu.
struct FolderStructureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(LibraryStore.self) private var library
    @Environment(BIOSManager.self) private var bios

    @State private var root = FolderStructure.defaultRoot
    @State private var isCreating = false
    @State private var failure: String?

    /// Systems named in the ROMs row; the rest are counted.
    private static let exampleSystems = ["snes", "psx", "gba"]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AppSpacing.l) {
                HStack(alignment: .top, spacing: AppSpacing.m) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 32))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("Set Up Folders for Your Games?")
                            .font(.headline)
                        Text("Ursprung can create a folder for every system it supports. Copy your games into them, and Ursprung finds them by itself.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: AppSpacing.m) {
                    FolderRow(name: FolderStructure.rootName, systemImage: "folder.fill",
                              detail: Text(verbatim: (root.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath))
                    VStack(alignment: .leading, spacing: AppSpacing.m) {
                        FolderRow(name: FolderStructure.romsName, systemImage: "folder.fill", detail: romsDetail)
                        FolderRow(name: FolderStructure.biosName, systemImage: "folder.fill",
                                  detail: Text("BIOS files under any name. Ursprung recognizes them and imports them by itself."))
                        FolderRow(name: FolderStructure.readMeName, systemImage: "doc.text",
                                  detail: Text("What goes where."))
                    }
                    .padding(.leading, AppSpacing.xl)
                }
                .padding(AppSpacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: AppMetrics.rowHighlightRadius))

                HStack(spacing: AppSpacing.s) {
                    Text("Folders that already exist and the files in them stay as they are.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Change Location…", action: chooseLocation)
                        .disabled(isCreating)
                }

                if let failure {
                    StatusLabel(verbatim: failure, kind: .error)
                }
            }
            .padding(20)
            Divider()
            HStack {
                if isCreating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Folders", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating)
            }
            .padding(AppSpacing.l)
        }
        .frame(width: 520)
    }

    private var romsDetail: Text {
        let names = Self.exampleSystems.compactMap { SystemCatalog.system(withID: $0)?.folderName }
            .formatted(.list(type: .and))
        return Text("One folder for each of the \(SystemCatalog.all.count) systems, such as \(names).")
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose where the “Ursprung” folder is created, for example on an external drive.")
        panel.directoryURL = root.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // A chosen folder of that name is the structure itself.
        root = url.lastPathComponent == FolderStructure.rootName
            ? url : url.appending(path: FolderStructure.rootName, directoryHint: .isDirectory)
        failure = nil
    }

    private func create() {
        isCreating = true
        failure = nil
        Task {
            defer { isCreating = false }
            do {
                try await library.createFolderStructure(at: root, context: context)
                bios.watch(FolderStructure.bios(in: root))
                NSWorkspace.shared.open(root)
                dismiss()
            } catch {
                failure = String(localized: "The folders couldn't be created. \(error.localizedDescription)")
            }
        }
    }
}

/// A folder of the structure with what it is for.
private struct FolderRow: View {
    let name: String
    let systemImage: String
    let detail: Text

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(verbatim: name)
                    .fontWeight(.medium)
                detail
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
    }
}
