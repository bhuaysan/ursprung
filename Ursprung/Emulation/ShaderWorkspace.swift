// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// How the shader editor's preview shows the picture.
nonisolated struct ShaderPreviewTools: Equatable, Sendable {
    /// The part of the picture (from the left, 0…1) shown without the preset.
    var split: Double?
    /// Magnification of the finished picture, 1…8, without smoothing.
    var zoom: Double = 1
    /// The point of the picture (0…1 from the top left) the zoom centres on.
    var focus = CGPoint(x: 0.5, y: 0.5)
    /// Renders the preset for a screen of this size (pixels) instead of the
    /// view's, and scales the result into the view.
    var outputSize: CGSize?

    var changesLayout: Bool { zoom != 1 || outputSize != nil }
}

/// The RetroArch preset the player renders and its parameters, shared by the
/// renderer, the player's shader panel and the shader editor: a slider
/// changes the next frame without recompiling the preset.
@Observable
final class ShaderWorkspace {
    enum Status: Equatable {
        /// A built-in filter draws the picture.
        case builtin
        /// The preset compiles; the previous picture stays meanwhile.
        case compiling(ShaderPresetRef)
        case ready(ShaderPresetRef)
        /// The preset can't be used; the picture falls back to Sharp.
        case failed(ShaderPresetRef, String)
    }

    private(set) var status = Status.builtin
    /// The parameters of the preset in use, in declaration order.
    private(set) var parameters: [ShaderParameter] = []
    /// The current value of each parameter, by name.
    private(set) var values: [String: Float] = [:]
    /// What the preset sets each parameter to, by name.
    @ObservationIgnored private var initials: [String: Float] = [:]

    /// The shader editor's draft: shown instead of the game's choice while
    /// the editor previews on the running game.
    var editorPreset: ShaderPresetRef?
    /// The preset that is showing compiles again; it keeps showing meanwhile.
    private(set) var isRecompiling = false
    /// Why the last compile of the preset that is showing failed; the
    /// previous result keeps showing.
    private(set) var compileError: String?
    /// Bumped by every finished compile, successful or not.
    private(set) var compileCount = 0
    /// Passes of the preset that is showing.
    private(set) var passCount = 0
    var previewTools = ShaderPreviewTools()
    /// GPU time of the preset per frame, in seconds (averaged); nil without a preset.
    private(set) var gpuTime: Double?
    @ObservationIgnored private var gpuSamples: [Double] = []
    @ObservationIgnored private var gpuWindowStart: Double = 0

    /// Sends a parameter change to the renderer's chain.
    @ObservationIgnored private var apply: ((String, Float) -> Void)?
    /// Compiles the preset again, e.g. after its file was saved.
    @ObservationIgnored private var reload: (() -> Void)?

    /// The preset whose parameters are shown.
    var preset: ShaderPresetRef? {
        if case .ready(let preset) = status { preset } else { nil }
    }

    var isCompiling: Bool {
        if case .compiling = status { true } else { false }
    }

    /// Why the preset in use can't be shown, or why its last change didn't compile.
    var errorMessage: String? {
        if case .failed(_, let message) = status { message } else { compileError }
    }

    /// Whether `name` differs from what the preset sets it to.
    func isModified(_ name: String) -> Bool {
        guard let initial = initials[name], let value = values[name] else { return false }
        return Self.differs(value, initial)
    }

    /// Whether any parameter differs from the preset.
    var isModified: Bool {
        parameters.contains { parameter in values[parameter.name].map { Self.differs($0, parameter.initial) } ?? false }
    }

    private static func differs(_ a: Float, _ b: Float) -> Bool { abs(a - b) > 0.000_001 }

    // MARK: Panel

    func setValue(_ value: Float, for name: String) {
        guard initials[name] != nil, values[name] != value else { return }
        values[name] = value
        apply?(name, value)
    }

    /// Back to the value the preset sets.
    func reset(_ name: String) {
        guard let initial = initials[name] else { return }
        setValue(initial, for: name)
    }

    func resetAll() {
        for parameter in parameters where isModified(parameter.name) {
            setValue(parameter.initial, for: parameter.name)
        }
    }

    /// Reads the preset's file again; the current picture stays until it is compiled.
    func reloadPreset() {
        reload?()
    }

    /// The renderer that compiles for this workspace, so `reloadPreset()`
    /// works also after a failed compile.
    func attach(reload: @escaping () -> Void) {
        self.reload = reload
    }

    // MARK: Renderer

    /// No preset: the game ended or uses a built-in filter.
    func useBuiltin() {
        status = .builtin
        clear()
    }

    func compiling(_ preset: ShaderPresetRef) {
        status = .compiling(preset)
        isRecompiling = false
    }

    /// The preset that is showing compiles again (its files changed).
    func recompiling() {
        isRecompiling = true
    }

    /// The new compile failed; the previous one keeps showing.
    func recompileFailed(message: String) {
        isRecompiling = false
        compileError = message
        compileCount += 1
    }

    /// The renderer shows `preset` now; `apply` changes a parameter of its chain.
    func loaded(_ preset: ShaderPresetRef, parameters: [ShaderParameter], values: [String: Float], passCount: Int,
                apply: @escaping (String, Float) -> Void, reload: @escaping () -> Void) {
        status = .ready(preset)
        isRecompiling = false
        compileError = nil
        compileCount += 1
        self.passCount = passCount
        self.parameters = parameters
        self.values = values
        initials = Dictionary(parameters.map { ($0.name, $0.initial) }, uniquingKeysWith: { first, _ in first })
        self.apply = apply
        self.reload = reload
    }

    func failed(_ preset: ShaderPresetRef, message: String) {
        status = .failed(preset, message)
        compileCount += 1
        clear()
    }

    /// GPU time of one run of the preset; published averaged twice a second.
    func recordGPUTime(_ seconds: Double, at time: Double) {
        guard seconds > 0, seconds < 1 else { return }
        gpuSamples.append(seconds)
        if time - gpuWindowStart >= 0.5 {
            gpuTime = gpuSamples.reduce(0, +) / Double(gpuSamples.count)
            gpuSamples = []
            gpuWindowStart = time
        }
    }

    private func clear() {
        isRecompiling = false
        compileError = nil
        passCount = 0
        gpuTime = nil
        gpuSamples = []
        parameters = []
        values = [:]
        initials = [:]
        apply = nil
    }
}

extension ShaderParameter {
    /// Presets such as Mega Bezel declare parameters without a range as
    /// section titles.
    var isHeading: Bool { maximum <= minimum }
}
