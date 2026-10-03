// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftData
import SwiftUI

/// Searches ScreenScraper by title and lets the user choose which game a
/// library entry is. Details the user edited stay as they are.
struct MatchPicker: View {
    let game: Game

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(MetadataService.self) private var metadata
    @State private var query: String
    @State private var results: [ScrapedGame] = []
    @State private var selection: String?
    @State private var phase = Phase.idle
    /// The latest search; an earlier one that answers late is ignored.
    @State private var searchID = 0

    private enum Phase: Equatable {
        case idle, searching, done
        case failed(String)
    }

    init(game: Game) {
        self.game = game
        // A title the user typed may not be ScreenScraper's; the file name is a better start then.
        _query = State(initialValue: game.isLocked(.title) ? TitleFormatter.title(fromFileName: game.fileName) : game.title)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                Text("Choose the Right Game")
                    .font(.headline)
                Text("Search ScreenScraper for \(game.system?.name ?? game.systemID) games, then choose the one “\(game.fileName)” contains.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("Title", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(search)
                    Button("Search", action: search)
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || phase == .searching)
                }
            }
            .padding(20)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use This Game") {
                    if let match = results.first(where: { $0.screenScraperID == selection }) {
                        metadata.apply(match, to: game, context: context)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
            .padding(AppSpacing.l)
        }
        .frame(width: 520, height: 480)
        .task { search() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            ProgressView()
        case .searching where results.isEmpty:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView {
                Label("Search Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .done where results.isEmpty:
            // ScreenScraper matches titles word for word: fewer words find more.
            ContentUnavailableView("No Games Found", systemImage: "magnifyingglass",
                                   description: Text("Try fewer words, for example only the first word of the title."))
        default:
            List(results, id: \.screenScraperID, selection: $selection) { result in
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(result.title ?? String(localized: "Untitled"))
                        .font(.body.weight(.medium))
                    Text(verbatim: [result.releaseDate.map { String($0.prefix(4)) }, result.developer ?? result.publisher, result.genre]
                        .compactMap { $0 }
                        .joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let overview = result.overview {
                        Text(overview)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, AppSpacing.xxs)
                .tag(result.screenScraperID)
            }
        }
    }

    private func search() {
        let title = query.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, let system = game.system else { return }
        phase = .searching
        searchID += 1
        let id = searchID
        Task {
            do {
                let found = try await metadata.search(title, systemID: system.screenScraperID)
                guard id == searchID else { return }
                results = found
                selection = found.first { $0.screenScraperID == game.screenScraperID }?.screenScraperID ?? found.first?.screenScraperID
                phase = .done
            } catch {
                guard id == searchID else { return }
                results = []
                phase = .failed(MetadataFailure(error).message)
            }
        }
    }
}
