// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// One row of background work in the activity footer.
nonisolated enum Activity: Hashable, Identifiable {
    case scan
    case metadata(completed: Int, total: Int, currentTitle: String?)
    case systemMedia
    case error(MetadataFailure)
    /// Library folders the last scan could not reach, by volume name.
    case unreachable(volumes: [String])

    static let maxRows = 3

    var id: String {
        switch self {
        case .scan: "scan"
        case .metadata: "metadata"
        case .systemMedia: "systemMedia"
        case .error: "error"
        case .unreachable: "unreachable"
        }
    }

    /// The rows to show, at most `maxRows`, in a fixed order: scan, metadata,
    /// system media, last error, unreachable folders.
    static func rows(isScanning: Bool, metadata: (completed: Int, total: Int, currentTitle: String?)?,
                     isFetchingSystemMedia: Bool, error: MetadataFailure?,
                     unreachableFolders: [URL] = []) -> [Activity] {
        var rows: [Activity] = []
        if isScanning { rows.append(.scan) }
        if let metadata { rows.append(.metadata(completed: metadata.completed, total: metadata.total,
                                                currentTitle: metadata.currentTitle)) }
        if isFetchingSystemMedia { rows.append(.systemMedia) }
        if let error { rows.append(.error(error)) }
        if !unreachableFolders.isEmpty {
            var volumes: [String] = []
            for name in unreachableFolders.map(LibraryPaths.volumeName(of:)) where !volumes.contains(name) {
                volumes.append(name)
            }
            rows.append(.unreachable(volumes: volumes))
        }
        return Array(rows.prefix(maxRows))
    }
}

extension Activity {
    /// Whether anything runs or needs attention. Reads only flags, so hosts do
    /// not re-render on every progress step.
    static func isPending(library: LibraryStore, metadata: MetadataService, systemMedia: SystemMediaStore) -> Bool {
        library.isScanning || metadata.isRunning || systemMedia.isFetching || metadata.lastError != nil
            || !library.unreachableFolders.isEmpty
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
    @Environment(\.openSettings) private var openSettings
    @AppStorage(PrefKey.settingsTab) private var settingsTab = SettingsTab.general

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
                      error: metadata.lastError,
                      unreachableFolders: library.unreachableFolders)
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
        case .error(let failure):
            warningRow(symbol: "exclamationmark.triangle.fill", title: "Metadata couldn't be fetched",
                       detail: failure.reason, help: failure.message,
                       action: ("Retry", retry), dismiss: { metadata.lastError = nil })
        case .unreachable(let volumes):
            warningRow(symbol: "externaldrive.badge.exclamationmark", title: unreachableTitle(volumes),
                       detail: nil, help: volumes.formatted(.list(type: .and)),
                       action: ("Show in Settings", showLibraryFolders), dismiss: library.dismissUnreachableFolders)
        }
    }

    private func unreachableTitle(_ volumes: [String]) -> LocalizedStringKey {
        volumes.count == 1 ? "Games on “\(volumes[0])” are unavailable." : "Games in \(volumes.count) locations are unavailable."
    }

    private func showLibraryFolders() {
        settingsTab = .general
        openSettings()
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

    /// Something that needs attention: an orange symbol, what happened, the
    /// reason in one line, a link button and a dismiss button.
    private func warningRow(symbol: String, title: LocalizedStringKey, detail: String?, help: String,
                            action: (title: LocalizedStringKey, perform: () -> Void),
                            dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.s) {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit() // Badged symbols are wider than the 16 pt slot.
                .foregroundStyle(.orange)
                .frame(width: 16, height: 16)
                .accessibilityLabel("Warning")
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .lineLimit(2)
                        // Otherwise the one-line detail below takes the second line.
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(verbatim: detail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .help(help)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(title))
                .accessibilityValue(help)
                Button(action.title, action: action.perform)
                    .buttonStyle(.link)
            }
            .font(.subheadline)
            Spacer(minLength: 0)
            RowButton(title: "Dismiss", systemImage: "xmark.circle.fill", action: dismiss)
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
