// SPDX-License-Identifier: GPL-3.0-or-later

import PDFKit
import QuickLookUI
import SwiftData
import SwiftUI

/// A game's manual in a window of its own, next to the game. PDFs open in a
/// PDF view with page thumbnails; other files in Quick Look.
struct ManualView: View {
    let gameID: UUID?

    @Query private var games: [Game]

    init(gameID: UUID?) {
        self.gameID = gameID
        let id = gameID ?? UUID()
        _games = Query(filter: #Predicate<Game> { $0.id == id })
    }

    var body: some View {
        Group {
            if let gameID, let manual = ManualStore.manual(in: AppPaths.extras, gameID: gameID) {
                if manual.pathExtension.lowercased() == "pdf" {
                    PDFManualView(url: manual)
                } else {
                    QuickLookManualView(url: manual)
                }
            } else {
                ContentUnavailableView("No Manual", systemImage: "book.closed",
                                       description: Text("Add a manual in the game's info panel."))
            }
        }
        .navigationTitle(games.first.map { String(localized: "Manual: \($0.title)") } ?? String(localized: "Manual"))
    }
}

private struct PDFManualView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

private struct QuickLookManualView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
}
