// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// One row of background work in the activity footer.
nonisolated enum Activity: Hashable, Identifiable {
    case scan
    case metadata(completed: Int, total: Int, currentTitle: String?)
    case systemMedia
    case error(String)

    static let maxRows = 3

    var id: String {
        switch self {
        case .scan: "scan"
        case .metadata: "metadata"
        case .systemMedia: "systemMedia"
        case .error: "error"
        }
    }

    /// The rows to show, at most `maxRows`, in a fixed order: scan, metadata,
    /// system media, last error.
    static func rows(isScanning: Bool, metadata: (completed: Int, total: Int, currentTitle: String?)?,
                     isFetchingSystemMedia: Bool, error: String?) -> [Activity] {
        var rows: [Activity] = []
        if isScanning { rows.append(.scan) }
        if let metadata { rows.append(.metadata(completed: metadata.completed, total: metadata.total,
                                                currentTitle: metadata.currentTitle)) }
        if isFetchingSystemMedia { rows.append(.systemMedia) }
        if let error { rows.append(.error(error)) }
        return Array(rows.prefix(maxRows))
    }
}

extension Activity {
    /// Whether anything runs or failed. Reads only flags, so hosts do not
    /// re-render on every progress step.
    static func isPending(library: LibraryStore, metadata: MetadataService, systemMedia: SystemMediaStore) -> Bool {
        library.isScanning || metadata.isRunning || systemMedia.isFetching || metadata.lastError != nil
    }

    /// Whether anything still runs, as opposed to only an error being left.
    static func isRunning(library: LibraryStore, metadata: MetadataService, systemMedia: SystemMediaStore) -> Bool {
        library.isScanning || metadata.isRunning || systemMedia.isFetching
    }
}

/// Library scan, metadata and system media progress plus the last error.
/// Lives in the sidebar footer, and in a toolbar popover while the sidebar is
/// collapsed. See docs/DESIGN_SPEC.md, section C.
struct ActivityStatusView: View {
    /// Retries what failed: fetching missing metadata.
    let retry: () -> Void

    @Environment(LibraryStore.self) private var library
    @Environment(MetadataService.self) private var metadata
    @Environment(SystemMediaStore.self) private var systemMedia

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            ForEach(rows) { row($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rows: [Activity] {
        Activity.rows(isScanning: library.isScanning,
                      metadata: metadata.isRunning ? (metadata.completed, metadata.total, metadata.currentTitle) : nil,
                      isFetchingSystemMedia: systemMedia.isFetching,
                      error: metadata.lastError)
    }

    @ViewBuilder
    private func row(_ activity: Activity) -> some View {
        switch activity {
        case .scan:
            progressRow(title: "Scanning library…", detail: nil, progress: nil)
        case .metadata(let completed, let total, let currentTitle):
            progressRow(title: "Fetching metadata",
                        detail: String(localized: "\(min(completed + 1, total)) of \(total)"),
                        progress: total > 0 ? Double(completed) / Double(total) : nil,
                        stop: metadata.cancel)
                .help(currentTitle ?? "")
        case .systemMedia:
            progressRow(title: "Fetching system artwork", detail: nil, progress: nil)
        case .error(let message):
            errorRow(message)
        }
    }

    private func progressRow(title: LocalizedStringKey, detail: String?, progress: Double?,
                             stop: (() -> Void)? = nil) -> some View {
        HStack(alignment: .center, spacing: AppSpacing.s) {
            Group {
                if let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.circular)
            .controlSize(.small)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .lineLimit(1)
                if let detail {
                    Text(verbatim: detail)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .font(.subheadline)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityValue(detail ?? "")

            Spacer(minLength: 0)
            if let stop {
                RowButton(title: "Stop", systemImage: "xmark.circle.fill", action: stop)
            }
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 16, height: 16)
                .accessibilityLabel("Warning")
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(message)
                    .lineLimit(2)
                    .help(message)
                Button("Retry", action: retry)
                    .buttonStyle(.link)
            }
            .font(.subheadline)
            Spacer(minLength: 0)
            RowButton(title: "Dismiss", systemImage: "xmark.circle.fill") { metadata.lastError = nil }
        }
    }
}

/// The 16 pt trailing stop / dismiss button of an activity row.
private struct RowButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                // The visible glyph stays small; the pointer target is 24 pt.
                .padding(4)
                .contentShape(.rect)
                .padding(-4)
        }
        .buttonStyle(.plain)
        .help(Text(title))
    }
}

/// The toolbar's activity button: shown while the sidebar, and with it the
/// activity footer, is collapsed.
struct ActivityToolbarButton: View {
    let retry: () -> Void

    @Environment(LibraryStore.self) private var library
    @Environment(MetadataService.self) private var metadata
    @Environment(SystemMediaStore.self) private var systemMedia
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label {
                Text("Activity")
            } icon: {
                if Activity.isRunning(library: library, metadata: metadata, systemMedia: systemMedia) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                }
            }
        }
        .help("Activity")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ActivityStatusView(retry: retry)
                .padding(.horizontal, AppSpacing.m)
                .padding(.vertical, 10)
                .frame(width: 280)
        }
    }
}
