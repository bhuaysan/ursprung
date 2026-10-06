// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Finds a RetroArch preset in the downloaded pack or the user's folder:
/// categories, favourites and search. Presets and folders dropped on it are
/// imported into the user's folder.
struct ShaderBrowser: View {
    /// The preset in use; selected when the browser opens.
    let current: ShaderPresetRef?
    /// The default button, e.g. "Add Passes" in the shader editor.
    var actionTitle: LocalizedStringKey = "Use Shader"
    let choose: (ShaderPresetRef) -> Void

    @Environment(ShaderLibrary.self) private var shaders
    @Environment(\.dismiss) private var dismiss
    @State private var category: Category = .all
    @State private var search = ""
    @State private var selection: ShaderPresetRef?
    @State private var isDropTargeted = false
    @State private var importReport: ImportReport?
    @State private var downloadFailure: String?

    enum Category: Hashable {
        case all, favorites, user
        case pack(String)
    }

    struct ImportReport: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 180)
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 700, height: 540)
        .onAppear {
            selection = current
            if let current {
                category = current.source == .user ? .user : .pack(ShaderPresetInfo(ref: current).category)
            }
            shaders.refresh()
        }
        .alert(item: $importReport) { report in
            Alert(title: Text(report.title), message: Text(report.message))
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .center, spacing: AppSpacing.m) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text("RetroArch Shaders")
                    .font(.headline)
                Text("Choose a preset for the picture. Drop presets or folders here to add them to your shaders.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AppSpacing.m)
            SearchField(text: $search)
                .frame(width: 200)
        }
        .padding(20)
    }

    private var sidebar: some View {
        List(selection: $category) {
            Section {
                Label("All Presets", systemImage: "square.grid.2x2").tag(Category.all)
                Label("Favorites", systemImage: "star").tag(Category.favorites)
                Label("My Shaders", systemImage: "folder").tag(Category.user)
            }
            if !packCategories.isEmpty {
                Section("Categories") {
                    ForEach(packCategories, id: \.self) { name in
                        Text(ShaderIndex.title(ofCategory: name)).tag(Category.pack(name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if !shaders.isPackInstalled, category != .user, category != .favorites {
                packBanner
                Divider()
            }
            if !shaders.hasIndex {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                presetList
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            importItems(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var presetList: some View {
        ScrollViewReader { proxy in
            List(filtered, selection: $selection) { info in
                ShaderPresetRow(info: info, showsCategory: showsCategory)
            }
            // Each category starts at the top.
            .id(category)
            .contextMenu(forSelectionType: ShaderPresetRef.self) { selected in
                if let preset = selected.first {
                    Button(shaders.isFavorite(preset) ? "Remove from Favorites" : "Add to Favorites") {
                        shaders.toggleFavorite(preset)
                    }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([shaders.url(of: preset)])
                    }
                }
            } primaryAction: { selected in
                if let preset = selected.first { use(preset) }
            }
            .task {
                // Scrolling while the list is still being filled crashes SwiftUI's outline view.
                await shaders.waitForIndex()
                try? await Task.sleep(for: .milliseconds(100))
                if let current, filtered.contains(where: { $0.ref == current }) {
                    proxy.scrollTo(current, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            switch category {
            case .favorites:
                ContentUnavailableView("No Favorites", systemImage: "star",
                                       description: Text("Mark presets with the star. Favorites also appear in the Filter menus."))
            case .user:
                ContentUnavailableView("No Shaders of Your Own", systemImage: "folder",
                                       description: Text("Import presets or drop them here. They are kept in your shader folder and are part of backups."))
            case .all, .pack:
                if shaders.isPackInstalled {
                    ContentUnavailableView("No Presets", systemImage: "camera.filters")
                } else {
                    ContentUnavailableView("No Presets Yet", systemImage: "camera.filters",
                                           description: Text("Download the shader pack to choose from more than 2,500 presets."))
                }
            }
        }
    }

    private var packBanner: some View {
        HStack(spacing: AppSpacing.m) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text("The RetroArch shader pack isn't downloaded.")
                if let downloadFailure {
                    StatusLabel("The shaders couldn't be downloaded", kind: .error, detail: downloadFailure)
                } else {
                    Text("About 55 MB from the libretro buildbot.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: AppSpacing.m)
            ShaderPackProgress()
            if !shaders.isInstallingPack {
                Button("Download", action: download)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, AppSpacing.m)
    }

    private var footer: some View {
        HStack(spacing: AppSpacing.s) {
            Button("Import…", action: presentImportPanel)
            if category == .user {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([shaders.makeUserDirectory()])
                }
            }
            Spacer(minLength: AppSpacing.m)
            if shaders.isIndexing {
                ProgressView().controlSize(.small)
            }
            Text(countDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(actionTitle) {
                if let selection { use(selection) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selection == nil)
        }
        .padding(20)
    }

    // MARK: Data

    private var packCategories: [String] {
        Set(shaders.presets.filter { $0.ref.source == .library }.map(\.category))
            .sorted { lhs, rhs in
                // "Other" (presets at the top of the pack) comes last.
                if lhs.isEmpty != rhs.isEmpty { return rhs.isEmpty }
                return ShaderIndex.title(ofCategory: lhs).localizedStandardCompare(ShaderIndex.title(ofCategory: rhs)) == .orderedAscending
            }
    }

    private var filtered: [ShaderPresetInfo] {
        let presets: [ShaderPresetInfo] = switch category {
        case .all: shaders.presets
        case .favorites: shaders.favorites.compactMap { favorite in shaders.presets.first { $0.ref == favorite } }
        case .user: shaders.presets.filter { $0.ref.source == .user }
        case .pack(let name): shaders.presets.filter { $0.ref.source == .library && $0.category == name }
        }
        let search = search.trimmingCharacters(in: .whitespaces)
        return search.isEmpty ? presets : presets.filter { $0.matches(search) }
    }

    /// A single category lists its folders only.
    private var showsCategory: Bool {
        if case .pack = category { false } else { true }
    }

    private var countDescription: String {
        let count = filtered.count
        return String(localized: "\(count) presets")
    }

    // MARK: Actions

    private func use(_ preset: ShaderPresetRef) {
        choose(preset)
        dismiss()
    }

    private func download() {
        downloadFailure = nil
        Task {
            do {
                try await shaders.installPack()
            } catch {
                downloadFailure = error.localizedDescription
            }
        }
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "slangp") ?? .data, .folder]
        panel.message = String(localized: "Choose shader presets (.slangp) or folders with presets.")
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK else { return }
        importItems(panel.urls)
    }

    private func importItems(_ urls: [URL]) {
        Task {
            let result = await shaders.importItems(urls)
            await shaders.waitForIndex()
            if let first = result.presets.first {
                category = .user
                search = ""
                selection = first
            }
            if !result.failures.isEmpty {
                let lines = result.failures.map { "\($0.name): \($0.reason)" }
                importReport = ImportReport(title: String(localized: "Some items couldn't be imported"),
                                            message: lines.joined(separator: "\n"))
            } else if !result.missing.isEmpty {
                let files = result.missing.count
                importReport = ImportReport(title: String(localized: "Some files are missing"),
                                            message: String(localized: "The imported presets refer to \(files) files that weren't found. These presets may not load."))
            }
        }
    }
}

/// One preset: name, where it is, passes and the favourite star.
private struct ShaderPresetRow: View {
    let info: ShaderPresetInfo
    let showsCategory: Bool
    @Environment(ShaderLibrary.self) private var shaders

    /// Presets this long may be too slow for some Macs in full screen.
    private static let heavyPassCount = 20

    var body: some View {
        let isFavorite = shaders.isFavorite(info.ref)
        HStack(spacing: AppSpacing.s) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(info.name)
                    .lineLimit(1)
                // Always two lines: rows of one height let the list scroll to the current preset.
                HStack(spacing: AppSpacing.xs) {
                    if let passes = info.passes {
                        let label = Text("\(passes) passes")
                            .monospacedDigit()
                        if passes >= Self.heavyPassCount {
                            label
                                .foregroundStyle(.orange)
                                .help("Many passes need a fast graphics processor, especially in full screen.")
                        } else {
                            label
                        }
                    }
                    if !subtitle.isEmpty {
                        if info.passes != nil { Text(verbatim: "·") }
                        Text(subtitle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if info.passes == nil && subtitle.isEmpty { Text(verbatim: " ") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: AppSpacing.s)
            if let problem = info.problem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(String(localized: "This preset can't be loaded: \(problem)"))
                    .accessibilityLabel("Can't Be Loaded")
            }
            Button {
                shaders.toggleFavorite(info.ref)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .padding(.vertical, AppSpacing.xxs)
    }

    private var subtitle: String {
        var parts: [String] = []
        if showsCategory {
            parts.append(info.ref.source == .user ? String(localized: "My Shaders") : ShaderIndex.title(ofCategory: info.category))
        }
        if !info.folder.isEmpty { parts.append(info.folder) }
        return parts.joined(separator: " › ")
    }
}

/// Download or unpack progress of the shader pack; nothing when idle.
struct ShaderPackProgress: View {
    @Environment(ShaderLibrary.self) private var shaders

    var body: some View {
        if let progress = shaders.downloadProgress {
            ProgressView(value: progress)
                .frame(width: 120)
                .accessibilityLabel("Downloading")
        } else if shaders.isUnpacking {
            HStack(spacing: AppSpacing.xs) {
                ProgressView().controlSize(.small)
                Text("Unpacking…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A search field for sheets, which have no toolbar for `.searchable`.
private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $text)
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
        .background(.quaternary.opacity(0.6), in: .capsule)
    }
}
