// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Button assignment for a gamepad read through IOKit. Edits a draft that
/// Done writes and Cancel discards (docs/DESIGN_SPEC.md, section L).
struct HIDGamepadMappingView: View {
    typealias Slot = HIDGamepadMapping.Slot

    @Environment(EmulationSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let gamepad: HIDGamepad
    /// The Settings window's height; the sheet stays 60 pt shorter.
    let windowHeight: CGFloat
    @State private var draft: HIDGamepadMapping
    @State private var listening: Slot?
    @State private var reassignment: Reassignment?

    /// The last assignment that took a control from another slot.
    private struct Reassignment: Equatable {
        let id = UUID()
        var message: String
        var mappingBefore: HIDGamepadMapping
    }

    init(gamepad: HIDGamepad, windowHeight: CGFloat) {
        self.gamepad = gamepad
        self.windowHeight = windowHeight
        _draft = State(initialValue: gamepad.mapping)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                ForEach(RetroInput.Group.allCases) { group in
                    Section(group.title) {
                        ForEach(RetroInput.allCases.filter { $0.group == group }) { input in
                            row(.input(input))
                        }
                    }
                }
                Section("System") {
                    if draft.menu == nil {
                        StatusLabel("Without a Game Menu button, open the menu with esc on the keyboard.",
                                    kind: .warning, prominent: true)
                    }
                    row(.menu)
                }
            }
            .formStyle(.grouped)
            if let reassignment {
                reassignmentRow(reassignment)
            }
            Divider()
            footer
        }
        .frame(width: 480)
        .frame(minHeight: 360, idealHeight: 500, maxHeight: max(360, windowHeight - 60))
        .presentationSizing(.fitted)
        .onDisappear(perform: stopListening)
        .task(id: reassignment?.id) {
            guard reassignment != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { reassignment = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text(gamepad.name)
                .font(.headline)
            if let level = gamepad.batteryLevel {
                Text("Battery \(level) %")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("Click an input, then press a button or move a stick.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, AppSpacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private func reassignmentRow(_ reassignment: Reassignment) -> some View {
        HStack(spacing: AppSpacing.s) {
            Text(verbatim: reassignment.message)
            Button("Undo") {
                stopListening()
                draft = reassignment.mappingBefore
                self.reassignment = nil
            }
            .buttonStyle(.link)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .padding(.horizontal, 20)
        .padding(.vertical, AppSpacing.s)
    }

    private var footer: some View {
        HStack {
            Button("Restore Defaults") {
                stopListening()
                draft = gamepad.defaultMapping
                reassignment = nil
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Done") {
                stopListening()
                gamepad.mapping = draft
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(AppSpacing.l)
    }

    private func row(_ slot: Slot) -> some View {
        LabeledContent(slot.title) {
            InputBindingButton(
                title: slot.title,
                binding: draft[slot]?.label,
                isListening: listening == slot,
                prompt: "Press a button…",
                hint: "Press to assign a new button",
                toggle: { listening == slot ? stopListening() : startListening(for: slot) },
                clear: {
                    draft[slot] = nil
                    reassignment = nil
                },
                endListening: stopListening)
        }
    }

    private func startListening(for slot: Slot) {
        listening = slot
        session.input.hid.learn(on: gamepad) { binding in
            assign(binding, to: slot)
            listening = nil
        }
    }

    private func stopListening() {
        session.input.hid.cancelLearning()
        listening = nil
    }

    private func assign(_ binding: HIDBinding, to slot: Slot) {
        let before = draft
        guard let previous = draft.assign(binding, to: slot) else {
            reassignment = nil
            return
        }
        let message = String(localized: "\(binding.label) moved from \(previous.title) to \(slot.title).")
        reassignment = Reassignment(message: message, mappingBefore: before)
        AccessibilityNotification.Announcement(message).post()
    }
}
