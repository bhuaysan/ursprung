// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftData
import SwiftUI

/// What the last scan found beyond the games it recognized: files it could
/// not identify (which the user can add with a system), games with missing
/// disc files, games whose file is missing, and what could not be read.
struct ScanReportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(LibraryStore.self) private var library
    @Query(sort: \Game.title) private var games: [Game]

    private var incomplete: [Game] { games.filter { !$0.missingTracks.isEmpty && !$0.isMissing } }
    private var missing: [Game] { games.filter(\.isMissing) }

    private var isClean: Bool {
        library.unrecognizedFiles.isEmpty && library.unreadableFiles.isEmpty && incomplete.isEmpty && missing.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Scan Report")
                    .font(.headline)
                if let summary = library.lastScanSummary {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()
            if isClean {
                ContentUnavailableView("Everything Was Recognized", systemImage: "checkmark.circle",
                                       description: Text("Every game in your library folders is ready to play."))
                    .frame(maxHeight: .infinity)
            } else {
                Form {
                    if !library.unrecognizedFiles.isEmpty { unrecognizedSection }
                    if !incomplete.isEmpty { incompleteSection }
                    if !missing.isEmpty { missingSection }
                    if !library.unreadableFiles.isEmpty { unreadableSection }
                }
                .formStyle(.grouped)
            }
            Divider()
            HStack {
                Button("Rescan") { Task { await library.rescan(context: context) } }
                    .disabled(library.isScanning)
                if library.isScanning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(AppSpacing.l)
        }
        .frame(width: 560)
        .frame(minHeight: 360, idealHeight: 560)
        .presentationSizing(.fitted)
    }

    private var unrecognizedSection: some View {
        Section {
            ForEach(library.unrecognizedFiles, id: \.self) { url in
                LabeledContent {
                    Menu("Add As") {
                        ForEach(systemsSortedByName) { system in
                            Button(system.name) { library.addUnrecognized(url, systemID: system.id, context: context) }
                        }
                    }
                    .fixedSize()
                } label: {
                    fileLabel(url)
                }
            }
        } header: {
            Text("Not Recognized")
        } footer: {
            Text("Ursprung couldn't tell which system these files belong to. Put them in a folder named after the system, or add them with Add As.")
                .settingsFootnote()
        }
    }

    private var incompleteSection: some View {
        Section {
            ForEach(incomplete) { game in
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.fileURL]) }
                } label: {
                    Text(game.title)
                    Text("Missing: \(game.missingTracks.joined(separator: ", "))")
                }
            }
        } header: {
            Text("Disc Files Missing")
        } footer: {
            Text("These games can't start until the files their .cue, .gdi or .m3u sheet lists are next to it.")
                .settingsFootnote()
        }
    }

    private var missingSection: some View {
        Section {
            ForEach(missing) { game in
                LabeledContent {
                    Button("Locate…") { library.presentLocatePanel(for: game, context: context) }
                } label: {
                    Text(game.title)
                    Text(game.fileURL.deletingLastPathComponent().path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } header: {
            Text("File Missing")
        }
    }

    private var unreadableSection: some View {
        Section {
            ForEach(library.unreadableFiles, id: \.self) { url in
                fileLabel(url)
            }
        } header: {
            Text("Couldn't Be Read")
        } footer: {
            Text("Check the permissions of these files and folders. Games inside them were kept.")
                .settingsFootnote()
        }
    }

    private func fileLabel(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text(url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(url.deletingLastPathComponent().path(percentEncoded: false))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(url.path(percentEncoded: false))
    }

    private var systemsSortedByName: [GameSystem] {
        SystemCatalog.all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
