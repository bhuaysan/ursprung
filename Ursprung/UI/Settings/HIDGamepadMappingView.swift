// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Button assignment for a gamepad read through IOKit.
struct HIDGamepadMappingView: View {
    @Environment(EmulationSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let gamepad: HIDGamepad
    @State private var listening: Target?

    private enum Target: Hashable {
        case input(RetroInput)
        case menu
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("Click an input, then press the button or move the stick on the controller.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text(gamepad.name)
                }
                ForEach(RetroInput.Group.allCases) { group in
                    Section(group.title) {
                        ForEach(RetroInput.allCases.filter { $0.group == group }) { input in
                            row(input.title, target: .input(input), binding: gamepad.mapping.bindings[input])
                        }
                    }
                }
                Section {
                    row(String(localized: "Game menu"), target: .menu, binding: gamepad.mapping.menu)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Restore Defaults") {
                    stopListening()
                    gamepad.mapping = gamepad.defaultMapping
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460, height: 600)
        .onDisappear(perform: stopListening)
    }

    private func row(_ title: String, target: Target, binding: HIDBinding?) -> some View {
        LabeledContent(title) {
            Button {
                if listening == target { stopListening() } else { startListening(for: target) }
            } label: {
                Text(listening == target ? String(localized: "Press a button…") : (binding?.label ?? "–"))
                    .frame(minWidth: 110)
                    .monospaced()
            }
            .buttonStyle(.bordered)
            .tint(listening == target ? .accentColor : nil)
        }
    }

    private func startListening(for target: Target) {
        listening = target
        session.input.hid.learn(on: gamepad) { binding in
            assign(binding, to: target)
            listening = nil
        }
    }

    private func stopListening() {
        session.input.hid.cancelLearning()
        listening = nil
    }

    private func assign(_ binding: HIDBinding, to target: Target) {
        var mapping = gamepad.mapping
        // One control drives one input, so reassigning moves it.
        for (input, existing) in mapping.bindings where existing == binding {
            mapping.bindings[input] = nil
        }
        if mapping.menu == binding { mapping.menu = nil }
        switch target {
        case .input(let input): mapping.bindings[input] = binding
        case .menu: mapping.menu = binding
        }
        gamepad.mapping = mapping
    }
}
