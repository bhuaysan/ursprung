// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Testing
@testable import Ursprung

@Suite("Input routing")
struct InputRoutingTests {
    @Test func padsHandledByGameControllerAreNotReadThroughHID() {
        // Sony, Nintendo and Microsoft pads belong to GameController.
        for vendor in [0x054C, 0x057E, 0x045E] {
            #expect(!InputRouter.isReadThroughHID(vendorID: vendor, name: "Pad", controllerNames: []))
        }
        // A pad GameController also reports under the same name is not read twice.
        #expect(!InputRouter.isReadThroughHID(vendorID: 0x2DC8, name: "8BitDo Pad", controllerNames: ["8BitDo Pad"]))
        #expect(InputRouter.isReadThroughHID(vendorID: 0x2DC8, name: "8BitDo Pad", controllerNames: ["Xbox Controller"]))
    }

    @Test func learningPadReportsNeutralStateButKeepsItsPort() {
        var held = PadState()
        held.set(.A, true)
        held.leftStick = SIMD2(1, 0)
        var other = PadState()
        other.set(.B, true)

        let states = InputRouter.hidStates([(state: held, isLearning: true), (state: other, isLearning: false)])

        #expect(states == [PadState(), other])
    }

    @Test func menuCommandsFireOncePerPress() {
        var pad = PadState()
        pad.set(.down, true)
        pad.set(.A, true)
        let held = InputRouter.menuMask(of: [pad])

        #expect(InputRouter.menuCommands(pressed: held, previous: 0) == [.down, .confirm])
        // Still held: nothing new.
        #expect(InputRouter.menuCommands(pressed: held, previous: held).isEmpty)
    }

    @Test func menuUsesTheRightFaceToConfirmAndTheBottomFaceToGoBack() {
        // Positional RetroPad mapping: bottom face = B, right face = A.
        var bottom = PadState()
        bottom.set(.B, true)
        var right = PadState()
        right.set(.A, true)

        #expect(InputRouter.menuCommands(pressed: InputRouter.menuMask(of: [bottom]), previous: 0) == [.back])
        #expect(InputRouter.menuCommands(pressed: InputRouter.menuMask(of: [right]), previous: 0) == [.confirm])
    }

    @Test func menuMergesPadsAndReadsTheLeftStickAsDPad() {
        var stick = PadState()
        stick.leftStick = SIMD2(0, -0.9)
        var other = PadState()
        other.set(.right, true)

        let mask = InputRouter.menuMask(of: [stick, other])

        #expect(InputRouter.menuCommands(pressed: mask, previous: 0) == [.up, .right])
        // A stick resting near the centre is not a press.
        var drift = PadState()
        drift.leftStick = SIMD2(0.3, 0.3)
        #expect(InputRouter.menuMask(of: [drift]) == 0)
    }
}

@Suite("Fast forward")
struct FastForwardTests {
    private func makeSession() -> EmulationSession {
        let directory = FileManager.default.temporaryDirectory.appending(path: "UrsprungTests-\(UUID().uuidString)")
        return EmulationSession(cores: CoreManager(coresDirectory: directory, systemDirectory: directory),
                                emulators: EmulatorManager(directory: directory),
                                bios: BIOSManager(systemDirectory: directory), achievements: AchievementService())
    }

    @Test func endsWhenTheAppLosesFocus() {
        let session = makeSession()
        session.setFastForward(true)

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        #expect(!session.isFastForwarding)
    }

    @Test func endsWhenThePauseMenuOpens() {
        let session = makeSession()
        session.setFastForward(true)

        session.isMenuVisible = true

        #expect(!session.isFastForwarding)
    }
}
