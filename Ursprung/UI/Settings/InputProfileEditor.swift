// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Form sections that edit an `InputProfile`: the keyboard layout and the
/// controller button layout. Used in Settings › Controls (for all systems or
/// one system) and in a game's controls sheet.
struct InputProfileEditor: View {
    @Binding var profile: InputProfile
    @Environment(EmulationSession.self) private var session
    @State private var listening: Listening?
    @State private var monitor: Any?

    private enum Listening: Equatable {
        case key(RetroInput)
        case button(RetroInput)
    }

    var body: some View {
        Group {
            Section {
                ForEach(ControllerMapping.buttons) { target in
                    LabeledContent(target.title) {
                        InputBindingButton(
                            title: target.title,
                            binding: profile.controller.source(for: target).map(\.controllerLabel),
                            isListening: listening == .button(target),
                            prompt: "Press a button…",
                            hint: "Press to assign a controller button",
                            toggle: { listening == .button(target) ? stopListening() : listenForButton(target) },
                            clear: { profile.controller.setSource(nil, for: target) },
                            endListening: stopListening)
                    }
                }
                HStack {
                    Spacer()
                    Button("Restore Default Buttons") {
                        stopListening()
                        profile.controller = .standard
                    }
                    .disabled(profile.controller.isStandard)
                }
            } header: {
                Text("Controller Buttons")
            } footer: {
                Text("Applies to every controller. Buttons are named by position, like on a Super Nintendo pad: the bottom face button is B.")
                    .settingsFootnote()
            }

            Section {
                HStack {
                    Text("Click an input, then press a key.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Default Keys") {
                        stopListening()
                        profile.keyboard = .standard
                    }
                    .disabled(profile.keyboard == .standard)
                }
            } header: {
                Text("Keyboard")
            } footer: {
                let shadowed = shadowedKeys
                if !shadowed.isEmpty {
                    // Hotkeys win over the game's keys.
                    StatusLabel("Also a hotkey: \(shadowed.formatted(.list(type: .and)))", kind: .warning,
                                detail: String(localized: "The game doesn't receive these keys. Choose other keys, or change the hotkeys above."))
                }
            }
            ForEach(RetroInput.Group.allCases) { group in
                Section(group.title) {
                    ForEach(RetroInput.allCases.filter { $0.group == group }) { input in
                        LabeledContent(input.title) {
                            InputBindingButton(
                                title: input.title,
                                binding: profile.keyboard.bindings[input]?.label,
                                isListening: listening == .key(input),
                                prompt: "Press a key…",
                                hint: "Press to assign a new key",
                                toggle: { listening == .key(input) ? stopListening() : listenForKey(input) },
                                clear: { profile.keyboard.bindings[input] = nil },
                                endListening: stopListening)
                        }
                    }
                }
            }
        }
        .onDisappear(perform: stopListening)
    }

    /// Keys of this layout that a hotkey takes for itself.
    private var shadowedKeys: [String] {
        let hotkeys = session.input.hotkeys
        let labels = profile.keyboard.bindings.values
            .filter { hotkeys.action(forKeyCode: $0.keyCode) != nil }
            .map(\.label)
        return Array(Set(labels)).sorted()
    }

    private func listenForButton(_ target: RetroInput) {
        stopListening()
        listening = .button(target)
        session.input.learnControllerButton { source in
            profile.controller.setSource(source, for: target)
            listening = nil
        }
    }

    private func listenForKey(_ input: RetroInput) {
        stopListening()
        listening = .key(input)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard case .key(let target) = listening else { return event }
            if event.type == .keyDown, event.keyCode == HotKey.escape {
                stopListening()
                return nil
            }
            if event.type == .flagsChanged, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                return nil // modifier released
            }
            profile.keyboard.bindings[target] = KeyBinding(keyCode: event.keyCode, label: KeyLabel.label(for: event))
            stopListening()
            return nil
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        session.input.cancelControllerLearning()
        listening = nil
    }
}

extension RetroInput {
    /// The short name of a controller button by position.
    var controllerLabel: String {
        switch self {
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        default: title
        }
    }
}

/// Names for keys as the Controls settings show them.
enum KeyLabel {
    private static let specialKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "esc", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        56: "⇧ left", 60: "⇧ right", 59: "⌃ left", 62: "⌃ right", 58: "⌥ left", 61: "⌥ right",
        55: "⌘ left", 54: "⌘ right", 57: "⇪",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    static func label(for event: NSEvent) -> String {
        if let special = specialKeys[event.keyCode] { return special }
        if event.type == .keyDown, let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return characters.uppercased()
        }
        return "#\(event.keyCode)"
    }
}
