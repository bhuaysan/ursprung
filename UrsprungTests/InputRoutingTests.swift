// SPDX-License-Identifier: GPL-3.0-or-later

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
}
