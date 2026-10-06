// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// One open `.slang` or include file: a TextKit 2 text view with slang
/// colours, line numbers with error marks, find and replace, and an undo
/// history of its own. Kept alive while its tab is open, so switching tabs
/// keeps the scroll position and undo.
final class SourceDocument: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    let tabID: ShaderEditor.SourceTab.ID
    let scrollView: NSScrollView
    let textView: NSTextView
    /// Called with the whole text after every change by the user.
    var onChange: ((String) -> Void)?

    /// Error messages by line (1-based), drawn in the gutter and as line backgrounds.
    var diagnostics: [Int: String] = [:] {
        didSet {
            guard diagnostics != oldValue else { return }
            applyDiagnostics()
            ruler.needsDisplay = true
        }
    }

    private let ruler: LineNumberRuler
    private let undo = UndoManager()
    /// UTF-16 offsets where lines start.
    fileprivate private(set) var lineStarts: [Int] = [0]
    private var isLoading = false

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    init(tabID: ShaderEditor.SourceTab.ID, url: URL) {
        self.tabID = tabID
        textView = NSTextView(usingTextLayoutManager: true)
        scrollView = NSScrollView()
        ruler = LineNumberRuler(scrollView: scrollView, orientation: .verticalRuler)
        super.init()

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.documentView = textView

        // Code doesn't wrap: lines scroll sideways.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 4, height: 6)

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = Self.font
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.textColor]
        textView.setAccessibilityLabel(url.lastPathComponent)
        textView.delegate = self
        textView.textStorage?.delegate = self

        ruler.clientView = textView
        ruler.document = self
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        load(url)
    }

    /// Replaces the text with the file's, without an undo step.
    func load(_ url: URL) {
        let data = (try? Data(contentsOf: url)) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        isLoading = true
        textView.string = text
        isLoading = false
        undo.removeAllActions()
        updateLineStarts()
        highlight(NSRange(location: 0, length: (text as NSString).length), whole: true)
        ruler.needsDisplay = true
    }

    @objc private func scrolled() {
        ruler.needsDisplay = true
    }

    /// Moves the cursor to the start of `line` and shows it.
    func reveal(line: Int) {
        let text = textView.string as NSString
        let index = min(max(line - 1, 0), lineStarts.count - 1)
        let range = text.lineRange(for: NSRange(location: min(lineStarts[index], text.length), length: 0))
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        textView.scrollRangeToVisible(range)
        if range.length > 0 { textView.showFindIndicator(for: range) }
    }

    // MARK: Delegates

    func undoManager(for view: NSTextView) -> UndoManager? {
        undo
    }

    func textDidChange(_ notification: Notification) {
        guard !isLoading else { return }
        onChange?(textView.string)
    }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            updateLineStarts()
            highlight(editedRange, whole: false)
            ruler.needsDisplay = true
        }
    }

    // MARK: Colours

    private static func color(for kind: SlangTokenizer.Kind) -> NSColor {
        switch kind {
        case .comment: .secondaryLabelColor
        case .keyword: .systemPink
        case .type: .systemPurple
        case .builtin: .systemTeal
        case .number: .systemBlue
        case .directive: .systemOrange
        case .pragma: .systemBrown
        case .string: .systemRed
        }
    }

    /// Colours the paragraphs around `edited`; to the end of the text when
    /// a block comment may have opened or closed there.
    private func highlight(_ edited: NSRange, whole: Bool) {
        guard let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        var range = whole ? NSRange(location: 0, length: text.length)
            : text.paragraphRange(for: NSRange(location: min(edited.location, text.length),
                                               length: min(edited.length, text.length - min(edited.location, text.length))))
        let tokens = SlangTokenizer.tokens(in: storage.string)
        if !whole {
            let paragraph = text.substring(with: range)
            let crossesComment = tokens.contains { token in
                token.kind == .comment && NSIntersectionRange(token.range, range).length > 0
                    && NSMaxRange(token.range) > NSMaxRange(range)
            }
            if paragraph.contains("/*") || paragraph.contains("*/") || crossesComment {
                range = NSRange(location: range.location, length: text.length - range.location)
            }
        }
        guard range.length > 0 else { return }
        storage.beginEditing()
        storage.addAttributes([.foregroundColor: NSColor.textColor, .font: Self.font], range: range)
        for token in tokens {
            let overlap = NSIntersectionRange(token.range, range)
            if overlap.length > 0 { storage.addAttribute(.foregroundColor, value: Self.color(for: token.kind), range: overlap) }
        }
        storage.endEditing()
    }

    private func updateLineStarts() {
        let units = textView.string.utf16
        var starts = [0]
        starts.reserveCapacity(starts.count)
        var offset = 0
        for unit in units {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        lineStarts = starts
    }

    /// The 1-based line of a UTF-16 offset.
    fileprivate func line(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }

    private func applyDiagnostics() {
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager else { return }
        layout.removeRenderingAttribute(.backgroundColor, for: content.documentRange)
        let text = textView.string as NSString
        for line in diagnostics.keys where line >= 1 && line <= lineStarts.count {
            let lineRange = text.lineRange(for: NSRange(location: min(lineStarts[line - 1], text.length), length: 0))
            guard let start = content.location(content.documentRange.location, offsetBy: lineRange.location),
                  let end = content.location(start, offsetBy: lineRange.length),
                  let range = NSTextRange(location: start, end: end) else { continue }
            layout.addRenderingAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.15), for: range)
        }
    }
}

/// Line numbers next to the source, with a red mark on lines that have errors.
private final class LineNumberRuler: NSRulerView {
    weak var document: SourceDocument?

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = 44
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let document, let textView = clientView as? NSTextView, let layout = textView.textLayoutManager,
              let content = layout.textContentManager else { return }
        // Views don't clip their drawing by default: stay inside the ruler.
        let area = rect.intersection(bounds)
        NSColor.textBackgroundColor.setFill()
        area.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: area.minY, width: 1, height: area.height).fill()

        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let visible = textView.visibleRect
        let start = layout.textViewportLayoutController.viewportRange?.location ?? content.documentRange.location
        layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY > visible.maxY { return false }
            guard frame.maxY >= visible.minY else { return true }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let line = document.line(at: offset)
            let lineHeight = fragment.textLineFragments.first?.typographicBounds.height ?? frame.height
            let y = convert(NSPoint(x: 0, y: frame.minY + textView.textContainerInset.height), from: textView).y
            let hasError = document.diagnostics[line] != nil
            if hasError {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 4, y: y + (lineHeight - 7) / 2, width: 7, height: 7)).fill()
            }
            let label = NSAttributedString(string: "\(line)", attributes: [
                .font: font,
                .foregroundColor: hasError ? NSColor.systemRed : NSColor.tertiaryLabelColor,
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: bounds.maxX - 6 - size.width, y: y + (lineHeight - size.height) / 2))
            return true
        }
    }
}

/// Shows a document's scroll view; switching tabs swaps the document.
struct SourceEditorView: NSViewRepresentable {
    let document: SourceDocument

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.clipsToBounds = true
        embed(document, in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard container.subviews.first !== document.scrollView else { return }
        embed(document, in: container)
    }

    private func embed(_ document: SourceDocument, in container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let scrollView = document.scrollView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// The open documents, by tab.
@Observable
final class SourceDocuments {
    @ObservationIgnored private var documents: [ShaderEditor.SourceTab.ID: SourceDocument] = [:]

    func document(for tab: ShaderEditor.SourceTab, editor: ShaderEditor) -> SourceDocument {
        if let document = documents[tab.id] { return document }
        let document = SourceDocument(tabID: tab.id, url: tab.url)
        document.onChange = { [weak editor] text in
            editor?.sourceChanged(tab.id, text: text)
        }
        documents[tab.id] = document
        return document
    }

    /// Drops documents whose tabs closed; reloads all when the draft was replaced.
    func keep(_ tabs: [ShaderEditor.SourceTab]) {
        let open = Set(tabs.map(\.id))
        documents = documents.filter { open.contains($0.key) }
    }

    func existing(_ id: ShaderEditor.SourceTab.ID) -> SourceDocument? {
        documents[id]
    }
}
