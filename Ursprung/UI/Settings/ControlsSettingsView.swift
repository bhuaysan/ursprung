// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import GameController
import SwiftUI

struct ControlsSettingsView: View {
    @Environment(EmulationSession.self) private var session
    @State private var mapping = KeyboardMapping.current
    @State private var listening: RetroInput?
    @State private var monitor: Any?
    @State private var configuring: HIDGamepad?

    var body: some View {
        Form {
            Section("Game Controllers") {
                let controllers = session.input.connectedControllers
                let xinputPads = session.input.xinput.gamepads
                let gamepads = session.input.hidGamepads
                if controllers.isEmpty && xinputPads.isEmpty && gamepads.isEmpty {
                    Text("No controller connected. Pair a controller in System Settings → Bluetooth or connect it via USB.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(controllers.enumerated()), id: \.offset) { index, controller in
                        LabeledContent(controller.vendorName ?? String(localized: "Controller")) {
                            Text("Player \(index + 1)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(xinputPads.enumerated()), id: \.element.id) { index, gamepad in
                        LabeledContent(gamepad.name) {
                            Text("Player \(controllers.count + index + 1)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(gamepads.enumerated()), id: \.element.id) { index, gamepad in
                        LabeledContent {
                            HStack {
                                Text("Player \(controllers.count + xinputPads.count + index + 1)")
                                    .foregroundStyle(.secondary)
                                Button("Configure…") { configuring = gamepad }
                            }
                        } label: {
                            Text(gamepad.name)
                            if let level = gamepad.batteryLevel {
                                Text("Battery \(level) %")
                            }
                        }
                    }
                }
                Text("Controllers are mapped by button position: the bottom face button is B, the right one is A — like on a Super Nintendo pad. The Home button opens the game menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !gamepads.isEmpty {
                    Text("Some controllers are not supported by macOS directly. Ursprung reads them itself and guesses their layout — if a button is wrong, change it with Configure….")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(RetroInput.Group.allCases) { group in
                Section(group.title) {
                    ForEach(RetroInput.allCases.filter { $0.group == group }) { input in
                        LabeledContent(input.title) {
                            Button {
                                startListening(for: input)
                            } label: {
                                Text(listening == input ? String(localized: "Press a key…") : (mapping.bindings[input]?.label ?? "–"))
                                    .frame(minWidth: 90)
                                    .monospaced()
                            }
                            .buttonStyle(.bordered)
                            .tint(listening == input ? .accentColor : nil)
                        }
                    }
                }
            }

            Section {
                LabeledContent("Game menu", value: "esc")
                LabeledContent("Fast forward (hold)", value: String(localized: "Space"))
                LabeledContent("Quick save / load", value: "F2 / F4")
                Button("Restore Default Keys") {
                    mapping = .standard
                    save()
                }
            } header: {
                Text("Keyboard Shortcuts")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $configuring) { gamepad in
            HIDGamepadMappingView(gamepad: gamepad)
        }
        .onDisappear(perform: stopListening)
    }

    private func startListening(for input: RetroInput) {
        stopListening()
        listening = input
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard let target = listening else { return event }
            if event.type == .keyDown, event.keyCode == HotKey.escape {
                stopListening()
                return nil
            }
            if event.type == .flagsChanged, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                return nil // modifier released
            }
            mapping.bindings[target] = KeyBinding(keyCode: event.keyCode, label: Self.label(for: event))
            save()
            stopListening()
            return nil
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = nil
    }

    private func save() {
        KeyboardMapping.current = mapping
        session.input.reloadMapping()
    }

    private static let specialKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "esc", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        56: "⇧ left", 60: "⇧ right", 59: "⌃ left", 62: "⌃ right", 58: "⌥ left", 61: "⌥ right",
        55: "⌘ left", 54: "⌘ right", 57: "⇪",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static func label(for event: NSEvent) -> String {
        if let special = specialKeys[event.keyCode] { return special }
        if event.type == .keyDown, let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return characters.uppercased()
        }
        return "#\(event.keyCode)"
    }
}
