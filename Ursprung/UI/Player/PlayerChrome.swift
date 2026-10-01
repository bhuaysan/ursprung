// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Dark glass capsule for transient player status: toasts, FPS and Fast
/// Forward. Never hit-testable, so it cannot take clicks or focus from the game.
struct HUDCapsule<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.callout.weight(.medium))
            .imageScale(.small)
            .padding(.horizontal, AppSpacing.m)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
    }
}

/// Dark glass container for the centred player panels (preparing, failure).
struct PlayerPanel<Content: View>: View {
    var padding: CGFloat = AppSpacing.xl
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .glassEffect(.regular, in: .rect(cornerRadius: AppMetrics.playerPanelRadius))
            .environment(\.colorScheme, .dark)
    }
}

/// Hairline between groups in the dark player panels.
struct PanelDivider: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.2))
            .frame(height: 1 / displayScale)
            .accessibilityHidden(true)
    }
}
