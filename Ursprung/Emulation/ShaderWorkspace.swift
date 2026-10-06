// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// The RetroArch preset the player renders and its parameters, shared by the
/// renderer and the player's shader panel: a slider changes the next frame
/// without recompiling the preset.
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

    // MARK: Renderer

    /// No preset: the game ended or uses a built-in filter.
    func useBuiltin() {
        status = .builtin
        clear()
    }

    func compiling(_ preset: ShaderPresetRef) {
        status = .compiling(preset)
    }

    /// The renderer shows `preset` now; `apply` changes a parameter of its chain.
    func loaded(_ preset: ShaderPresetRef, parameters: [ShaderParameter], values: [String: Float],
                apply: @escaping (String, Float) -> Void, reload: @escaping () -> Void) {
        status = .ready(preset)
        self.parameters = parameters
        self.values = values
        initials = Dictionary(parameters.map { ($0.name, $0.initial) }, uniquingKeysWith: { first, _ in first })
        self.apply = apply
        self.reload = reload
    }

    func failed(_ preset: ShaderPresetRef, message: String) {
        status = .failed(preset, message)
        clear()
    }

    private func clear() {
        parameters = []
        values = [:]
        initials = [:]
        apply = nil
        reload = nil
    }
}

extension ShaderParameter {
    /// Presets such as Mega Bezel declare parameters without a range as
    /// section titles.
    var isHeading: Bool { maximum <= minimum }
}
