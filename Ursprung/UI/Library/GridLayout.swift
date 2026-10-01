// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Columns of the game grid. See docs/DESIGN_SPEC.md, section E.
nonisolated struct GridLayout: Equatable {
    let columns: Int
    /// Width of every cover slot: the chosen step, unless two columns only fit smaller.
    let slotWidth: Double
    /// Space between columns; takes up the width the slots leave, so both grid
    /// edges stay aligned as in Finder's icon view.
    let spacing: Double

    /// Computed rather than `.adaptive`, so every step changes the cover size
    /// visibly and keyboard navigation knows the row length.
    init(availableWidth: Double, coverStep: Double, minSpacing: Double = AppMetrics.gridColumnSpacing) {
        let available = max(availableWidth, 0)
        // Two columns squeeze down to the smallest step before the grid drops to one.
        let smallest = min(AppMetrics.coverSteps.first ?? coverStep, coverStep)
        if available >= 2 * coverStep + minSpacing {
            columns = Int((available + minSpacing) / (coverStep + minSpacing))
            slotWidth = coverStep
            spacing = (available - Double(columns) * coverStep) / Double(columns - 1)
        } else if available >= 2 * smallest + minSpacing {
            columns = 2
            slotWidth = (available - minSpacing) / 2
            spacing = minSpacing
        } else {
            columns = 1
            slotWidth = min(coverStep, available)
            spacing = minSpacing
        }
    }
}

/// The discrete cover sizes stepped through with ⌘+ / ⌘− / ⌘0.
nonisolated enum CoverSize {
    static let steps = AppMetrics.coverSteps
    static let defaultStep = AppMetrics.defaultCoverStep

    /// The step nearest to a stored value; older versions stored any width from a slider.
    static func snapped(_ width: Double) -> Double {
        steps.min { abs($0 - width) < abs($1 - width) } ?? defaultStep
    }

    static func larger(than width: Double) -> Double? {
        steps.first { $0 > snapped(width) }
    }

    static func smaller(than width: Double) -> Double? {
        steps.last { $0 < snapped(width) }
    }
}

/// A keyboard move in the game grid.
nonisolated enum GridMove: Sendable {
    case left, right, up, down, home, end, pageUp, pageDown
}

/// Index math for moving the selection through a grid laid out row by row.
nonisolated enum GridNavigation {
    /// The index a move lands on, or `nil` when the grid is empty.
    /// - Parameters:
    ///   - index: The selected index, `nil` when nothing is selected.
    ///   - pageRows: Rows moved by Page Up / Page Down.
    ///   - entry: Selected by any move but Home and End when nothing is selected yet.
    static func target(of move: GridMove, from index: Int?, count: Int, columns: Int,
                       pageRows: Int = 1, entry: Int = 0) -> Int? {
        guard count > 0 else { return nil }
        let last = count - 1
        guard let index = index.map({ min(max($0, 0), last) }) else {
            switch move {
            case .home: return 0
            case .end: return last
            default: return min(max(entry, 0), last)
            }
        }
        let columns = max(columns, 1)
        let column = index % columns
        switch move {
        case .left: return max(index - 1, 0)
        case .right: return min(index + 1, last)
        case .home: return 0
        case .end: return last
        case .up, .pageUp:
            let target = index - columns * rows(for: move, pageRows: pageRows)
            // Past the top: the same column in the first row.
            return target >= 0 ? target : column
        case .down, .pageDown:
            let target = index + columns * rows(for: move, pageRows: pageRows)
            if target <= last { return target }
            // Past the bottom: the same column in the last row, or the last
            // game when that row is too short.
            return min(last / columns * columns + column, last)
        }
    }

    private static func rows(for move: GridMove, pageRows: Int) -> Int {
        move == .pageUp || move == .pageDown ? max(pageRows, 1) : 1
    }
}

/// Finder-style type-select: letters typed in quick succession form a prefix
/// that jumps to the first matching title.
nonisolated struct TypeSelect {
    static let timeout: TimeInterval = 1

    private(set) var buffer = ""
    private var lastInput = Date.distantPast

    /// Adds typed characters and returns the prefix to search for. A space
    /// only continues a prefix; on its own it returns `nil`.
    mutating func append(_ characters: String, at date: Date = .now) -> String? {
        if date.timeIntervalSince(lastInput) > Self.timeout { buffer = "" }
        guard !buffer.isEmpty || !characters.allSatisfy(\.isWhitespace) else { return nil }
        buffer += characters
        lastInput = date
        return buffer
    }

    /// The index of the first title that starts with `prefix`, ignoring case and diacritics.
    static func firstMatch(for prefix: String, in titles: some Sequence<String>) -> Int? {
        titles.enumerated().first { _, title in
            title.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
        }?.offset
    }
}
