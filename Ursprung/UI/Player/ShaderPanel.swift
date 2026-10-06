// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// The shader panel at the trailing edge of the player: choose a filter or
/// RetroArch preset for this game, its system or all systems, and tune the
/// preset's parameters on the running game. It overlays the picture instead
/// of shrinking it, because masks and scanlines depend on the output size.
///
/// While a slider is dragged, everything else fades out; holding ⌥ hides
/// the whole panel.
struct ShaderPanel: View {
    @Environment(EmulationSession.self) private var session
    @Environment(ShaderLibrary.self) private var shaders
    @Environment(ShaderEditor.self) private var editor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The level the panel shows and changes.
    @State private var scope = ShaderScope.all
    /// The choice stored at `scope`; nil inherits.
    @State private var stored: ShaderSelection?
    @State private var filter = ""
    /// The parameter whose slider is being dragged.
    @State private var draggedParameter: String?
    /// ⌥ is held: the panel steps aside to show the whole picture.
    @State private var isPeeking = false
    @State private var flagsMonitor: Any?
    @State private var isNaming = false
    @State private var presetName = ""
    @State private var replacedName: String?
    @State private var saveFailure: String?
    /// Bumped when preferences change, e.g. in the game's info panel.
    @State private var preferencesRevision = 0

    private var workspace: ShaderWorkspace { session.shader }
    private var isDragging: Bool { draggedParameter != nil }
    /// The editor previews its draft: a preset saved here would reference
    /// the draft, which goes away. The editor saves it instead.
    private var showsDraft: Bool { workspace.preset?.source == .draft }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .fadesWhileDragging(isDragging)
            PanelDivider()
                .padding(.vertical, AppSpacing.m)
                .fadesWhileDragging(isDragging)
            choice
                .fadesWhileDragging(isDragging)
            if workspace.preset != nil {
                parameters
            } else {
                PanelDivider()
                    .padding(.vertical, AppSpacing.m)
                    .fadesWhileDragging(isDragging)
                editorButton
            }
        }
        .padding(20)
        .frame(width: 320, alignment: .leading)
        .background {
            // Its own view so it can fade out while a slider is dragged.
            // Tinted: unlike the pause menu, the panel has no scrim behind it.
            Color.clear
                .glassEffect(Self.glass, in: .rect(cornerRadius: AppMetrics.pausePanelRadius))
                .opacity(isDragging ? 0 : 1)
        }
        .environment(\.colorScheme, .dark)
        .opacity(isPeeking ? 0 : 1)
        .allowsHitTesting(!isPeeking)
        .appAnimation(AppAnimation.quick, value: isDragging)
        .appAnimation(AppAnimation.quick, value: isPeeking)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shader")
        .onExitCommand { session.isShaderPanelVisible = false }
        .onAppear {
            scope = ShaderScope.deciding(gameID: session.runningGameID, systemID: session.systemID)
            stored = scope.selection()
            watchOptionKey()
        }
        .onDisappear(perform: stopWatchingOptionKey)
        .onChange(of: scope) { stored = scope.selection() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let current = scope.selection()
            if current != stored { stored = current }
            preferencesRevision += 1
        }
        .alert("Save as Preset", isPresented: $isNaming) {
            TextField("Name", text: $presetName)
            Button("Save") { save(replacing: false) }
                .disabled(ShaderPresetWriter.fileName(for: presetName) == nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the preset with your changes to My Shaders and uses it for \(scopeTitle).")
        }
        .confirmationDialog(Text("Replace “\(replacedName ?? "")”?"),
                            isPresented: Binding(get: { replacedName != nil }, set: { if !$0 { replacedName = nil } })) {
            Button("Replace", role: .destructive) { save(replacing: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("My Shaders already has a preset with this name.")
        }
        .alert("The preset couldn't be saved",
               isPresented: Binding(get: { saveFailure != nil }, set: { if !$0 { saveFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: saveFailure ?? "")
        }
    }

    static let glass = Glass.regular.tint(.black.opacity(0.35))

    /// Up to this many parameters, the panel is as tall as its content;
    /// more scroll in a lazy list.
    private static let fittingRowLimit = 24

    // MARK: Parts

    private var header: some View {
        HStack(spacing: AppSpacing.s) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text("Shader")
                    .font(.headline)
                Text("Hold ⌥ to see the whole picture.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: AppSpacing.s)
            CircleButton(session.isPaused ? "Resume" : "Pause", systemImage: session.isPaused ? "play.fill" : "pause.fill") {
                session.togglePause()
            }
            CircleButton("Close", systemImage: "xmark") { session.isShaderPanelVisible = false }
        }
    }

    private var choice: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Picker("Applies To", selection: $scope) {
                if let gameID = session.runningGameID {
                    Text("This Game").tag(ShaderScope.game(gameID))
                }
                if let systemID = session.systemID {
                    Text(verbatim: systemTitle).tag(ShaderScope.system(systemID))
                }
                Text("All Systems").tag(ShaderScope.all)
            }
            ShaderPicker(title: "Shader", selection: Binding(get: { stored }, set: { choose($0) }), inheritTitle: inheritTitle)
            overrideNote
            status
        }
        .pickerStyle(.menu)
    }

    /// Says so when a more specific level decides the picture, so a choice
    /// here doesn't show on this game.
    @ViewBuilder
    private var overrideNote: some View {
        let _ = preferencesRevision
        let deciding = ShaderScope.deciding(gameID: session.runningGameID, systemID: session.systemID)
        if deciding.specificity > scope.specificity, let selection = deciding.selection() {
            StatusLabel(deciding.specificity == 2
                            ? Text("This game has its own shader (\(selection.title)), so this choice doesn't show here.")
                            : Text("\(systemName) games have their own shader (\(selection.title)), so this choice doesn't show here."),
                        systemImage: "info.circle", kind: .neutral)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, AppSpacing.xs)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch workspace.status {
        case .compiling(let preset):
            HStack(spacing: AppSpacing.s) {
                ProgressView()
                    .controlSize(.small)
                Text("Compiling “\(preset.name)”…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, AppSpacing.xs)
        case .failed(let preset, let message):
            StatusLabel(Text("“\(preset.name)” couldn't be used"), kind: .warning, detail: message)
                .font(.subheadline)
                .lineLimit(6)
                .padding(.top, AppSpacing.xs)
        case .builtin:
            Text("Built-in filters have no settings. RetroArch shaders show their parameters here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, AppSpacing.xs)
        case .ready:
            if let detail = workspace.tooSlowDetail {
                StatusLabel("Too demanding for this Mac", kind: .warning, detail: detail)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, AppSpacing.xs)
            }
        }
    }

    @ViewBuilder
    private var parameters: some View {
        PanelDivider()
            .padding(.vertical, AppSpacing.m)
            .fadesWhileDragging(isDragging)
        if workspace.parameters.isEmpty {
            Text("This preset has no parameters.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fadesWhileDragging(isDragging)
        } else {
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                HStack {
                    Text("Parameters")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: AppSpacing.s)
                    Button("Reset All") { workspace.resetAll() }
                        .buttonStyle(.borderless)
                        .disabled(!workspace.isModified)
                }
                if workspace.parameters.count > 8 {
                    FilterField(text: $filter, prompt: "Filter Parameters")
                }
            }
            .fadesWhileDragging(isDragging)
            .padding(.bottom, AppSpacing.s)
            parameterList
        }
        PanelDivider()
            .padding(.vertical, AppSpacing.m)
            .fadesWhileDragging(isDragging)
        footer
            .fadesWhileDragging(isDragging)
    }

    @ViewBuilder
    private var parameterList: some View {
        let rows = visibleParameters
        if workspace.parameters.count <= Self.fittingRowLimit {
            FittingScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.name) { row($0) }
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.name) { row($0) }
                    if rows.isEmpty {
                        Text("No parameters match “\(filter)”.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(isDragging ? .hidden : .automatic)
        }
    }

    @ViewBuilder
    private func row(_ parameter: ShaderParameter) -> some View {
        if parameter.isHeading {
            Text(verbatim: parameter.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.horizontal, AppSpacing.s)
                .padding(.top, AppSpacing.m)
                .padding(.bottom, AppSpacing.xs)
                .fadesWhileDragging(isDragging)
        } else {
            ParameterRow(parameter: parameter, value: value(of: parameter),
                         isModified: workspace.isModified(parameter.name),
                         isDragged: draggedParameter == parameter.name,
                         reset: { workspace.reset(parameter.name) },
                         editingChanged: { editing in draggedParameter = editing ? parameter.name : nil })
                .opacity(isDragging && draggedParameter != parameter.name ? 0 : 1)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            if showsDraft {
                Text("The shader editor’s draft is showing. Save it in the shader editor.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if workspace.isModified {
                Text("Changes last until the game closes. Save them as a preset to keep them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: AppSpacing.s) {
                Button("Save as Preset…", action: startSaving)
                    .buttonStyle(.glass)
                    .disabled(workspace.preset == nil || showsDraft)
                editorButton
            }
        }
    }

    /// Opens the game's preset in the shader editor, which shows its changes on the game.
    private var editorButton: some View {
        Button("Open in Shader Editor") {
            editor.open(.current)
            openWindow(id: WindowID.shaderEditor)
        }
        .buttonStyle(.glass)
    }

    // MARK: Values

    private var visibleParameters: [ShaderParameter] {
        let all = workspace.parameters.filter { !$0.isHeading || !$0.label.isEmpty }
        guard !filter.isEmpty else { return all }
        return all.filter { !$0.isHeading && ($0.label.localizedStandardContains(filter) || $0.name.localizedStandardContains(filter)) }
    }

    private func value(of parameter: ShaderParameter) -> Binding<Float> {
        Binding(get: { workspace.values[parameter.name] ?? parameter.initial },
                set: { workspace.setValue(ParameterRow.snapped($0, to: parameter), for: parameter.name) })
    }

    // MARK: Scope

    private var systemName: String {
        session.systemID.flatMap { SystemCatalog.system(withID: $0)?.shortName } ?? ""
    }

    private var systemTitle: String {
        String(localized: "All \(systemName) Games")
    }

    /// The scope in words, for "uses it for …".
    private var scopeTitle: String {
        switch scope {
        case .game: String(localized: "this game")
        case .system: String(localized: "all \(systemName) games")
        case .all: String(localized: "all systems")
        }
    }

    /// What the scope inherits when it has no choice of its own.
    private var inheritTitle: String? {
        switch scope {
        case .game:
            let _ = preferencesRevision
            let inherited = ShaderSelection.current(for: session.systemID)
            return String(localized: "Same as \(systemName) (\(inherited.title))")
        case .system:
            let inherited = ShaderScope.all.selection() ?? .builtin(.sharp)
            return String(localized: "Same as All Systems (\(inherited.title))")
        case .all:
            return nil
        }
    }

    private func choose(_ selection: ShaderSelection?) {
        guard scope != .all || selection != nil else { return }
        stored = selection
        scope.setSelection(selection)
    }

    // MARK: Saving

    private func startSaving() {
        guard let preset = workspace.preset, preset.source != .draft else { return }
        presetName = preset.name
        isNaming = true
    }

    /// Writes the preset with the changed parameters to My Shaders (next to
    /// the current preset when that is one of the user's) and uses it for the scope.
    private func save(replacing: Bool) {
        guard let preset = workspace.preset, preset.source != .draft,
              let fileName = ShaderPresetWriter.fileName(for: presetName) else { return }
        let source = shaders.url(of: preset)
        let directory = preset.source == .user ? source.deletingLastPathComponent() : shaders.userDirectory
        let target = directory.appending(path: fileName, directoryHint: .notDirectory)
        let isCurrent = target.standardizedFileURL == source.standardizedFileURL
        if !replacing, !isCurrent, FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            replacedName = target.deletingPathExtension().lastPathComponent
            return
        }
        let values = workspace.values
        let userDirectory = shaders.userDirectory
        Task {
            do {
                try await Self.write(values, of: source, to: target)
            } catch {
                saveFailure = error.localizedDescription
                return
            }
            guard let saved = ShaderPresetRef(source: .user,
                                              path: ShaderPresetWriter.relativePath(from: userDirectory, to: target))
            else { return }
            shaders.refresh()
            choose(.preset(saved))
            // Saved over the preset in use: its file changed, not the selection.
            if isCurrent { workspace.reloadPreset() }
            session.showToast(String(localized: "Saved “\(saved.name)”"), kind: .saved)
        }
    }

    @concurrent
    private static func write(_ values: [String: Float], of source: URL, to target: URL) async throws {
        try ShaderPresetWriter.save(values, of: source, to: target)
    }

    // MARK: Peeking

    private func watchOptionKey() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated {
                // Only ⌥ on its own, so shortcuts with ⌥ don't flash the panel.
                isPeeking = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
            }
            return event
        }
    }

    private func stopWatchingOptionKey() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        isPeeking = false
    }
}

// MARK: - Parameter row

/// A parameter's name, value and slider. While its slider is dragged, the
/// row keeps a glass background of its own as the panel fades out.
struct ParameterRow: View {
    let parameter: ShaderParameter
    @Binding var value: Float
    let isModified: Bool
    let isDragged: Bool
    let reset: () -> Void
    let editingChanged: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            HStack(spacing: AppSpacing.xs) {
                Text(verbatim: parameter.label.isEmpty ? parameter.name : parameter.label)
                    .font(.callout)
                    .lineLimit(1)
                    .help(parameter.name)
                Spacer(minLength: AppSpacing.s)
                Text(verbatim: Self.format(value, step: parameter.step))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(isModified ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                Button("Reset Parameter", systemImage: "arrow.uturn.backward", action: reset)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .imageScale(.small)
                    .help("Reset to the Preset's Value")
                    .opacity(isModified ? 1 : 0)
                    .disabled(!isModified)
            }
            Slider(value: Binding(get: { Double(value) }, set: { value = Float($0) }),
                   in: Double(parameter.minimum)...Double(parameter.maximum),
                   onEditingChanged: editingChanged)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(Text(verbatim: parameter.label.isEmpty ? parameter.name : parameter.label))
                .accessibilityValue(Text(verbatim: Self.format(value, step: parameter.step)))
        }
        .padding(.horizontal, AppSpacing.s)
        .padding(.vertical, 6)
        .background {
            if isDragged {
                Color.clear
                    .glassEffect(ShaderPanel.glass, in: .rect(cornerRadius: AppMetrics.rowHighlightRadius))
            }
        }
    }

    /// `value` on the parameter's step grid, within its range.
    static func snapped(_ value: Float, to parameter: ShaderParameter) -> Float {
        let clamped = min(max(value, parameter.minimum), parameter.maximum)
        guard parameter.step > 0 else { return clamped }
        let steps = ((clamped - parameter.minimum) / parameter.step).rounded()
        return min(parameter.minimum + steps * parameter.step, parameter.maximum)
    }

    /// As many decimals as the step needs (at most four).
    static func format(_ value: Float, step: Float) -> String {
        let decimals = step > 0 && step < 1 ? min(4, Int((-log10(step)).rounded(.up))) : 0
        return value.formatted(.number.precision(.fractionLength(decimals)).grouping(.never))
    }
}

/// A 28 pt round icon button, like the pause menu's Back button.
private struct CircleButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    init(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .frame(width: 28, height: 28)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.1), in: .circle)
        .help(title)
    }
}

private extension View {
    /// Fades out while a parameter's slider is dragged, so only that slider stays over the picture.
    func fadesWhileDragging(_ isDragging: Bool) -> some View {
        opacity(isDragging ? 0 : 1)
            .allowsHitTesting(!isDragging)
    }
}
