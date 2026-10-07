// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

extension ARMSX2Controls {
    /// Ursprung's default controls on a US keyboard.
    static let standardUS = ARMSX2Controls(profile: .standard, hotkeys: .standard, rumble: true, deadZone: 0.15,
                                           keyNames: ARMSX2Keys.names(layout: [:]))
}

private func values(_ entries: [IniDocument.Entry], _ key: String) -> [String] {
    entries.filter { $0.key == key }.map(\.value)
}

@Suite("ARMSX2 controls")
struct ARMSX2ControlsTests {
    @Test func theStandardProfileBecomesPlayerOne() {
        let pad = ARMSX2Controls.standardUS.pad(player: 0)
        #expect(pad.prefix(2) == [.init("Type", "DualShock2"), .init("Deadzone", "0.15")])
        // Cross is B, the bottom face button, as for the PlayStation cores.
        #expect(values(pad, "Cross") == ["Keyboard/Z", "SDL-0/FaceSouth"])
        #expect(values(pad, "Circle") == ["Keyboard/X", "SDL-0/FaceEast"])
        #expect(values(pad, "Square") == ["Keyboard/A", "SDL-0/FaceWest"])
        #expect(values(pad, "Triangle") == ["Keyboard/S", "SDL-0/FaceNorth"])
        #expect(values(pad, "Up") == ["Keyboard/Up", "SDL-0/DPadUp"])
        #expect(values(pad, "Start") == ["Keyboard/Return", "SDL-0/Start"])
        #expect(values(pad, "Select") == ["Keyboard/Shift", "SDL-0/Back"])
        #expect(values(pad, "L2") == ["Keyboard/E", "SDL-0/+LeftTrigger"])
        #expect(values(pad, "R3") == ["Keyboard/2", "SDL-0/RightStick"])
        #expect(values(pad, "LUp") == ["Keyboard/I", "SDL-0/-LeftY"])
        #expect(values(pad, "RLeft") == ["Keyboard/F", "SDL-0/-RightX"])
        #expect(values(pad, "LargeMotor") == ["SDL-0/LargeMotor"])
        #expect(pad.count == 2 + 24 * 2 + 2)
        #expect(pad.allSatisfy { $0.key == "Type" || $0.key == "Deadzone" || ARMSX2Controls.bindingKeys.contains($0.key.lowercased()) })
    }

    @Test func playerTwoIsTheSecondController() {
        let pad = ARMSX2Controls.standardUS.pad(player: 1)
        #expect(values(pad, "Cross") == ["SDL-1/FaceSouth"])
        #expect(values(pad, "LLeft") == ["SDL-1/-LeftX"])
        #expect(!pad.contains { $0.value.hasPrefix("Keyboard/") }, "The keyboard plays as player 1 only")
    }

    @Test func followsTheProfile() {
        var controls = ARMSX2Controls.standardUS
        controls.profile.controller.setSource(.a, for: .b)   // Cross on the right face button
        controls.profile.controller.setSource(nil, for: .select)
        controls.profile.keyboard.bindings[.start] = KeyBinding(keyCode: 49, label: "Space")  // the Fast Forward key
        controls.rumble = false
        controls.deadZone = 0.3
        let pad = controls.pad(player: 0)
        #expect(values(pad, "Cross") == ["Keyboard/Z", "SDL-0/FaceEast"])
        #expect(values(pad, "Select") == ["Keyboard/Shift"])
        #expect(values(pad, "Start") == ["SDL-0/Start"], "A hotkey's key doesn't reach the game")
        #expect(values(pad, "LargeMotor").isEmpty && values(pad, "SmallMotor").isEmpty)
        #expect(values(pad, "Deadzone") == ["0.30"])
    }

    @Test func hotkeysWithACounterpart() {
        let hotkeys = ARMSX2Controls.standardUS.hotkeyEntries
        #expect(values(hotkeys, "OpenPauseMenu") == ["Keyboard/Escape", "SDL-0/Guide", "SDL-1/Guide"])
        #expect(values(hotkeys, "HoldTurbo") == ["Keyboard/Space"])
        #expect(values(hotkeys, "ToggleTurbo").isEmpty, "Fast Forward (on/off) has no key by default")
        #expect(values(hotkeys, "SaveStateToSlot1") == ["Keyboard/F2"])
        #expect(values(hotkeys, "LoadStateFromSlot1") == ["Keyboard/F4"])
        #expect(values(hotkeys, "Screenshot") == ["Keyboard/F8"])
        // ARMSX2's own hotkeys only on keys Ursprung leaves free.
        #expect(values(hotkeys, "TogglePause").isEmpty, "Space is Fast Forward")
        #expect(values(hotkeys, "ToggleFrameLimit").isEmpty, "F4 is Quick Load")
        #expect(values(hotkeys, "ToggleFullscreen").isEmpty, "Return is Start")
        #expect(values(hotkeys, "CycleAspectRatio") == ["Keyboard/F6"], "The Shader Panel key does nothing in ARMSX2")
        #expect(values(hotkeys, "Mute") == ["Keyboard/Control & Keyboard/M"])
        #expect(values(hotkeys, "SaveStateToSlot").isEmpty && values(hotkeys, "NextSaveStateSlot").isEmpty)

        var controls = ARMSX2Controls.standardUS
        controls.hotkeys.bindings[.menu] = KeyBinding(keyCode: 12, label: "Q")
        controls.hotkeys.bindings[.fastForward] = nil
        controls.profile.keyboard.bindings[.start] = KeyBinding(keyCode: 76, label: "⌤")
        #expect(values(controls.hotkeyEntries, "OpenPauseMenu") == ["Keyboard/Q", "Keyboard/Escape", "SDL-0/Guide", "SDL-1/Guide"])
        #expect(values(controls.pad(player: 0), "L1") == ["SDL-0/LeftShoulder"], "Q opens the menu now")
        #expect(values(controls.hotkeyEntries, "TogglePause") == ["Keyboard/Space"])
        #expect(values(controls.hotkeyEntries, "ToggleFullscreen") == ["Keyboard/Alt & Keyboard/Return"])
    }

    @Test func namesKeysByTheLayoutsCharacters() {
        let us = ARMSX2Keys.names(layout: [:])
        #expect(us[6] == "Z" && us[16] == "Y")
        #expect(us[27] == "Minus" && us[41] == "Semicolon" && us[50] == "QuoteLeft")
        #expect(us[65] == "NumpadPeriod" && us[82] == "Numpad0" && us[76] == "NumpadEnter")
        #expect(us[36] == "Return" && us[60] == "Shift" && us[56] == "Shift" && us[55] == "Meta" && us[59] == "Control")
        #expect(us[122] == "F1" && us[111] == "F12")

        // German: Y and Z swap, Ö has no name in ARMSX2, ^ is a dead key.
        let german: [UInt16: Character] = [6: "y", 16: "z", 41: "ö", 30: "+", 44: "-", 10: "<", 42: "#", 65: ","]
        let names = ARMSX2Keys.names(layout: german)
        #expect(names[6] == "Y" && names[16] == "Z")
        #expect(names[41] == nil)
        #expect(names[30] == "Plus" && names[44] == "Minus" && names[10] == "Less" && names[42] == "NumberSign")
        #expect(names[65] == "NumpadComma")
        #expect(names[50] == nil, "No US fallback for a key the layout doesn't type")
        #expect(names[36] == "Return")
        #expect(ARMSX2Keys.name(of: "ß") == nil)
        #expect(ARMSX2Keys.name(of: "a") == "A" && ARMSX2Keys.name(of: "7") == "7")
    }

    @Test func ursprungOwnsTheBindingsInTheIni() {
        let config = PCSX2Config(biosFolder: URL(filePath: "/b"), biosFileName: "", memoryCardFolder: URL(filePath: "/m"),
                                 saveStateFolder: URL(filePath: "/s"), snapshotFolder: URL(filePath: "/x"), pineSlot: 28011,
                                 saveStateOnShutdown: true, fullscreen: true, controls: .standardUS)
        let existing = """
            [Pad1]
            Type = DualShock2
            Analog = SDL-0/Guide
            Cross = Keyboard/K
            AxisScale = 1.5

            [Pad2]
            Type = None

            [Hotkeys]
            ResetVM = Keyboard/F12
            TogglePause = Keyboard/Space
            """
        let text = config.merged(into: existing)
        let ini = IniDocument(parsing: text)
        #expect(ini.values("Analog", in: "Pad1").isEmpty, "Bindings Ursprung doesn't make go")
        #expect(ini.values("AxisScale", in: "Pad1") == ["1.5"], "Other pad settings stay")
        #expect(ini.values("Type", in: "Pad2") == ["DualShock2"])
        #expect(ini.values("ResetVM", in: "Hotkeys").isEmpty)
        #expect(ini.values("TogglePause", in: "Hotkeys").isEmpty)
        #expect(config.merged(into: text) == text)
    }
}
