// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Edits a game's title, system, details and cover. A changed field is locked,
/// so fetching metadata again keeps the user's value. Edits a draft that Save
/// writes and Cancel discards.
struct GameInfoEditor: View {
    let game: Game

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(MetadataService.self) private var metadata
    @Environment(LibraryStore.self) private var library
    @State private var draft: Draft
    @State private var newCover: URL?
    @State private var restoresScrapedCover = false

    /// The editable values; `system` is nil for automatic detection.
    private struct Draft: Equatable {
        var title: String
        var system: String?
        var developer: String
        var publisher: String
        var genre: String
        var releaseDate: String
        var players: String
        var overview: String

        init(_ game: Game) {
            title = game.title
            system = game.systemOverride
            developer = game.developer ?? ""
            publisher = game.publisher ?? ""
            genre = game.genre ?? ""
            releaseDate = game.releaseDate ?? ""
            players = game.players ?? ""
            overview = game.overview ?? ""
        }
    }

    init(game: Game) {
        self.game = game
        _draft = State(initialValue: Draft(game))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Title", text: $draft.title)
                    Picker("System", selection: $draft.system) {
                        Text("Detect Automatically").tag(String?.none)
                        Divider()
                        ForEach(SystemCatalog.all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { system in
                            Text(system.name).tag(Optional(system.id))
                        }
                    }
                } footer: {
                    if draft.system != game.systemOverride {
                        Text("Metadata is fetched again for the new system.")
                            .settingsFootnote()
                    }
                }
                Section("Details") {
                    TextField("Developer", text: $draft.developer)
                    TextField("Publisher", text: $draft.publisher)
                    TextField("Genre", text: $draft.genre)
                    TextField("Released", text: $draft.releaseDate, prompt: Text(verbatim: "1994-03-11"))
                    TextField("Players", text: $draft.players)
                }
                Section("Description") {
                    TextEditor(text: $draft.overview)
                        .font(.body)
                        .frame(minHeight: 90)
                        .accessibilityLabel("Description")
                }
                Section("Cover") {
                    coverRow
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 500)
        .frame(minHeight: 420, idealHeight: 640)
        .presentationSizing(.fitted)
    }

    private var coverRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.l) {
            ArtworkImage(url: coverPreviewURL, maxPixel: 240) {
                PlaceholderCover(title: draft.title, system: game.system)
                    .aspectRatio(game.system?.boxAspect ?? 0.72, contentMode: .fit)
            }
            .artworkFrame(radius: AppMetrics.smallArtworkRadius)
            .frame(maxWidth: 72, maxHeight: 96)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                Button("Choose Image…", action: chooseCover)
                if game.isLocked(.boxArt) || newCover != nil {
                    Button("Use ScreenScraper Cover") {
                        newCover = nil
                        restoresScrapedCover = true
                    }
                    .disabled(restoresScrapedCover && newCover == nil)
                }
                Text("PNG, JPEG or HEIC. Your cover is kept when metadata is fetched again.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var coverPreviewURL: URL? {
        if let newCover { return newCover }
        return restoresScrapedCover ? nil : game.boxArtURL
    }

    private var footer: some View {
        HStack {
            Button("Use ScreenScraper Data") {
                game.lockedFields = []
                if let custom = game.boxArtFile, custom.hasPrefix("custom-") {
                    try? FileManager.default.removeItem(at: game.mediaDirectory.appending(path: custom))
                    game.boxArtFile = nil
                }
                try? context.save()
                metadata.enqueue([game], force: true, context: context)
                dismiss()
            }
            .help("Forgets your changes and fetches everything from ScreenScraper again.")
            .disabled(game.lockedFields.isEmpty)
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                save()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(AppSpacing.l)
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .image]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        newCover = url
        restoresScrapedCover = false
    }

    private func save() {
        let original = Draft(game)
        var locked = game.lockedFields
        func update(_ field: GameField, _ value: String, _ previous: String, _ keyPath: ReferenceWritableKeyPath<Game, String?>) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != previous.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            game[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
            locked.insert(field)
        }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title != original.title {
            game.title = title
            locked.insert(.title)
        }
        update(.developer, draft.developer, original.developer, \.developer)
        update(.publisher, draft.publisher, original.publisher, \.publisher)
        update(.genre, draft.genre, original.genre, \.genre)
        update(.releaseDate, draft.releaseDate, original.releaseDate, \.releaseDate)
        update(.players, draft.players, original.players, \.players)
        update(.overview, draft.overview, original.overview, \.overview)

        if let newCover {
            let name = "custom-box." + (newCover.pathExtension.isEmpty ? "png" : newCover.pathExtension.lowercased())
            let destination = game.mediaDirectory.appending(path: name)
            do {
                try FileManager.default.createDirectory(at: game.mediaDirectory, withIntermediateDirectories: true)
                if let previous = game.boxArtFile, previous.hasPrefix("custom-") {
                    try? FileManager.default.removeItem(at: game.mediaDirectory.appending(path: previous))
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: newCover, to: destination)
                game.boxArtFile = name
                locked.insert(.boxArt)
            } catch {
                NSAlert(error: error).runModal()
            }
        } else if restoresScrapedCover {
            if let previous = game.boxArtFile, previous.hasPrefix("custom-") {
                try? FileManager.default.removeItem(at: game.mediaDirectory.appending(path: previous))
                game.boxArtFile = nil
            }
            locked.remove(.boxArt)
        }
        game.lockedFields = locked

        let systemChanged = draft.system != original.system
        if systemChanged {
            game.systemOverride = draft.system
            if let system = draft.system { library.changeSystem(of: game, to: system) }
            game.scrapeState = .pending
        }
        try? context.save()
        if systemChanged, draft.system == nil {
            // Back to automatic: a scan detects the system, then the game's
            // metadata is fetched for it.
            Task {
                await library.rescan(context: context)
                metadata.enqueue([game], force: true, context: context)
            }
        } else if systemChanged || restoresScrapedCover {
            metadata.enqueue([game], force: systemChanged, context: context)
        }
    }
}
