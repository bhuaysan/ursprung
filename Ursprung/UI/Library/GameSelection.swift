// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The selected games in the library, Finder-style: a click selects one,
/// ⌘-click adds or removes one, ⇧-click and ⇧-arrows select a range from the
/// anchor. `focus` is the game the keyboard moves from.
nonisolated struct GameSelection<ID: Hashable>: Equatable {
    private(set) var ids: Set<ID> = []
    /// Where ⇧-ranges start.
    private(set) var anchor: ID?
    /// The game arrows move from; the last one clicked or reached.
    private(set) var focus: ID?

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }

    /// The only selected game, if exactly one is selected.
    var single: ID? { ids.count == 1 ? ids.first : nil }

    func contains(_ id: ID) -> Bool { ids.contains(id) }

    enum Modifier { case none, toggle, extend }

    /// A click on `id`, among the games in their visible `order`.
    mutating func click(_ id: ID, modifier: Modifier, order: [ID]) {
        switch modifier {
        case .none:
            select(id)
        case .toggle:
            if ids.contains(id) {
                ids.remove(id)
                focus = ids.isEmpty ? nil : id
                anchor = ids.isEmpty ? nil : anchor
            } else {
                ids.insert(id)
                anchor = id
                focus = id
            }
        case .extend:
            extend(to: id, order: order)
        }
    }

    /// Selects only `id`.
    mutating func select(_ id: ID?) {
        ids = id.map { [$0] } ?? []
        anchor = id
        focus = id
    }

    /// Selects the range from the anchor to `id`, replacing the earlier range.
    mutating func extend(to id: ID, order: [ID]) {
        guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
            return select(id)
        }
        ids = Set(order[min(from, to)...max(from, to)])
        focus = id
    }

    /// Takes a selection made elsewhere (the list view). The focus moves to
    /// a newly added game, or stays when it is still selected.
    mutating func replace(with newIDs: Set<ID>, order: [ID]) {
        let added = newIDs.subtracting(ids)
        ids = newIDs
        if let newFocus = order.first(where: added.contains) {
            focus = newFocus
            if newIDs.count == 1 { anchor = newFocus }
        } else if let focus, !newIDs.contains(focus) {
            self.focus = order.first(where: newIDs.contains)
        }
        if let anchor, !newIDs.contains(anchor) { self.anchor = focus }
        if newIDs.isEmpty { anchor = nil; focus = nil }
    }

    mutating func selectAll(_ order: [ID]) {
        ids = Set(order)
        if focus == nil || !ids.contains(focus!) { focus = order.first }
        if anchor == nil || !ids.contains(anchor!) { anchor = focus }
    }

    /// Drops games that are no longer shown.
    mutating func keep(only visible: Set<ID>) {
        guard !ids.isSubset(of: visible) else { return }
        ids.formIntersection(visible)
        if let focus, !ids.contains(focus) { self.focus = ids.first }
        if let anchor, !ids.contains(anchor) { self.anchor = focus }
    }
}
