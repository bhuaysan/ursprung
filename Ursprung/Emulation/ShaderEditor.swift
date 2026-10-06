// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import OSLog

/// The shader editor's state: the draft being edited, its open source files
/// and the preview. With a game running, the draft shows in the player
/// (through the session's `ShaderWorkspace`); otherwise on a still picture
/// in the editor window. See docs/SHADER_PLAN.md, phase 5.
@Observable
final class ShaderEditor {
    /// What the editor opens with.
    enum Request: Hashable {
        /// The draft from last time, or an empty preset.
        case lastDraft
        /// What the running game shows.
        case current
        case preset(ShaderPresetRef)
        /// The game's preset, with the frames captured from it.
        case game(UUID, systemID: String?)
        case system(String)
        case newPreset
    }

    /// A source file open in a tab, edited for one pass.
    struct SourceTab: Identifiable, Hashable {
        let id = UUID()
        var url: URL
        var passID: SlangPreset.Pass.ID?
        var name: String { url.lastPathComponent }
    }

    /// What the still preview shows.
    enum StillSource: Hashable {
        case pattern(ShaderTestPattern, width: Int, height: Int)
        /// A frame captured from a game at its own resolution.
        case frame(URL)
        /// Any image, at a source resolution (its own when nil).
        case image(URL, width: Int?, height: Int?)
    }

    /// A problem with the draft: a compile error (with its place when known)
    /// or something wrong in the preset.
    struct Issue: Identifiable, Hashable {
        let id = UUID()
        let message: String
        var fileName: String?
        var line: Int?
        var url: URL?
    }

    enum SaveResult: Equatable {
        case saved(ShaderPresetRef)
        /// The draft has no name yet.
        case needsName
        /// A preset of that name exists; save again with `replacing`.
        case exists(String)
        case failed(String)
    }

    let session: EmulationSession
    let shaders: ShaderLibrary
    /// Compiles and renders the draft when no game runs.
    let stillWorkspace = ShaderWorkspace()

    private(set) var info: ShaderDraftInfo?
    private(set) var preset = SlangPreset()
    var selectedPassID: SlangPreset.Pass.ID? {
        didSet { if selectedPassID != oldValue { openSelectedPassSource() } }
    }
    private(set) var tabs: [SourceTab] = []
    var selectedTabID: SourceTab.ID?
    /// A line a tab should scroll to (set when an error is clicked).
    struct RevealRequest: Equatable {
        let id = UUID()
        let tab: SourceTab.ID
        let line: Int
    }

    private(set) var revealRequest: RevealRequest?
    /// Parameters each pass's shader declares, for grouping and defaults.
    private(set) var passParameters: [SlangPreset.Pass.ID: [SlangSource.Parameter]] = [:]
    /// Why the requested preset couldn't be opened.
    private(set) var openError: String?
    /// A request that waits until the user decides about unsaved changes.
    var pendingRequest: Request?
    /// The game the editor was opened for: its captured frames and "Use for This Game".
    private(set) var contextGameID: UUID?
    private(set) var contextSystemID: String?
    var stillSource: StillSource = .pattern(.colorBars, width: 256, height: 224) {
        didSet { if stillSource != oldValue { loadStillSource() } }
    }
    private(set) var stillFrame: StillFrame?
    private(set) var stillSourceError: String?
    /// The editor window is open: the player shows the draft meanwhile.
    var isWindowOpen = false {
        didSet { updatePlayerPreset() }
    }

    @ObservationIgnored private var recompileTask: Task<Void, Never>?
    @ObservationIgnored private var parameterTask: Task<Void, Never>?
    @ObservationIgnored private var stillTask: Task<Void, Never>?
    @ObservationIgnored private var appliedRequest = false

    private static let log = Logger(subsystem: "io.github.bhuaysan.Ursprung", category: "shader-editor")

    init(session: EmulationSession, shaders: ShaderLibrary) {
        self.session = session
        self.shaders = shaders
    }

    // MARK: State

    /// A game runs: the player is the preview.
    var isLive: Bool { session.phase == .running }

    /// The workspace that compiles and shows the draft right now.
    var workspace: ShaderWorkspace { isLive ? session.shader : stillWorkspace }

    /// Only the first passes show ("the output of pass N"); nil shows all.
    /// The renderers then compile a copy of the draft with just those passes:
    /// librashader's own pass limit crashes on presets whose passes read
    /// later passes' output.
    var passLimit: Int? {
        didSet {
            guard passLimit != oldValue else { return }
            persist()
            updatePlayerPreset()
        }
    }

    /// The reference the renderers compile the draft by.
    var draftRef: ShaderPresetRef? {
        info.map { info in
            guard let limit = activePassLimit else { return ShaderDrafts.ref(info.id) }
            return ShaderPresetRef(source: .draft, path: "\(info.id.uuidString)/\(Self.previewFileName(limit))")!
        }
    }

    private var activePassLimit: Int? {
        passLimit.flatMap { $0 < preset.passes.count ? max($0, 1) : nil }
    }

    private static func previewFileName(_ limit: Int) -> String { "preview-\(limit).slangp" }

    var name: String { info?.name ?? "" }
    var isModified: Bool { info?.isModified ?? false }
    /// Where Save writes, once the draft has been saved or came from the user's folder.
    var target: ShaderPresetRef? { info?.targetPreset }

    var selectedPass: SlangPreset.Pass? { preset.passes.first { $0.id == selectedPassID } }
    var selectedTab: SourceTab? { tabs.first { $0.id == selectedTabID } }

    private var root: URL { shaders.draftsDirectory }

    // MARK: Opening

    /// Opens what `request` asks for. With unsaved changes, the request
    /// waits in `pendingRequest` until `resolvePending(discard:)`.
    func open(_ request: Request) {
        // Without a game, "what the game shows" is whatever the editor had.
        guard request != .lastDraft, request != .current || isLive, let resolved = resolve(request) else {
            if info == nil { openLastDraft() }
            return
        }
        if let origin = info?.originPreset, origin == resolved.preset, !resolved.isNew { return }
        if isModified {
            pendingRequest = request
            return
        }
        apply(resolved)
    }

    /// Continues a waiting request, discarding the draft's changes, or drops it.
    func resolvePending(discard: Bool) {
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        if discard, let resolved = resolve(request) { apply(resolved) }
    }

    private struct Resolved {
        var preset: ShaderPresetRef?
        var isNew = false
        var gameID: UUID?
        var systemID: String?
    }

    private func resolve(_ request: Request) -> Resolved? {
        switch request {
        case .lastDraft:
            return nil
        case .newPreset:
            return Resolved(isNew: true, gameID: contextGameID, systemID: contextSystemID)
        case .preset(let preset):
            return Resolved(preset: preset, gameID: contextGameID, systemID: contextSystemID)
        case .current:
            var selection: ShaderPresetRef?
            if case .preset(let preset) = ShaderSelection.current(for: session.systemID, gameID: session.runningGameID) {
                selection = preset
            }
            return Resolved(preset: selection, isNew: selection == nil, gameID: session.runningGameID,
                            systemID: session.systemID)
        case .game(let gameID, let systemID):
            var resolved = Resolved(gameID: gameID, systemID: systemID)
            if case .preset(let preset) = ShaderSelection.current(for: systemID, gameID: gameID) {
                resolved.preset = preset
            } else {
                resolved.isNew = true
            }
            return resolved
        case .system(let systemID):
            var resolved = Resolved(systemID: systemID)
            if case .preset(let preset) = ShaderSelection.current(for: systemID) {
                resolved.preset = preset
            } else {
                resolved.isNew = true
            }
            return resolved
        }
    }

    private func apply(_ resolved: Resolved) {
        contextGameID = resolved.gameID
        contextSystemID = resolved.systemID
        if let gameID = resolved.gameID,
           let frame = ShaderFrameStore.frames(in: AppPaths.extras, gameID: gameID).first {
            stillSource = .frame(frame)
        }
        if let preset = resolved.preset, !resolved.isNew {
            openPreset(preset)
        } else {
            newDraft()
        }
    }

    private func openLastDraft() {
        if let id = ShaderDrafts.latest(in: root), let (info, preset) = try? ShaderDrafts.load(id, in: root) {
            show(info, preset)
        } else {
            newDraft()
        }
    }

    /// A new draft of `preset`. Pack presets are never a save target.
    func openPreset(_ ref: ShaderPresetRef) {
        do {
            let (info, preset) = try ShaderDrafts.create(from: shaders.url(of: ref), name: ref.name, origin: ref,
                                                         target: ref.source == .user ? ref : nil, in: root)
            show(info, preset)
            openError = nil
        } catch {
            openError = String(localized: "“\(ref.name)” couldn’t be opened. \(error.localizedDescription)")
            if info == nil { newDraft() }
        }
    }

    /// An empty preset with one new pass.
    func newDraft() {
        do {
            var (info, preset) = try ShaderDrafts.create(from: nil, name: String(localized: "New Shader"), origin: nil,
                                                         target: nil, in: root)
            let shader = try ShaderDrafts.newShader(named: "pass", info: &info, in: root)
            preset.passes = [SlangPreset.Pass(shader: shader.path(percentEncoded: false))]
            preset.passes[0].scaleTypeX = .viewport
            preset.passes[0].scaleTypeY = .viewport
            try ShaderDrafts.write(preset, info: info, in: root)
            show(info, preset)
        } catch {
            openError = error.localizedDescription
        }
    }

    private func show(_ info: ShaderDraftInfo, _ preset: SlangPreset) {
        let previous = self.info?.id
        self.info = info
        self.preset = preset
        tabs = []
        selectedTabID = nil
        selectedPassID = preset.passes.first?.id
        passLimit = nil
        if let previous, previous != info.id { ShaderDrafts.remove(previous, in: root) }
        ShaderDrafts.removeAll(in: root, keeping: info.id)
        updatePlayerPreset()
        readParameters()
        if stillFrame == nil { loadStillSource() }
    }

    /// While the editor is open, the player shows the draft.
    private func updatePlayerPreset() {
        session.shader.editorPreset = isWindowOpen ? draftRef : nil
        if !isWindowOpen {
            session.shader.previewTools = ShaderPreviewTools()
        }
    }

    // MARK: Passes

    /// Changes the preset, saves the draft and compiles it again.
    func update(recompile: Bool = true, _ change: (inout SlangPreset) -> Void) {
        var changed = preset
        change(&changed)
        guard changed != preset else { return }
        preset = changed
        markModified()
        persist()
        if recompile { scheduleRecompile(after: .milliseconds(150)) }
    }

    /// A binding target for the inspector: the pass with `id`.
    func updatePass(_ id: SlangPreset.Pass.ID, _ change: (inout SlangPreset.Pass) -> Void) {
        update { preset in
            guard let index = preset.passes.firstIndex(where: { $0.id == id }) else { return }
            change(&preset.passes[index])
        }
    }

    /// Adds the passes of a library preset after the selected pass, with
    /// its textures and values unless the draft has them already.
    func addPasses(from ref: ShaderPresetRef) {
        do {
            let added = try SlangPreset.load(from: shaders.url(of: ref))
            update { preset in
                let index = preset.passes.firstIndex { $0.id == selectedPassID }.map { $0 + 1 } ?? preset.passes.count
                preset.passes.insert(contentsOf: added.passes, at: index)
                let names = Set(preset.textures.map(\.name))
                preset.textures += added.textures.filter { !names.contains($0.name) }
                for value in added.values where preset.value(of: value.name) == nil {
                    preset.setValue(value.value, of: value.name)
                }
            }
            selectedPassID = added.passes.first?.id
            readParameters()
        } catch {
            openError = String(localized: "The passes of “\(ref.name)” couldn’t be added. \(error.localizedDescription)")
        }
    }

    /// Adds a pass with a new shader from the template.
    func addNewPass() {
        guard var info else { return }
        do {
            let shader = try ShaderDrafts.newShader(named: "pass", info: &info, in: root)
            self.info = info
            var pass = SlangPreset.Pass(shader: shader.path(percentEncoded: false))
            pass.scaleTypeX = .source
            pass.scaleTypeY = .source
            update { preset in
                let index = preset.passes.firstIndex { $0.id == selectedPassID }.map { $0 + 1 } ?? preset.passes.count
                preset.passes.insert(pass, at: index)
            }
            selectedPassID = pass.id
            readParameters()
        } catch {
            openError = error.localizedDescription
        }
    }

    func duplicatePass(_ id: SlangPreset.Pass.ID) {
        guard let index = preset.passes.firstIndex(where: { $0.id == id }) else { return }
        var copy = preset.passes[index].duplicated()
        // Two passes of one name would break the preset.
        copy.alias = nil
        update { $0.passes.insert(copy, at: index + 1) }
        selectedPassID = copy.id
        readParameters()
    }

    func removePass(_ id: SlangPreset.Pass.ID) {
        guard let index = preset.passes.firstIndex(where: { $0.id == id }) else { return }
        update { $0.passes.remove(at: index) }
        tabs.removeAll { $0.passID == id }
        if selectedPassID == id {
            selectedPassID = preset.passes.indices.contains(index) ? preset.passes[index].id : preset.passes.last?.id
        }
        readParameters()
    }

    func movePasses(from source: IndexSet, to destination: Int) {
        update { preset in
            let moving = source.map { preset.passes[$0] }
            let before = source.filter { $0 < destination }.count
            for index in source.reversed() { preset.passes.remove(at: index) }
            preset.passes.insert(contentsOf: moving, at: destination - before)
        }
    }

    // MARK: Textures

    func addTexture(_ url: URL) {
        let base = url.deletingPathExtension().lastPathComponent.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        var name = base.isEmpty || base.first!.isNumber ? "Texture" + base : base
        let names = Set(preset.textures.map(\.name))
        if names.contains(name) {
            let stem = name
            name = (2...).lazy.map { "\(stem)\($0)" }.first { !names.contains($0) }!
        }
        update { $0.textures.append(SlangPreset.Texture(name: name, path: url.path(percentEncoded: false))) }
    }

    func updateTexture(_ id: SlangPreset.Texture.ID, _ change: (inout SlangPreset.Texture) -> Void) {
        update { preset in
            guard let index = preset.textures.firstIndex(where: { $0.id == id }) else { return }
            change(&preset.textures[index])
        }
    }

    func removeTexture(_ id: SlangPreset.Texture.ID) {
        update { $0.textures.removeAll { $0.id == id } }
    }

    // MARK: Parameters

    /// The shader's own value of `name` (not the preset's).
    func defaultValue(of name: String) -> Float? {
        for parameters in passParameters.values {
            if let parameter = parameters.first(where: { $0.name == name }) { return parameter.initial }
        }
        return nil
    }

    /// Whether the draft sets `name` to something else than the shader does.
    func isParameterChanged(_ name: String) -> Bool {
        preset.value(of: name) != nil
    }

    /// Changes a parameter live, and keeps it in the draft (no recompile).
    func setParameter(_ name: String, to value: Float) {
        workspace.setValue(value, for: name)
        let shaderValue = defaultValue(of: name)
        let keep = shaderValue.map { abs($0 - value) > 0.000_001 } ?? true
        update(recompile: false) { $0.setValue(keep ? ShaderPresetWriter.format(value) : nil, of: name) }
    }

    /// Back to the shader's own value.
    func resetParameter(_ name: String) {
        if let value = defaultValue(of: name) { workspace.setValue(value, for: name) }
        update(recompile: false) { $0.setValue(nil, of: name) }
    }

    func resetAllParameters() {
        for parameter in workspace.parameters where isParameterChanged(parameter.name) {
            if let value = defaultValue(of: parameter.name) { workspace.setValue(value, for: parameter.name) }
        }
        let names = Set(workspace.parameters.map(\.name))
        update(recompile: false) { $0.values.removeAll { names.contains($0.name) } }
    }

    /// The parameters of the preset in use, grouped by the pass that declares
    /// them first; parameters no pass declares (a stale list) come last.
    func parameterGroups() -> [(pass: Int?, parameters: [ShaderParameter])] {
        var owner: [String: Int] = [:]
        // Declaration order across all passes, so each group lists them as the shaders do.
        var order: [String: Int] = [:]
        for (index, pass) in preset.passes.enumerated() {
            for parameter in passParameters[pass.id] ?? [] where owner[parameter.name] == nil {
                owner[parameter.name] = index
                order[parameter.name] = order.count
            }
        }
        var groups: [Int?: [ShaderParameter]] = [:]
        for (position, parameter) in workspace.parameters.enumerated() {
            groups[owner[parameter.name], default: []].append(parameter)
            if order[parameter.name] == nil { order[parameter.name] = Int.max / 2 + position }
        }
        return groups.keys.sorted { ($0 ?? .max) < ($1 ?? .max) }.map { pass in
            (pass, (groups[pass] ?? []).sorted { order[$0.name, default: 0] < order[$1.name, default: 0] })
        }
    }

    /// Reads the `#pragma parameter` lines of every pass (and its includes).
    private func readParameters() {
        let passes = preset.passes.map { ($0.id, $0.shader) }
        parameterTask?.cancel()
        parameterTask = Task {
            let result = await Self.parameters(of: passes)
            guard !Task.isCancelled else { return }
            passParameters = result
        }
    }

    @concurrent
    private static func parameters(of passes: [(SlangPreset.Pass.ID, String)]) async -> [SlangPreset.Pass.ID: [SlangSource.Parameter]] {
        var result: [SlangPreset.Pass.ID: [SlangSource.Parameter]] = [:]
        var cache: [String: [SlangSource.Parameter]] = [:]
        for (id, shader) in passes where shader.hasPrefix("/") {
            var parameters: [SlangSource.Parameter] = []
            for file in SlangSource.closure(of: URL(filePath: shader)) {
                let key = file.path(percentEncoded: false)
                if cache[key] == nil {
                    cache[key] = (try? String(contentsOf: file, encoding: .utf8)).map(SlangSource.parameters(in:)) ?? []
                }
                parameters += cache[key] ?? []
            }
            result[id] = parameters
        }
        return result
    }

    // MARK: Sources

    /// The files of a pass: its shader and everything it includes.
    func files(of passID: SlangPreset.Pass.ID) -> [URL] {
        guard let pass = preset.passes.first(where: { $0.id == passID }), pass.shader.hasPrefix("/") else { return [] }
        return SlangSource.closure(of: URL(filePath: pass.shader))
    }

    /// Opens `url` in a tab for the pass (or selects its tab).
    func openSource(_ url: URL, for passID: SlangPreset.Pass.ID?) {
        let url = url.standardizedFileURL
        if let tab = tabs.first(where: { $0.url == url && $0.passID == passID }) {
            selectedTabID = tab.id
            return
        }
        let tab = SourceTab(url: url, passID: passID)
        // The pass's own shader replaces another pass's shader tab, so tabs don't pile up.
        if let passID, let shader = preset.passes.first(where: { $0.id == passID })?.shader,
           URL(filePath: shader).standardizedFileURL == url,
           let index = tabs.firstIndex(where: { tab in
               tab.passID != passID && preset.passes.contains { $0.id == tab.passID && URL(filePath: $0.shader).standardizedFileURL == tab.url }
           }) {
            tabs[index] = tab
        } else {
            tabs.append(tab)
        }
        selectedTabID = tab.id
    }

    func closeTab(_ id: SourceTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == id { selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id }
    }

    private func openSelectedPassSource() {
        guard let pass = selectedPass, pass.shader.hasPrefix("/") else { return }
        openSource(URL(filePath: pass.shader), for: pass.id)
    }

    /// Whether editing `tab` changes a copy the draft owns (otherwise the
    /// first change makes one).
    func isOwn(_ tab: SourceTab) -> Bool {
        guard let info else { return false }
        return ShaderDrafts.isOwn(tab.url, id: info.id, in: root)
    }

    /// The text of `tab` changed: writes it to the draft's own copy (made on
    /// the first change) and compiles again shortly. Returns the tab's file now.
    @discardableResult
    func sourceChanged(_ tabID: SourceTab.ID, text: String) -> URL? {
        guard var info, let index = tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        var tab = tabs[index]
        do {
            if !ShaderDrafts.isOwn(tab.url, id: info.id, in: root) {
                try makeOwn(&tab, info: &info)
                tabs[index] = tab
                self.info = info
            }
            try text.write(to: tab.url, atomically: true, encoding: .utf8)
        } catch {
            openError = String(localized: "Your change couldn’t be saved. \(error.localizedDescription)")
            return nil
        }
        markModified()
        persist()
        scheduleRecompile(after: .milliseconds(400))
        if tab.url.pathExtension == "slang" || SlangSource.parameters(in: text).isEmpty == false { readParameters() }
        return tab.url
    }

    /// Copies the tab's pass shader with its includes into the draft and
    /// points the pass (and the pass's other tabs) at the copies.
    private func makeOwn(_ tab: inout SourceTab, info: inout ShaderDraftInfo) throws {
        let shader: URL
        if let passID = tab.passID, let pass = preset.passes.first(where: { $0.id == passID }), pass.shader.hasPrefix("/") {
            shader = URL(filePath: pass.shader)
        } else {
            shader = tab.url
        }
        let copy = try ShaderDrafts.ownCopy(of: shader, info: &info, in: root, library: shaders.libraryDirectory,
                                            user: shaders.userDirectory)
        if let passID = tab.passID {
            preset.passes = preset.passes.map { pass in
                var pass = pass
                if pass.id == passID { pass.shader = copy.path(percentEncoded: false) }
                return pass
            }
        }
        let files = ShaderDrafts.filesURL(info.id, in: root)
        func ownURL(_ url: URL) -> URL? {
            info.files.first { $0.origin == url.standardizedFileURL.path(percentEncoded: false) }
                .map { files.appending(path: $0.path, directoryHint: .notDirectory).standardizedFileURL }
        }
        if let own = ownURL(tab.url) { tab.url = own }
        for index in tabs.indices where tabs[index].passID == tab.passID {
            if let own = ownURL(tabs[index].url) { tabs[index].url = own }
        }
    }

    /// Opens the file an issue names at its line.
    func reveal(_ issue: Issue) {
        guard let url = issue.url, let line = issue.line else { return }
        let pass = selectedPassID.flatMap { id in files(of: id).contains(url) ? id : nil }
            ?? preset.passes.first { pass in files(of: pass.id).contains(url) }?.id
        openSource(url, for: pass)
        if let selectedTabID { revealRequest = RevealRequest(tab: selectedTabID, line: line) }
    }

    func revealed() {
        revealRequest = nil
    }

    // MARK: Issues

    /// Problems in the preset, and the last compile error with the lines it names.
    func issues() -> [Issue] {
        var issues = preset.problems.map { Issue(message: $0) }
        guard let message = workspace.errorMessage else { return issues }
        let diagnostics = SlangSource.diagnostics(in: message)
        guard !diagnostics.isEmpty else {
            issues.append(Issue(message: SlangSource.summary(of: message)))
            return issues
        }
        // glslang names files without folder: look in the selected pass first.
        let ordered = (selectedPassID.map { [$0] } ?? []) + preset.passes.map(\.id)
        var candidates: [URL] = []
        for id in ordered { candidates += files(of: id) }
        for diagnostic in diagnostics {
            let url = candidates.first { $0.lastPathComponent == diagnostic.fileName }
            issues.append(Issue(message: diagnostic.message, fileName: diagnostic.fileName, line: diagnostic.line, url: url))
        }
        return issues
    }

    // MARK: Compiling

    private func scheduleRecompile(after delay: Duration) {
        recompileTask?.cancel()
        recompileTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            session.shader.reloadPreset()
            stillWorkspace.reloadPreset()
        }
    }

    /// Compiles the draft again now.
    func recompile() {
        scheduleRecompile(after: .zero)
    }

    private func markModified() {
        guard info?.isModified == false else { return }
        info?.isModified = true
    }

    private func persist() {
        guard let info else { return }
        do {
            try ShaderDrafts.write(preset, info: info, in: root)
            if let limit = activePassLimit {
                var preview = preset
                preview.passes = Array(preview.passes.prefix(limit))
                let folder = ShaderDrafts.folder(info.id, in: root)
                try preview.text(relativeTo: folder).write(to: folder.appending(path: Self.previewFileName(limit)),
                                                           atomically: true, encoding: .utf8)
            }
        } catch {
            Self.log.error("Draft couldn't be written: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Saving

    /// Saves to the draft's user preset, or under `name` in My Shaders.
    func save(as name: String? = nil, replacing: Bool = false) -> SaveResult {
        guard let info else { return .failed(String(localized: "Nothing to save.")) }
        let target: ShaderPresetRef
        let inPlace: Bool
        if let name {
            guard let fileName = ShaderPresetWriter.fileName(for: name),
                  let ref = ShaderPresetRef(source: .user, path: fileName)
            else { return .failed(String(localized: "Choose another name.")) }
            target = ref
            inPlace = ref == info.targetPreset
            if !replacing, !inPlace, shaders.exists(ref) { return .exists(ref.name) }
        } else if let existing = info.targetPreset {
            target = existing
            inPlace = true
        } else {
            return .needsName
        }
        do {
            try ShaderDrafts.save(preset, info: info, to: shaders.url(of: target), inPlace: inPlace, in: root,
                                  user: shaders.userDirectory)
        } catch {
            return .failed(error.localizedDescription)
        }
        shaders.refresh()
        // Continue on the saved preset: its files are the user's now.
        let selected = preset.passes.firstIndex { $0.id == selectedPassID }
        openPreset(target)
        if let selected, preset.passes.indices.contains(selected) { selectedPassID = preset.passes[selected].id }
        // Settings that use the preset show the saved version.
        let saved = ShaderSelection.preset(target)
        if session.shader.preset == target || ShaderSelection.current(for: session.systemID, gameID: session.runningGameID) == saved {
            session.shader.reloadPreset()
        }
        return .saved(target)
    }

    /// Goes back to the preset the draft was opened from.
    func revert() {
        if let origin = info?.originPreset, shaders.exists(origin) {
            openPreset(origin)
        } else {
            newDraft()
        }
    }

    /// The draft's preset file, e.g. to show in Finder.
    var draftURL: URL? { info.map { ShaderDrafts.presetURL($0.id, in: root) } }

    /// The saved preset, or else the draft.
    var revealURL: URL? { target.map { shaders.url(of: $0) } ?? draftURL }

    /// Writes a folder with the draft and every file it reads.
    func export(to folder: URL) throws -> URL {
        guard let draftURL else { throw CocoaError(.fileNoSuchFile) }
        return try ShaderDrafts.export(draftURL, named: name, to: folder)
    }

    /// Uses the saved preset for a game, a system or all systems.
    func use(_ ref: ShaderPresetRef, for scope: ShaderScope) {
        scope.setSelection(.preset(ref))
    }

    // MARK: Still preview

    private func loadStillSource() {
        let source = stillSource
        let coreName = session.coreName
        stillTask?.cancel()
        stillTask = Task {
            let picture = await Self.picture(for: source)
            guard !Task.isCancelled else { return }
            if let picture {
                let frame = StillFrame(picture, coreName: coreName)
                frame.isPaused = stillFrame?.isPaused ?? false
                stillFrame = frame
                stillSourceError = nil
            } else {
                stillSourceError = String(localized: "The picture couldn’t be opened.")
            }
        }
    }

    @concurrent
    private static func picture(for source: StillSource) async -> StillPicture? {
        switch source {
        case .pattern(let pattern, let width, let height): pattern.picture(width: width, height: height)
        case .frame(let url): StillPicture.load(url)
        case .image(let url, let width, let height): StillPicture.load(url, width: width, height: height)
        }
    }

    /// Captured frames of the game the editor was opened for, or of the running game.
    func capturedFrames() -> [URL] {
        guard let gameID = contextGameID ?? session.runningGameID else { return [] }
        return ShaderFrameStore.frames(in: AppPaths.extras, gameID: gameID)
    }
}
