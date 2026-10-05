// SPDX-License-Identifier: GPL-3.0-or-later

import CoreHaptics
import Foundation
import GameController

/// The two motors of a rumbling pad, 0…1 each, as a core sets them.
nonisolated struct RumbleState: Equatable, Sendable {
    var strong: Float = 0
    var weak: Float = 0

    var isOff: Bool { strong == 0 && weak == 0 }

    /// One intensity for pads with a single actuator: the strong motor
    /// counts fully, the weak one somewhat less.
    var combined: Float { min(1, max(strong, weak * 0.7)) }
}

/// Plays a core's rumble on a GameController pad. Pads with haptics in both
/// handles get the strong motor left and the weak one right, like the
/// original hardware; others get one combined intensity.
final class HapticRumble {
    private var players: [(engine: CHHapticEngine, player: CHHapticAdvancedPatternPlayer, isStrong: Bool?)] = []
    private var isPlaying = false
    private var failed = false

    init(controller: GCController) {
        guard let haptics = controller.haptics else {
            failed = true
            return
        }
        let localities = haptics.supportedLocalities
        let split = localities.contains(.leftHandle) && localities.contains(.rightHandle)
        let targets: [(GCHapticsLocality, Bool?)] = split ? [(.leftHandle, true), (.rightHandle, false)] : [(.default, nil)]
        for (locality, isStrong) in targets {
            guard let engine = haptics.createEngine(withLocality: locality),
                  let player = try? Self.makePlayer(engine) else { continue }
            players.append((engine, player, isStrong))
        }
        failed = players.isEmpty
    }

    /// A continuous vibration whose strength is set while it plays.
    private static func makePlayer(_ engine: CHHapticEngine) throws -> CHHapticAdvancedPatternPlayer {
        engine.isAutoShutdownEnabled = false
        try engine.start()
        let event = CHHapticEvent(eventType: .hapticContinuous,
                                  parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                               CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)],
                                  relativeTime: 0, duration: 30)
        let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
        player.loopEnabled = true
        return player
    }

    func apply(_ state: RumbleState) {
        guard !failed else { return }
        if state.isOff {
            guard isPlaying else { return }
            for entry in players { try? entry.player.stop(atTime: CHHapticTimeImmediate) }
            isPlaying = false
            return
        }
        for entry in players {
            let intensity = switch entry.isStrong {
            case true?: state.strong
            case false?: state.weak
            case nil: state.combined
            }
            if !isPlaying { try? entry.player.start(atTime: CHHapticTimeImmediate) }
            try? entry.player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                                                        value: intensity, relativeTime: 0)],
                                             atTime: CHHapticTimeImmediate)
        }
        isPlaying = true
    }

    func stop() {
        apply(RumbleState())
        for entry in players { entry.engine.stop() }
        players = []
        failed = true
    }
}
