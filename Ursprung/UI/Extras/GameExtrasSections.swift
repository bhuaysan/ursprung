// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Media

/// Artwork and screenshots of a game as thumbnails; a click opens the viewer.
struct MediaSection: View {
    let game: Game
    @Environment(EmulationSession.self) private var session
    @State private var viewing: MediaItem?

    var body: some View {
        let items = MediaItem.items(for: game, revision: session.screenshotRevision)
        if !items.isEmpty {
            InfoSection("Media") {
                ScrollView(.horizontal) {
                    HStack(spacing: AppSpacing.s) {
                        ForEach(items) { item in
                            Button { viewing = item } label: {
                                ArtworkImage(url: item.url, maxPixel: 240, contentMode: .fill) { Color.secondary.opacity(0.1) }
                                    .frame(width: 96, height: 72)
                                    .clipShape(.rect(cornerRadius: AppMetrics.smallArtworkRadius, style: .continuous))
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help(item.title)
                            .accessibilityLabel(Text(item.title))
                            // Drags the file itself, e.g. into the Finder or Mail.
                            .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
                            .contextMenu { MediaItemActions(item: item, onDelete: { delete(item) }) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                Text(summary(items))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .sheet(item: $viewing) { item in
                MediaViewer(items: items, current: item, onDelete: delete)
            }
        }
    }

    private func summary(_ items: [MediaItem]) -> String {
        let screenshots = items.filter(\.isScreenshot).count
        return screenshots == 0 ? String(localized: "Screenshots you take while playing appear here.")
            : String(localized: "\(screenshots) screenshots")
    }

    private func delete(_ item: MediaItem) {
        guard item.isScreenshot else { return }
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        if viewing == item { viewing = nil }
        session.noteScreenshotsChanged()
    }
}

/// One picture of a game: artwork or a screenshot the user took.
struct MediaItem: Identifiable, Hashable {
    let url: URL
    let title: String
    let isScreenshot: Bool
    var id: URL { url }

    static func items(for game: Game, revision: Int = 0) -> [MediaItem] {
        _ = revision
        let artwork: [(String?, String)] = [
            (game.boxArtFile, String(localized: "Box Art")),
            (game.titleScreenFile, String(localized: "Title Screen")),
            (game.screenshotFile, String(localized: "Screenshot")),
            (game.fanartFile, String(localized: "Fan Art")),
            (game.logoFile, String(localized: "Logo")),
        ]
        let scraped = artwork.compactMap { file, title in
            game.mediaURL(file).map { MediaItem(url: $0, title: title, isScreenshot: false) }
        }.filter { FileManager.default.fileExists(atPath: $0.url.path(percentEncoded: false)) }
        let screenshots = ScreenshotStore.screenshots(in: AppPaths.extras, gameID: game.id).map { url in
            MediaItem(url: url, title: Self.screenshotTitle(url), isScreenshot: true)
        }
        return screenshots + scraped
    }

    private static func screenshotTitle(_ url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
        return String(localized: "Screenshot from \(date.formatted(date: .abbreviated, time: .shortened))")
    }
}

/// Copy, Save As…, Show in Finder and (for screenshots) Delete.
private struct MediaItemActions: View {
    let item: MediaItem
    let onDelete: () -> Void

    var body: some View {
        Button("Copy", systemImage: "doc.on.doc") {
            guard let image = NSImage(contentsOf: item.url) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
        Button("Save As…", systemImage: "square.and.arrow.down") { MediaExport.save(item) }
        Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        if item.isScreenshot {
            Divider()
            Button("Move to Trash", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

enum MediaExport {
    /// Asks where to save a copy of the picture.
    static func save(_ item: MediaItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.url.lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: item.url.pathExtension) ?? .image]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: item.url, to: target)
    }
}

/// A picture large, with the others a click or arrow key away.
private struct MediaViewer: View {
    let items: [MediaItem]
    @State var current: MediaItem
    let onDelete: (MediaItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ArtworkImage(url: current.url, maxPixel: 2400, contentMode: .fit) { Color.clear }
                .frame(minWidth: 480, idealWidth: 800, maxWidth: .infinity, minHeight: 320, idealHeight: 560, maxHeight: .infinity)
                .padding(AppSpacing.l)
                .id(current.url)
            Divider()
            HStack(spacing: AppSpacing.s) {
                Button("Previous", systemImage: "chevron.left") { step(-1) }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(items.count < 2)
                Button("Next", systemImage: "chevron.right") { step(1) }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(items.count < 2)
                Text(current.title)
                    .lineLimit(1)
                Spacer(minLength: AppSpacing.m)
                Menu("Actions", systemImage: "ellipsis.circle") {
                    MediaItemActions(item: current, onDelete: { onDelete(current) })
                }
                .menuIndicator(.hidden)
                .fixedSize()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(AppSpacing.l)
        }
    }

    private func step(_ offset: Int) {
        guard let index = items.firstIndex(of: current), !items.isEmpty else { return }
        current = items[(index + offset + items.count) % items.count]
    }
}

// MARK: - Manual

/// Add, open, replace or remove the game's manual.
struct ManualSection: View {
    let game: Game
    @Environment(\.openWindow) private var openWindow
    @State private var isImporting = false
    @State private var failure: String?
    /// Bumped after changes: the manual lives on disk, not in the model.
    @State private var revision = 0

    var body: some View {
        let manual = { _ = revision; return ManualStore.manual(in: AppPaths.extras, gameID: game.id) }()
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            SymbolRow("Manual", symbol: "book.closed") {
                if let manual {
                    Button(manual.lastPathComponent) { openWindow(id: WindowID.manual, value: game.id) }
                        .buttonStyle(.link)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Open Manual")
                    Menu {
                        Button("Replace…") { isImporting = true }
                        Button("Remove") {
                            try? ManualStore.removeManual(in: AppPaths.extras, gameID: game.id)
                            revision += 1
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .accessibilityLabel("Manual Actions")
                } else {
                    Button("Add Manual…") { isImporting = true }
                        .buttonStyle(.link)
                        .help("Keep the game's manual here, as a PDF or picture. It opens next to the game, also from the game menu.")
                }
            }
            if let failure {
                StatusLabel("The manual couldn't be added", kind: .error, detail: failure)
                    .font(.callout)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.pdf, .image, .plainText, .html, .rtf]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                try ManualStore.setManual(url, in: AppPaths.extras, gameID: game.id)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            revision += 1
        }
    }
}

// MARK: - Patches

/// ROM patches: which one the game starts with, adding and removing them.
struct PatchesSection: View {
    let game: Game
    @Environment(EmulationSession.self) private var session
    @State private var isImporting = false
    @State private var failure: String?
    @State private var revision = 0

    var body: some View {
        let patches = { _ = revision; return PatchStore.patches(in: AppPaths.extras, gameID: game.id) }()
        let active = { _ = revision; return PatchStore.active(in: AppPaths.extras, gameID: game.id) }()
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            SymbolRow("Patches", symbol: "bandage") {
                if patches.isEmpty {
                    Button("Add Patch…") { isImporting = true }
                        .buttonStyle(.link)
                        .help("Translations, hacks and fixes as IPS, UPS or BPS files. The game file stays unchanged; a patched game keeps its own saves.")
                } else {
                    Picker("Play", selection: Binding(get: { active }, set: { setActive($0) })) {
                        Text("Original").tag(URL?.none)
                        Divider()
                        ForEach(patches, id: \.self) { patch in
                            Text(verbatim: patch.deletingPathExtension().lastPathComponent).tag(URL?.some(patch))
                        }
                    }
                    .modifier(InlineMenu())
                    .help("The version the game starts as")
                }
            }
            if !patches.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    ForEach(patches, id: \.self) { patch in
                        PatchRow(patch: patch, game: game, isActive: patch == active) {
                            try? PatchStore.remove(patch, in: AppPaths.extras, gameID: game.id)
                            revision += 1
                        }
                    }
                    if session.runningGameID == game.id {
                        Text("Changes apply the next time the game starts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Add Patch…") { isImporting = true }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                // Under the value, past the symbol column.
                .padding(.leading, 18 + AppSpacing.s)
            }
            if let failure {
                StatusLabel("The patch couldn't be added", kind: .error, detail: failure)
                    .font(.callout)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.patchTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            failure = nil
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let added = try PatchStore.add(url, in: AppPaths.extras, gameID: game.id)
                    if active == nil, urls.count == 1 { setActive(added) }
                } catch {
                    failure = error.localizedDescription
                }
            }
            revision += 1
        }
    }

    private static let patchTypes: [UTType] = ROMPatch.Format.fileExtensions.compactMap { UTType(filenameExtension: $0) } + [.data]

    private func setActive(_ patch: URL?) {
        try? PatchStore.setActive(patch, in: AppPaths.extras, gameID: game.id)
        revision += 1
    }
}

/// A patch file: its format, whether it fits the game, and Remove.
private struct PatchRow: View {
    let patch: URL
    let game: Game
    let isActive: Bool
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                // The menu above names the active patch; here it is only set apart.
                Text(verbatim: patch.deletingPathExtension().lastPathComponent)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(fits ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
            }
            Spacer(minLength: AppSpacing.s)
            Button("Remove", systemImage: "minus.circle", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove Patch")
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private var expectedCRC: UInt32? {
        (try? Data(contentsOf: patch)).flatMap(ROMPatch.expectedSourceCRC)
    }

    /// False when the patch names another ROM checksum than the game's.
    private var fits: Bool {
        guard let expected = expectedCRC, let crc = game.crc32 else { return true }
        return Checksum.hex(expected).caseInsensitiveCompare(crc) == .orderedSame
    }

    private var note: String? {
        let format = ROMPatch.Format(rawValue: patch.pathExtension.lowercased())?.title ?? ""
        if !fits { return String(localized: "\(format) · Made for another version of the game") }
        return expectedCRC != nil ? String(localized: "\(format) · Fits this game") : format
    }
}

// MARK: - Cheats

/// How many cheats a game has and how many are on; Edit… opens the editor.
struct CheatsSection: View {
    let game: Game
    @Environment(EmulationSession.self) private var session
    @State private var isEditing = false

    var body: some View {
        let cheats = session.runningGameID == game.id ? session.cheats : CheatStore.cheats(in: AppPaths.extras, gameID: game.id)
        SymbolRow("Cheats", symbol: "wand.and.stars") {
            if cheats.isEmpty {
                Button("Add Cheats…") { isEditing = true }
                    .buttonStyle(.link)
                    .help("Codes such as Game Genie or Action Replay, switched on and off while you play.")
            } else {
                Text("\(cheats.filter(\.isEnabled).count) of \(cheats.count) cheats on")
                Button("Edit…") { isEditing = true }
                    .buttonStyle(.link)
            }
        }
        .sheet(isPresented: $isEditing) {
            CheatsEditor(game: game)
        }
    }
}

/// The cheats of a game: switch, rename, add, delete and import (.cht).
struct CheatsEditor: View {
    let game: Game
    @Environment(EmulationSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var cheats: [Cheat] = []
    @State private var selection = Set<Cheat.ID>()
    @State private var isImporting = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            Text("Cheats for \(game.title)")
                .font(.headline)
            Table($cheats, selection: $selection) {
                TableColumn("On") { $cheat in
                    Toggle("On", isOn: $cheat.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                }
                .width(32)
                TableColumn("Name") { $cheat in
                    TextField("Name", text: $cheat.name)
                        .labelsHidden()
                }
                TableColumn("Code") { $cheat in
                    TextField("Code", text: $cheat.code)
                        .labelsHidden()
                        .monospaced()
                }
            }
            .frame(minHeight: 220)
            .onDeleteCommand(perform: deleteSelection)
            HStack(spacing: AppSpacing.s) {
                Button("Add", systemImage: "plus") {
                    let cheat = Cheat(name: String(localized: "New Cheat"), code: "", isEnabled: true)
                    cheats.append(cheat)
                    selection = [cheat.id]
                }
                Button("Delete", systemImage: "minus", action: deleteSelection)
                    .disabled(selection.isEmpty)
                Button("Import…") { isImporting = true }
                Spacer()
                if let failure {
                    StatusLabel("Import failed", kind: .error, detail: failure)
                }
            }
            .labelStyle(.titleAndIcon)
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppSpacing.xl)
        .frame(width: 620)
        .onAppear { cheats = CheatStore.cheats(in: AppPaths.extras, gameID: game.id) }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [UTType(filenameExtension: "cht") ?? .plainText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return failure = String(localized: "The file can't be read.")
            }
            let imported = CheatStore.parseCHT(text)
            if imported.isEmpty {
                failure = String(localized: "The file contains no cheats.")
            } else {
                failure = nil
                cheats += imported
            }
        }
    }

    private var note: String {
        var parts = [String(localized: "Codes are given to the core as they are; their format depends on the system, e.g. Game Genie or Action Replay. Several codes for one cheat are joined with “+”.")]
        if let core = game.effectiveCore {
            parts.append(String(localized: "Not every core supports cheats; \(core.name) is used for this game."))
        }
        return parts.joined(separator: " ")
    }

    private func deleteSelection() {
        cheats.removeAll { selection.contains($0.id) }
        selection = []
    }

    private func save() {
        let cleaned = cheats.filter { !$0.code.trimmingCharacters(in: .whitespaces).isEmpty }
        if session.runningGameID == game.id {
            session.setCheats(cleaned)
        } else {
            do {
                try CheatStore.save(cleaned, in: AppPaths.extras, gameID: game.id)
            } catch {
                return failure = error.localizedDescription
            }
        }
        dismiss()
    }
}
