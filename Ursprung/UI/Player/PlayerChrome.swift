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

/// A text field drawn like a search field; `.searchable` only exists for toolbars.
struct FilterField: View {
    @Binding var text: String
    var prompt: LocalizedStringKey = "Filter Options"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AppSpacing.s)
        .padding(.vertical, 5)
        .background(.white.opacity(0.08), in: .capsule)
    }
}

/// The content as tall as it is, or in a scroll view when it is taller than
/// the height it is offered, so short pages keep the panel small and long
/// ones scroll inside it. Decided in one layout pass: a measured height
/// started each new page at zero and made the panel jump while it animated.
struct FittingScrollView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
                .scrollBounceBehavior(.basedOnSize)
        }
    }
}
