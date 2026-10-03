// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftData
import SwiftUI

/// Editing the playlist of an .m3u game, or creating one for loose discs.
enum DiscPlaylistRequest: Identifiable {
    case edit(Game)
    /// The discs in order.
    case create([Game])

    var id: PersistentIdentifier? {
        switch self {
        case .edit(let game): game.persistentModelID
        case .create(let games): games.first?.persistentModelID
        }
    }
}

/// Orders, labels, adds and removes the discs of a multi-disc game and
/// checks that none is missing. Discs that are games of their own in the
/// library join the playlist's game with their play time and saves.
struct DiscPlaylistEditor: View {
    let request: DiscPlaylistRequest
    /// The playlist's game once saved; nil when cancelled.
    let completion: (Game?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(LibraryStore.self) private var library
    @State private var rows: [DiscRow] = []
    @State private var fileName = ""
    @State private var error: String?
    @State private var hasLoaded = false

    private struct DiscRow: Identifiable, Equatable {
        let id = UUID()
        /// As the playlist names it.
        var path: String
        var label: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(isCreating ? "Create Disc Playlist" : "Edit Discs")
                    .font(.headline)
                Text(isCreating
                     ? "The discs become one game that changes discs from the pause menu. Ursprung writes an .m3u file next to them."
                     : "The order is the order of the discs in the pause menu. Labels help tell the discs apart.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, AppSpacing.m)

            if isCreating {
                HStack {
                    Text("File Name")
                        .foregroundStyle(.secondary)
                    TextField("File Name", text: $fileName)
                        .labelsHidden()
                    Text(verbatim: ".m3u")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, AppSpacing.m)
            }

            List {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rowView(index: index, row: row)
                }
                .onMove { rows.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds()
            .padding(.horizontal, 20)

            problems
                .padding(.horizontal, 20)
                .padding(.top, AppSpacing.s)

            HStack {
                Button("Add Disc…", systemImage: "plus", action: addDisc)
                if !isInDiscOrder {
                    Button("Sort by Disc Number", action: sortByDiscNumber)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    completion(nil)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(isCreating ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(rows.isEmpty || (isCreating && cleanFileName.isEmpty))
            }
            .padding(20)
        }
        .frame(width: 600, height: 480)
        .onAppear(perform: load)
        .alert("The playlist couldn't be saved", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func rowView(index: Int, row: DiscRow) -> some View {
        let exists = FileManager.default.fileExists(atPath: url(of: row).path(percentEncoded: false))
        return HStack(spacing: AppSpacing.m) {
            Text("Disc \(index + 1)")
                .font(.body.weight(.semibold))
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                TextField("Label", text: binding(for: row), prompt: Text("Label (optional)"))
                    .labelsHidden()
                HStack(spacing: AppSpacing.xs) {
                    if !exists {
                        StatusLabel("Missing", kind: .warning)
                    }
                    Text((row.path as NSString).lastPathComponent)
                        .monospaced()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.path)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Move Up", systemImage: "chevron.up") { move(row, by: -1) }
                .disabled(index == 0)
            Button("Move Down", systemImage: "chevron.down") { move(row, by: 1) }
                .disabled(index == rows.count - 1)
            Button("Remove", systemImage: "minus.circle") { rows.removeAll { $0.id == row.id } }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.vertical, AppSpacing.xxs)
    }

    /// Missing files and disc numbers, as one line each.
    @ViewBuilder
    private var problems: some View {
        let missingFiles = rows.filter { !FileManager.default.fileExists(atPath: url(of: $0).path(percentEncoded: false)) }
        let infos = rows.map { VariantInfo.parse(fileName: ($0.path as NSString).lastPathComponent) }
        let missingDiscs = DiscSets.missingDiscs(infos.compactMap(\.disc), declaredCount: infos.compactMap(\.discCount).max())
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            if !missingFiles.isEmpty {
                StatusLabel(missingFiles.count == 1 ? "A disc file is missing" : "\(missingFiles.count) disc files are missing",
                            kind: .warning, prominent: true,
                            detail: String(localized: "Put them next to the playlist, or remove them from it."))
            }
            if !missingDiscs.isEmpty {
                StatusLabel("Disc \(missingDiscs.map(String.init).formatted(.list(type: .and))) isn't in the playlist",
                            kind: .warning, prominent: true)
            }
            if missingFiles.isEmpty, missingDiscs.isEmpty, !rows.isEmpty {
                StatusLabel("All discs are there", systemImage: "checkmark.circle", kind: .neutral)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Data

    private var isCreating: Bool {
        if case .create = request { true } else { false }
    }

    /// The folder the playlist is (or will be) in.
    private var directory: URL {
        switch request {
        case .edit(let game): game.fileURL.deletingLastPathComponent()
        case .create(let games): games.first?.fileURL.deletingLastPathComponent() ?? URL(filePath: "/")
        }
    }

    private var cleanFileName: String {
        fileName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    private var isInDiscOrder: Bool {
        let numbers = rows.compactMap { VariantInfo.parse(fileName: ($0.path as NSString).lastPathComponent).disc }
        return numbers.count < 2 || numbers == numbers.sorted()
    }

    private func url(of row: DiscRow) -> URL {
        DiscPlaylist.resolve(row.path, in: directory)
    }

    private func binding(for row: DiscRow) -> Binding<String> {
        Binding {
            rows.first { $0.id == row.id }?.label ?? ""
        } set: { label in
            if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index].label = label }
        }
    }

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        switch request {
        case .edit(let game):
            let playlist = DiscPlaylist.read(game.fileURL) ?? DiscPlaylist()
            rows = playlist.entries.map { DiscRow(path: $0.path, label: $0.label ?? "") }
        case .create(let games):
            rows = games.map { DiscRow(path: DiscPlaylist.reference(to: $0.fileURL, from: directory), label: "") }
            fileName = games.first.flatMap { DiscSets.setName(of: $0.fileName) } ?? ""
        }
    }

    private func move(_ row: DiscRow, by offset: Int) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        let target = index + offset
        guard rows.indices.contains(target) else { return }
        rows.swapAt(index, target)
    }

    private func sortByDiscNumber() {
        rows.sort {
            let left = VariantInfo.parse(fileName: ($0.path as NSString).lastPathComponent).disc ?? .max
            let right = VariantInfo.parse(fileName: ($1.path as NSString).lastPathComponent).disc ?? .max
            return left < right
        }
    }

    private func addDisc() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = directory
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose disc images (.cue, .chd, .iso …). Discs next to the playlist are easiest to move along with it.")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = DiscPlaylist.reference(to: url, from: directory)
            if !rows.contains(where: { $0.path == path }) { rows.append(DiscRow(path: path, label: "")) }
        }
    }

    private func save() {
        let playlist = DiscPlaylist(entries: rows.map { DiscPlaylist.Entry(path: $0.path, label: $0.label.isEmpty ? nil : $0.label) })
        let target: URL
        let keeping: Game?
        switch request {
        case .edit(let game):
            target = game.fileURL
            keeping = game
        case .create:
            target = directory.appending(path: cleanFileName + ".m3u")
            keeping = nil
            if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                error = String(localized: "A file named “\(target.lastPathComponent)” already exists.")
                return
            }
        }
        do {
            try playlist.write(to: target)
            // Discs that were games of their own join the playlist's game.
            let paths = Set(rows.map { url(of: $0).standardizedFileURL.path(percentEncoded: false) })
            let library = (try? context.fetch(FetchDescriptor<Game>())) ?? []
            let discs = library.filter { paths.contains($0.path) } + (keeping.map { [$0] } ?? [])
            let game = try self.library.adoptPlaylist(target, discs: discs, keeping: keeping, context: context)
            completion(game)
            dismiss()
            Task { await self.library.rescan(context: context) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
