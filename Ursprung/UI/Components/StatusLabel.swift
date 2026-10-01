// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// What a status means. Colour only reinforces it: every status is a symbol plus a word.
nonisolated enum StatusKind {
    case success, warning, error, neutral

    var defaultSymbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .neutral: "circle"
        }
    }

    var color: Color {
        switch self {
        case .success: .green
        case .warning: .orange
        case .error: .red
        case .neutral: .secondary
        }
    }
}

/// Symbol in a semantic colour plus a word (docs/DESIGN_SPEC.md, sections K and N).
/// Inline status trails its row with a secondary word; a warning or error row
/// (`prominent`) leads its section with primary text.
struct StatusLabel: View {
    private let title: Text
    private let symbol: String
    private let kind: StatusKind
    private let prominent: Bool
    private let detail: String?

    /// `detail` adds a secondary line below the title, e.g. the reason for an error.
    init(_ title: LocalizedStringKey, systemImage: String? = nil, kind: StatusKind, prominent: Bool = false,
         detail: String? = nil) {
        self.init(Text(title), systemImage: systemImage, kind: kind, prominent: prominent, detail: detail)
    }

    init(verbatim title: String, systemImage: String? = nil, kind: StatusKind, prominent: Bool = false,
         detail: String? = nil) {
        self.init(Text(verbatim: title), systemImage: systemImage, kind: kind, prominent: prominent, detail: detail)
    }

    init(_ title: Text, systemImage: String? = nil, kind: StatusKind, prominent: Bool = false, detail: String? = nil) {
        self.title = title
        self.symbol = systemImage ?? kind.defaultSymbol
        self.kind = kind
        self.prominent = prominent
        self.detail = detail
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                title.foregroundStyle(prominent ? .primary : .secondary)
                if let detail {
                    Text(verbatim: detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(kind.color)
        }
    }
}

extension View {
    /// Section footers in Settings: the grouped form does not style them.
    func settingsFootnote() -> some View {
        font(.subheadline).foregroundStyle(.secondary)
    }
}
