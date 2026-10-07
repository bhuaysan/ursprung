// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// An ini file the way ARMSX2 reads and writes it (SimpleIni): sections in
/// order, each an ordered list of entries in which a key may repeat — one
/// line per binding when a button has several (docs/STANDALONE_PLAN.md, S7).
/// Section names and keys are compared without regard to case, like SimpleIni.
nonisolated struct IniDocument: Equatable, Sendable {
    nonisolated struct Entry: Equatable, Sendable {
        var key: String
        var value: String

        init(_ key: String, _ value: String) {
            self.key = key
            self.value = value
        }
    }

    nonisolated struct Section: Equatable, Sendable {
        var name: String
        var entries: [Entry]
    }

    private(set) var sections: [Section] = []

    init(parsing text: String = "") {
        var current: Int?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if index(of: name) == nil { sections.append(Section(name: name, entries: [])) }
                current = index(of: name)
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let entry = Entry(line[..<equals].trimmingCharacters(in: .whitespaces),
                              line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
            if current == nil {
                // Keys before the first section belong to an unnamed one.
                sections.insert(Section(name: "", entries: []), at: 0)
                current = 0
            }
            sections[current!].entries.append(entry)
        }
    }

    func values(_ key: String, in section: String) -> [String] {
        guard let index = index(of: section) else { return [] }
        return sections[index].entries.filter { Self.same($0.key, key) }.map(\.value)
    }

    /// Replaces every value of the keys in `entries` within `section`. The
    /// new values of a key take the place of its first old one, keys the
    /// section did not have go to its end; other keys stay as they are.
    mutating func set(_ entries: [Entry], in section: String) {
        if index(of: section) == nil { sections.append(Section(name: section, entries: [])) }
        guard let index = index(of: section) else { return }
        var pending: [(key: String, values: [Entry])] = []
        for entry in entries {
            if let position = pending.firstIndex(where: { Self.same($0.key, entry.key) }) {
                pending[position].values.append(entry)
            } else {
                pending.append((entry.key, [entry]))
            }
        }
        var merged: [Entry] = []
        var written = Set<String>()
        for entry in sections[index].entries {
            guard let managed = pending.first(where: { Self.same($0.key, entry.key) }) else {
                merged.append(entry)
                continue
            }
            if written.insert(managed.key.lowercased()).inserted { merged += managed.values }
        }
        for managed in pending where !written.contains(managed.key.lowercased()) {
            merged += managed.values
        }
        sections[index].entries = merged
    }

    var text: String {
        sections.map { section in
            let header = section.name.isEmpty ? [] : ["[\(section.name)]"]
            return (header + section.entries.map { "\($0.key) = \($0.value)" }).joined(separator: "\n") + "\n"
        }.joined(separator: "\n")
    }

    private func index(of section: String) -> Int? {
        sections.firstIndex { Self.same($0.name, section) }
    }

    private static func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}

/// The settings Ursprung writes into ARMSX2's `PCSX2.ini` before every launch
/// (docs/STANDALONE_PLAN.md, "Configuration"). Keys it does not manage stay as
/// they are, so changes made in ARMSX2's own settings survive.
nonisolated struct PCSX2Config: Equatable, Sendable {
    var biosFolder: URL
    /// A dump in `biosFolder`; without one ARMSX2 picks any dump itself.
    var biosFileName: String
    var memoryCardFolder: URL
    var saveStateFolder: URL
    var snapshotFolder: URL
    var pineSlot: Int
    /// ARMSX2 writes `<serial> (<CRC>).resume.p2s` when Ursprung quits it.
    var saveStateOnShutdown: Bool
    var fullscreen: Bool

    /// The single memory card of a game (slot 2 stays empty).
    static let memoryCardFileName = "Mcd001.ps2"
    /// The Metal renderer. OpenGL (12) cannot create a device on macOS and
    /// crashes ARMSX2 with an error dialog (S5).
    static let metalRenderer = "17"

    /// Managed entries per section, in the order a new file gets them.
    var sections: [(name: String, entries: [IniDocument.Entry])] {
        typealias E = IniDocument.Entry
        return [
            ("UI", [
                // Without these two ARMSX2 shows its setup wizard.
                E("SettingsVersion", "1"),
                E("SetupWizardIncomplete", "false"),
                // A confirmation is a dialog, and dialogs crash ARMSX2 on macOS 27 (S5).
                E("ConfirmShutdown", "false"),
                E("StartFullscreen", Self.bool(fullscreen)),
                E("HideMouseCursor", "true"),
            ]),
            ("AutoUpdater", [E("CheckAtStartup", "false")]),
            ("Folders", [
                E("Bios", biosFolder.path(percentEncoded: false)),
                E("MemoryCards", memoryCardFolder.path(percentEncoded: false)),
                E("Savestates", saveStateFolder.path(percentEncoded: false)),
                E("Snapshots", snapshotFolder.path(percentEncoded: false)),
            ]),
            ("Filenames", [E("BIOS", biosFileName)]),
            ("MemoryCards", [
                E("Slot1_Enable", "true"),
                E("Slot1_Filename", Self.memoryCardFileName),
                E("Slot2_Enable", "false"),
            ]),
            ("EmuCore", [
                E("EnableFastBoot", "true"),
                E("EnablePINE", "true"),
                E("PINESlot", String(pineSlot)),
                E("SaveStateOnShutdown", Self.bool(saveStateOnShutdown)),
                // Ursprung keeps replaced states itself.
                E("BackupSavestate", "false"),
            ]),
            ("EmuCore/GS", [E("Renderer", Self.metalRenderer)]),
            ("InputSources", [
                E("Keyboard", "true"),
                E("Mouse", "true"),
                E("SDL", "true"),
                E("SDLControllerEnhancedMode", "true"),
            ]),
            ("Pad1", Self.padBindings),
            ("Hotkeys", Self.hotkeys),
        ]
    }

    /// `existing` with every managed key set; a fresh file when it is empty.
    func merged(into existing: String) -> String {
        var document = IniDocument(parsing: existing)
        for section in sections {
            document.set(section.entries, in: section.name)
        }
        return document.text
    }

    /// Writes `inis/PCSX2.ini` below ARMSX2's data folder (`-datapath`).
    func write(dataFolder: URL) throws {
        let url = Self.iniURL(dataFolder: dataFolder)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try merged(into: existing).write(to: url, atomically: true, encoding: .utf8)
    }

    /// ARMSX2 keeps everything in an `ARMSX2` folder below `-datapath`.
    static func iniURL(dataFolder: URL) -> URL {
        dataFolder.appending(path: "ARMSX2/inis/PCSX2.ini")
    }

    private static func bool(_ value: Bool) -> String { value ? "true" : "false" }

    /// ARMSX2's default keyboard map plus the first SDL controller, as its
    /// setup wizard and automatic mapping would write them (S7). Phase 6
    /// replaces these with the input profile.
    static let padBindings: [IniDocument.Entry] = {
        let buttons: [(String, keyboard: String?, controller: String)] = [
            ("Up", "Up", "DPadUp"), ("Right", "Right", "DPadRight"), ("Down", "Down", "DPadDown"), ("Left", "Left", "DPadLeft"),
            ("Triangle", "I", "FaceNorth"), ("Circle", "L", "FaceEast"), ("Cross", "K", "FaceSouth"), ("Square", "J", "FaceWest"),
            ("Select", "Backspace", "Back"), ("Start", "Return", "Start"),
            ("L1", "Q", "LeftShoulder"), ("L2", "1", "+LeftTrigger"), ("R1", "E", "RightShoulder"), ("R2", "3", "+RightTrigger"),
            ("L3", "2", "LeftStick"), ("R3", "4", "RightStick"),
            ("LUp", "W", "-LeftY"), ("LRight", "D", "+LeftX"), ("LDown", "S", "+LeftY"), ("LLeft", "A", "-LeftX"),
            ("RUp", "T", "-RightY"), ("RRight", "H", "+RightX"), ("RDown", "G", "+RightY"), ("RLeft", "F", "-RightX"),
            ("LargeMotor", nil, "LargeMotor"), ("SmallMotor", nil, "SmallMotor"),
        ]
        var entries = [IniDocument.Entry("Type", "DualShock2")]
        for (button, keyboard, controller) in buttons {
            if let keyboard { entries.append(.init(button, "Keyboard/\(keyboard)")) }
            entries.append(.init(button, "SDL-0/\(controller)"))
        }
        return entries
    }()

    /// ARMSX2's default hotkeys; without them not even Escape opens its menu.
    static let hotkeys: [IniDocument.Entry] = [
        ("ToggleFullscreen", "Keyboard/Alt & Keyboard/Return"),
        ("CycleAspectRatio", "Keyboard/F6"),
        ("CycleInterlaceMode", "Keyboard/F5"),
        ("ToggleMipmapMode", "Keyboard/Insert"),
        ("Screenshot", "Keyboard/F8"),
        ("ToggleSoftwareRendering", "Keyboard/F9"),
        ("ToggleOSD", "Keyboard/F10"),
        ("ZoomIn", "Keyboard/Control & Keyboard/Plus"),
        ("ZoomOut", "Keyboard/Control & Keyboard/Minus"),
        ("Mute", "Keyboard/Control & Keyboard/M"),
        ("LoadStateFromSlot", "Keyboard/F3"),
        ("SaveStateToSlot", "Keyboard/F1"),
        ("NextSaveStateSlot", "Keyboard/F2"),
        ("PreviousSaveStateSlot", "Keyboard/Shift & Keyboard/F2"),
        ("OpenPauseMenu", "Keyboard/Escape"),
        ("ToggleFrameLimit", "Keyboard/F4"),
        ("TogglePause", "Keyboard/Space"),
        ("ToggleSlowMotion", "Keyboard/Shift & Keyboard/Backtab"),
        ("ToggleTurbo", "Keyboard/Tab"),
        ("HoldTurbo", "Keyboard/Period"),
    ].map { IniDocument.Entry($0.0, $0.1) }
}
