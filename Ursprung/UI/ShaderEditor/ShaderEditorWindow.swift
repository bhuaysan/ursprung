// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The shader editor: passes in the sidebar, the preview above the source
/// of the selected pass, and its options and parameters in the inspector.
/// Every change is kept in a draft; Save writes it to My Shaders.
struct ShaderEditorWindow: View {
    @Environment(ShaderEditor.self) private var editor
    @Environment(EmulationSession.self) private var session
    @Environment(ShaderLibrary.self) private var shaders

    @State private var documents = SourceDocuments()
    @State private var inspectorPage = ShaderEditorInspector.Page.pass
    @State private var showsInspector = true
    @State private var isNaming = false
    @State private var presetName = ""
    @State private var replacedName: String?
    @State private var failure: String?
    @State private var opensPreset = false
    @State private var confirmsRevert = false

    var body: some View {
        NavigationSplitView {
            PassList()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            // Not a VSplitView: its children's changing minimum sizes sent
            // AppKit into an endless constraint update loop.
            ResizableSplit {
                ShaderPreview()
            } bottom: {
                SourcePane(documents: documents)
            }
        }
        .inspector(isPresented: $showsInspector) {
            ShaderEditorInspector(page: $inspectorPage)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
        }
        .navigationTitle(editor.name)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .focusedSceneValue(\.shaderEditorSave, save)
        .onAppear {
            editor.isWindowOpen = true
            if editor.info == nil { editor.open(.lastDraft) }
        }
        .onDisappear { editor.isWindowOpen = false }
        .sheet(isPresented: $opensPreset) {
            ShaderBrowser(current: editor.info?.originPreset, actionTitle: "Open") { editor.open(.preset($0)) }
        }
        .alert("Save Shader", isPresented: $isNaming) {
            TextField("Name", text: $presetName)
            Button("Save") { save(as: presetName, replacing: false) }
                .disabled(ShaderPresetWriter.fileName(for: presetName) == nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the shader to My Shaders, where every Filter menu offers it.")
        }
        .confirmationDialog(Text("Replace “\(replacedName ?? "")”?"),
                            isPresented: Binding(get: { replacedName != nil }, set: { if !$0 { replacedName = nil } })) {
            Button("Replace", role: .destructive) { save(as: presetName, replacing: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("My Shaders already has a shader with this name.")
        }
        .confirmationDialog(Text("Discard your changes to “\(editor.name)”?"),
                            isPresented: Binding(get: { editor.pendingRequest != nil },
                                                 set: { if !$0 { editor.resolvePending(discard: false) } })) {
            Button("Discard Changes", role: .destructive) { editor.resolvePending(discard: true) }
            Button("Cancel", role: .cancel) { editor.resolvePending(discard: false) }
        } message: {
            Text("Another shader is being opened. Save first to keep your changes.")
        }
        .confirmationDialog(Text("Revert “\(editor.name)”?"), isPresented: $confirmsRevert) {
            Button("Revert", role: .destructive, action: editor.revert)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All changes since the shader was opened or saved are lost.")
        }
        .alert("The shader couldn’t be saved",
               isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: failure ?? "")
        }
    }

    private var subtitle: String {
        if editor.isModified { return String(localized: "Edited") }
        if let target = editor.target { return String(localized: "My Shaders › \(target.path)") }
        return String(localized: "Not Saved")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            CompileStatus()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Save", systemImage: "square.and.arrow.down", action: save)
                .disabled(!editor.isModified && editor.target != nil)
                .help("Save to My Shaders (⌘S)")
            Menu("Use For", systemImage: "checkmark.circle") {
                useForItems
            }
            .disabled(editor.target == nil || editor.isModified)
            .help(editor.target == nil || editor.isModified ? "Save the shader to use it" : "Choose where this shader is used")
            Menu("More", systemImage: "ellipsis.circle") {
                Button("New Shader") { editor.open(.newPreset) }
                Button("Open Shader…") { opensPreset = true }
                Divider()
                Button("Save As…") {
                    presetName = editor.name
                    isNaming = true
                }
                Button("Revert…") { confirmsRevert = true }
                    .disabled(!editor.isModified)
                Divider()
                Button("Show in Finder") {
                    if let url = editor.revealURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("Export as Folder…", action: exportFolder)
                Button("Export as Zip…", action: exportZip)
            }
            Button(showsInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing") {
                showsInspector.toggle()
            }
        }
    }

    @ViewBuilder
    private var useForItems: some View {
        if let target = editor.target {
            let gameID = editor.contextGameID ?? session.runningGameID
            let systemID = editor.contextSystemID ?? session.systemID
            if let gameID {
                Button("This Game") { use(target, for: .game(gameID)) }
            }
            if let systemID, let system = SystemCatalog.system(withID: systemID) {
                Button("All \(system.shortName) Games") { use(target, for: .system(systemID)) }
            }
            Button("All Systems") { use(target, for: .all) }
        }
    }

    private func use(_ target: ShaderPresetRef, for scope: ShaderScope) {
        editor.use(target, for: scope)
        session.showToast(String(localized: "“\(target.name)” is in use"), kind: .info)
    }

    // MARK: Saving

    private func save() {
        save(as: nil, replacing: false)
    }

    private func save(as name: String?, replacing: Bool) {
        switch editor.save(as: name, replacing: replacing) {
        case .saved:
            documents.keep([])
        case .needsName:
            presetName = editor.name
            isNaming = true
        case .exists(let existing):
            replacedName = existing
        case .failed(let message):
            failure = message
        }
    }

    private func exportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export")
        panel.message = String(localized: "Choose where the folder with the shader and all its files goes.")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let destination = GameExtras.available(folder.appending(path: GameExtras.sanitizedFileName(editor.name),
                                                                directoryHint: .isDirectory))
        do {
            let preset = try editor.export(to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([preset])
        } catch {
            failure = error.localizedDescription
        }
    }

    private func exportZip() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = GameExtras.sanitizedFileName(editor.name) + ".zip"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let staging = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            let folder = staging.appending(path: GameExtras.sanitizedFileName(editor.name), directoryHint: .isDirectory)
            _ = try editor.export(to: folder)
            try ShaderExport.zip(folder, to: target)
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch {
            failure = error.localizedDescription
        }
    }
}

extension FocusedValues {
    /// Saves the shader editor's draft; ⌘S while the editor is the key window.
    @Entry var shaderEditorSave: (() -> Void)?
}

/// Zips a folder with the system's own archiver (as Finder's Compress does).
nonisolated enum ShaderExport {
    static func zip(_ folder: URL, to target: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zipped in
            do {
                if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: zipped, to: target)
            } catch {
                copyError = error
            }
        }
        if let error = coordinatorError ?? copyError { throw error }
    }
}

/// Compiling, failed or fine: next to the window title.
private struct CompileStatus: View {
    @Environment(ShaderEditor.self) private var editor

    var body: some View {
        let workspace = editor.workspace
        Group {
            if workspace.isCompiling || workspace.isRecompiling {
                HStack(spacing: AppSpacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Compiling…")
                }
            } else if workspace.errorMessage != nil {
                Label("Error", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if workspace.preset != nil {
                Label("Compiled", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, AppSpacing.s)
    }
}

/// Two views above each other with a divider that is dragged to share the height.
private struct ResizableSplit<Top: View, Bottom: View>: View {
    @ViewBuilder let top: Top
    @ViewBuilder let bottom: Bottom
    @AppStorage("shaderEditorPreviewHeight") private var topHeight = 340.0
    @State private var dragStart: Double?

    private static var minimumTop: Double { 150 }
    private static var minimumBottom: Double { 160 }

    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size.height
            let height = min(max(topHeight, Self.minimumTop), max(Self.minimumTop, available - Self.minimumBottom - 1))
            VStack(spacing: 0) {
                top
                    .frame(height: height)
                Divider()
                    .overlay {
                        Color.clear
                            .frame(height: 8)
                            .contentShape(.rect)
                            .pointerStyle(.rowResize)
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { value in
                                    let start = dragStart ?? height
                                    if dragStart == nil { dragStart = start }
                                    topHeight = min(max(start + value.translation.height, Self.minimumTop),
                                                    available - Self.minimumBottom - 1)
                                }
                                .onEnded { _ in dragStart = nil })
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Preview Height")
                    .accessibilityValue(Text(verbatim: (height / max(available, 1)).formatted(.percent.precision(.fractionLength(0)))))
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: topHeight = min(height + 40, available - Self.minimumBottom - 1)
                        case .decrement: topHeight = max(height - 40, Self.minimumTop)
                        @unknown default: break
                        }
                    }
                bottom
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Passes

private struct PassList: View {
    @Environment(ShaderEditor.self) private var editor
    @State private var addsFromLibrary = false

    var body: some View {
        @Bindable var editor = editor
        List(selection: $editor.selectedPassID) {
            Section("Passes") {
                ForEach(Array(editor.preset.passes.enumerated()), id: \.element.id) { index, pass in
                    PassRow(index: index, pass: pass)
                        .tag(pass.id)
                        .contextMenu {
                            Button("Duplicate") { editor.duplicatePass(pass.id) }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: pass.shader)])
                            }
                            Divider()
                            Button("Remove Pass", role: .destructive) { editor.removePass(pass.id) }
                        }
                }
                .onMove { editor.movePasses(from: $0, to: $1) }
            }
            if !editor.preset.textures.isEmpty {
                Section("Textures") {
                    ForEach(editor.preset.textures) { texture in
                        Label(texture.name, systemImage: "photo")
                            .help(URL(filePath: texture.path).lastPathComponent)
                            .selectionDisabled()
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: AppSpacing.s) {
                Menu("Add Pass", systemImage: "plus") {
                    Button("Passes from a Preset…") { addsFromLibrary = true }
                    Button("New Pass") { editor.addNewPass() }
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add Pass")
                Button("Remove Pass", systemImage: "minus") {
                    if let id = editor.selectedPassID { editor.removePass(id) }
                }
                .disabled(editor.selectedPassID == nil || editor.preset.passes.count < 2)
                .help("Remove Pass")
                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(AppSpacing.s)
            .background(.bar)
        }
        .sheet(isPresented: $addsFromLibrary) {
            ShaderBrowser(current: nil, actionTitle: "Add Passes") { editor.addPasses(from: $0) }
        }
    }
}

private struct PassRow: View {
    @Environment(ShaderEditor.self) private var editor
    let index: Int
    let pass: SlangPreset.Pass

    var body: some View {
        let file = URL(filePath: pass.shader)
        let isOwn = editor.info.map { ShaderDrafts.isOwn(file, id: $0.id, in: editor.shaders.draftsDirectory) } ?? false
        HStack(spacing: AppSpacing.s) {
            Text(verbatim: "\(index + 1)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: file.deletingPathExtension().lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let alias = pass.alias {
                    Text(verbatim: alias)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isOwn {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
                    .help("Edited in this shader")
                    .accessibilityLabel("Edited")
            }
            if let limit = editor.passLimit, index >= limit {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.tertiary)
                    .help("Not shown in the preview")
                    .accessibilityLabel("Not shown in the preview")
            }
        }
        .help(pass.shader)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Source

private struct SourcePane: View {
    @Environment(ShaderEditor.self) private var editor
    let documents: SourceDocuments

    var body: some View {
        VStack(spacing: 0) {
            TabBar()
            Divider()
            if let tab = editor.selectedTab {
                fileNote(tab)
                SourceEditorView(document: documents.document(for: tab, editor: editor))
                    .id(tab.id)
            } else {
                ContentUnavailableView("No File Open", systemImage: "doc.text",
                                       description: Text("Choose a pass to edit its shader."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            IssueList()
        }
        .onChange(of: editor.tabs) { _, tabs in
            documents.keep(tabs)
            updateDiagnostics()
        }
        .onChange(of: editor.workspace.compileCount) { updateDiagnostics() }
        .onChange(of: editor.revealRequest) { _, request in
            guard let request, let tab = editor.tabs.first(where: { $0.id == request.tab }) else { return }
            let document = documents.document(for: tab, editor: editor)
            // After the tab's view is in the window.
            Task { @MainActor in
                document.reveal(line: request.line)
                editor.revealed()
            }
        }
    }

    @ViewBuilder
    private func fileNote(_ tab: ShaderEditor.SourceTab) -> some View {
        let own = editor.isOwn(tab)
        let isPack = tab.url.standardizedFileURL.pathComponents
            .starts(with: editor.shaders.libraryDirectory.standardizedFileURL.pathComponents)
        if !own {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "info.circle")
                    .accessibilityHidden(true)
                Text(isPack ? "A file of the shader pack. Your first change edits a copy in this shader."
                     : "Your first change edits a copy; Save writes it back.")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, AppSpacing.m)
            .padding(.vertical, AppSpacing.xs)
            .background(.quaternary.opacity(0.5))
        }
    }

    /// Marks the error lines of every open document.
    private func updateDiagnostics() {
        let issues = editor.issues()
        for tab in editor.tabs {
            guard let document = documents.existing(tab.id) else { continue }
            var lines: [Int: String] = [:]
            for issue in issues where issue.url == tab.url {
                if let line = issue.line { lines[line] = issue.message }
            }
            document.diagnostics = lines
        }
    }
}

private struct TabBar: View {
    @Environment(ShaderEditor.self) private var editor

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 1) {
                    ForEach(editor.tabs) { tab in
                        TabButton(tab: tab, isSelected: tab.id == editor.selectedTabID)
                    }
                }
            }
            .scrollIndicators(.never)
            if let pass = editor.selectedPass {
                let includes = editor.files(of: pass.id).dropFirst()
                if !includes.isEmpty {
                    Menu {
                        ForEach(Array(includes), id: \.self) { file in
                            Button(file.lastPathComponent) { editor.openSource(file, for: pass.id) }
                        }
                    } label: {
                        Label("Included Files", systemImage: "doc.on.doc")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .labelStyle(.iconOnly)
                    .help("Open a file this pass includes")
                    .padding(.horizontal, AppSpacing.s)
                }
            }
        }
        .frame(height: 28)
        .background(.bar)
    }
}

private struct TabButton: View {
    @Environment(ShaderEditor.self) private var editor
    let tab: ShaderEditor.SourceTab
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            Button("Close Tab", systemImage: "xmark") { editor.closeTab(tab.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .imageScale(.small)
                .opacity(isHovered || isSelected ? 1 : 0)
                .help("Close Tab")
            Text(verbatim: tab.name)
                .font(.callout)
                .lineLimit(1)
            if let pass = tab.passID.flatMap({ id in editor.preset.passes.firstIndex { $0.id == id } }) {
                Text(verbatim: "\(pass + 1)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Pass \(pass + 1)")
            }
        }
        .padding(.horizontal, AppSpacing.s)
        .frame(maxHeight: .infinity)
        .background(isSelected ? AnyShapeStyle(.background) : AnyShapeStyle(.clear))
        .contentShape(.rect)
        .onTapGesture { editor.selectedTabID = tab.id }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { editor.selectedTabID = tab.id }
    }
}

/// Compile errors and preset problems; clicking one shows its line.
private struct IssueList: View {
    @Environment(ShaderEditor.self) private var editor

    var body: some View {
        let _ = editor.workspace.compileCount
        let issues = editor.issues()
        if !issues.isEmpty {
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(issues) { issue in
                        Button {
                            editor.reveal(issue)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
                                Image(systemName: "xmark.octagon.fill")
                                    .foregroundStyle(.red)
                                    .accessibilityLabel("Error")
                                if let file = issue.fileName, let line = issue.line {
                                    Text(verbatim: "\(file):\(line)")
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Text(verbatim: issue.message)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, AppSpacing.m)
                            .padding(.vertical, AppSpacing.xs)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(issue.url == nil)
                    }
                }
                .padding(.vertical, AppSpacing.xs)
            }
            .frame(height: min(CGFloat(issues.count) * 24 + 8, 110))
            .background(.red.opacity(0.06))
        }
    }
}
