// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Spacing on a 4 pt grid. See docs/DESIGN_SPEC.md, section Q.
nonisolated enum AppSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Sizes shared by more than one view. Values used in a single place stay there.
nonisolated enum AppMetrics {
    static let sidebarWidth = (min: 200.0, ideal: 220.0, max: 280.0)
    static let inspectorWidth = (min: 280.0, ideal: 320.0, max: 400.0)
    /// The grid never gets narrower than this; the inspector or sidebar yields first.
    static let contentMinWidth: CGFloat = 440
    /// Below this content width the grid uses compact padding and the system header shrinks.
    static let compactContentWidth: CGFloat = 560

    /// Cover slot widths the user steps through with ⌘+ / ⌘−.
    static let coverSteps: [Double] = [120, 150, 180, 220, 260]
    static let defaultCoverStep: Double = 180

    static let gridColumnSpacing: CGFloat = 20
    static let gridRowSpacing: CGFloat = 28
    static let gridPadding: CGFloat = 24
    static let compactGridPadding: CGFloat = 20

    static let artworkRadius: CGFloat = 8
    static let smallArtworkRadius: CGFloat = 6
    static let selectionRingWidth: CGFloat = 3
    static let highContrastSelectionRingWidth: CGFloat = 4
    static let selectionRingGap: CGFloat = 3
    static let coverPlayButton: CGFloat = 32

    static let systemHeaderHeight: CGFloat = 88
    static let compactSystemHeaderHeight: CGFloat = 72

    static let pausePanelRadius: CGFloat = 24
    static let playerPanelRadius: CGFloat = 20
    static let rowHighlightRadius: CGFloat = 8
}

extension ShapeStyle where Self == Color {
    /// The favorite heart. The accent: a heart glyph and the selection ring
    /// never need to be told apart by colour.
    static var favorite: Color { .accentColor }
}

/// Restrained, bounce-free animations. Call sites go through `appAnimation`,
/// `withAppAnimation` and `appFade` so Reduce Motion is handled in one place.
nonisolated enum AppAnimation {
    /// Hover feedback and row highlights.
    static let quick = Animation.easeOut(duration: 0.12)
    /// Toasts, HUD indicators, inline status.
    static let standard = Animation.smooth(duration: 0.20)
    /// Pause menu and player panels.
    static let panel = Animation.smooth(duration: 0.25)
    /// Replacement for all of the above when Reduce Motion is on; pair it
    /// with opacity-only transitions (`appFade`).
    static let reduced = Animation.easeOut(duration: 0.15)
}

extension View {
    /// `animation(_:value:)` that falls back to `AppAnimation.reduced` when Reduce Motion is on.
    func appAnimation(_ animation: Animation, value: some Equatable) -> some View {
        modifier(AppAnimationModifier(animation: animation, value: value))
    }
}

private struct AppAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? AppAnimation.reduced : animation, value: value)
    }
}

/// `withAnimation` that falls back to `AppAnimation.reduced` when Reduce Motion is on.
func withAppAnimation<Result>(_ animation: Animation, reduceMotion: Bool,
                              _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(reduceMotion ? AppAnimation.reduced : animation, body)
}

extension AnyTransition {
    /// `transition` normally, a plain fade when Reduce Motion is on.
    static func appFade(or transition: AnyTransition, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : transition
    }
}
