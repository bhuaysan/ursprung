// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import GameController
import SwiftUI

struct ControlsSettingsView: View {
    @Environment(EmulationSession.self) private var session
    @AppStorage(PrefKey.stickDeadZone) private var deadZone = 0.15
    @State private var configuring: HIDGamepad?
    @State private var windowHeight: CGFloat = 560
    @State private var hotkeys = HotkeyMapping.current
    @State private var listeningHotkey: HotkeyAction?
    @State private var hotkeyMonitor: Any?
    /// nil edits the controls for all systems.
    @State private var scope: String?
    @State private var profile = InputProfile.global
    @State private var hasOwnProfile = false

    var body: some View {
        Form {
            controllersSection
            Section {
                LabeledContent("Stick Dead Zone") {
                    HStack {
                        Slider(value: $deadZone, in: 0...0.4)
                            .frame(maxWidth: 200)
                            .accessibilityValue(Text(deadZone.formatted(.percent.precision(.fractionLength(0)))))
                        Text(deadZone.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .onChange(of: deadZone) { session.input.reloadSettings() }
                InputTestView()
            } header: {
                Text("Test")
            } footer: {
                Text("Press buttons or keys to see what the game receives. Raise the dead zone if a stick moves on its own.")
                    .settingsFootnote()
            }
            hotkeysSection
            profileSection
            if scope == nil || hasOwnProfile {
                InputProfileEditor(profile: $profile)
            }
        }
        .formStyle(.grouped)
        .background { WindowSizeReader { windowHeight = $0.height } }
        .sheet(item: $configuring) { gamepad in
            HIDGamepadMappingView(gamepad: gamepad, windowHeight: windowHeight)
        }
        .onChange(of: scope) { load() }
        .onChange(of: profile) { save() }
        .onChange(of: hasOwnProfile) { save() }
        .onDisappear(perform: stopListeningHotkey)
    }

    // MARK: Controllers

    private var controllersSection: some View {
        Section {
            let controllers = session.input.controllers
            if controllers.isEmpty {
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("No Controller Connected")
                    Text("Pair a controller in System Settings → Bluetooth or connect it via USB.")
                }
            } else {
                ForEach(controllers) { controller in
                    LabeledContent {
                        HStack {
                            if let gamepad = controller.hidGamepad {
                                Button("Configure…") { configuring = gamepad }
                            }
                            Picker("Player", selection: Binding(
                                get: { controller.fixedPort },
                                set: { session.input.setFixedPort($0, for: controller.id) }
                            )) {
                                Text(controller.port.map { String(localized: "Automatic (Player \($0 + 1))") }
                                     ?? String(localized: "Automatic"))
                                    .tag(Int?.none)
                                Divider()
                                ForEach(0..<Int(URMaxPorts), id: \.self) { port in
                                    Text("Player \(port + 1)").tag(Optional(port))
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    } label: {
                        Text(controller.name)
                        if let level = controller.batteryLevel {
                            Text("Battery \(level) %")
                        }
                    }
                }
            }
        } header: {
            Text("Game Controllers")
        } footer: {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Choose a player for a controller to keep it there when it reconnects. The keyboard always plays as player 1. The Home button opens the game menu.")
                if !session.input.hidGamepads.isEmpty {
                    Text("Some controllers are not supported by macOS directly. Ursprung reads them itself and guesses their layout — if a button is wrong, change it with Configure….")
                }
            }
            .settingsFootnote()
        }
    }

    // MARK: Hotkeys

    private var hotkeysSection: some View {
        Section {
            ForEach(HotkeyAction.allCases) { action in
                LabeledContent(action.title) {
                    InputBindingButton(
                        title: action.title,
                        binding: hotkeys.bindings[action]?.label,
                        isListening: listeningHotkey == action,
                        prompt: "Press a key…",
                        hint: "Press to assign a new key",
                        toggle: { listeningHotkey == action ? stopListeningHotkey() : listenForHotkey(action) },
                        clear: {
                            hotkeys.bindings[action] = nil
                            saveHotkeys()
                        },
                        endListening: stopListeningHotkey)
                }
            }
            HStack {
                Spacer()
                Button("Restore Default Hotkeys") {
                    stopListeningHotkey()
                    hotkeys = .standard
                    saveHotkeys()
                }
                .disabled(hotkeys == .standard)
            }
        } header: {
            Text("Hotkeys")
        } footer: {
            Text("Keys that control the player rather than the game. esc always opens the game menu too.")
                .settingsFootnote()
        }
    }

    private func listenForHotkey(_ action: HotkeyAction) {
        stopListeningHotkey()
        listeningHotkey = action
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard let target = listeningHotkey else { return event }
            if event.keyCode == HotKey.escape, target != .menu {
                stopListeningHotkey()
                return nil
            }
            // A key does one thing: it leaves any other hotkey.
            for (other, binding) in hotkeys.bindings where binding.keyCode == event.keyCode { hotkeys.bindings[other] = nil }
            hotkeys.bindings[target] = KeyBinding(keyCode: event.keyCode, label: KeyLabel.label(for: event))
            saveHotkeys()
            stopListeningHotkey()
            return nil
        }
    }

    private func stopListeningHotkey() {
        if let hotkeyMonitor { NSEvent.removeMonitor(hotkeyMonitor) }
        hotkeyMonitor = nil
        listeningHotkey = nil
    }

    private func saveHotkeys() {
        HotkeyMapping.current = hotkeys
        session.input.reloadSettings()
    }

    // MARK: Profiles

    private var profileSection: some View {
        Section {
            Picker("Controls For", selection: $scope) {
                Text("All Systems").tag(String?.none)
                Divider()
                ForEach(SystemCatalog.all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { system in
                    Text(system.name).tag(Optional(system.id))
                }
            }
            if let scope, let system = SystemCatalog.system(withID: scope) {
                Toggle(isOn: $hasOwnProfile) {
                    Text("Separate Controls for \(system.name)")
                    Text("Otherwise this system uses the controls for all systems.")
                }
            }
        } header: {
            Text("Layout")
        } footer: {
            Text("A game can have its own controls too: open its inspector and choose Controls › Edit….")
                .settingsFootnote()
        }
    }

    private func load() {
        if let scope {
            let own = InputProfile.system(scope)
            hasOwnProfile = own != nil
            profile = own ?? .global
        } else {
            hasOwnProfile = false
            profile = .global
        }
    }

    private func save() {
        if let scope {
            InputProfile.setSystem(hasOwnProfile ? profile : nil, for: scope)
        } else {
            InputProfile.global = profile
        }
        // A running game keeps the controls it started with.
        if !session.isActive { session.input.reloadMapping() }
    }
}

/// What each player sends to the game right now: pressed buttons and stick
/// positions, after remapping and the dead zone.
struct InputTestView: View {
    @Environment(EmulationSession.self) private var session
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            ForEach(0..<Int(URMaxPorts), id: \.self) { port in
                let state = session.input.livePorts[port]
                LabeledContent("Player \(port + 1)") {
                    Text(verbatim: Self.describe(state))
                        .monospaced()
                        .foregroundStyle(state == PadState() ? .secondary : .primary)
                        .lineLimit(1)
                }
            }
        }
        .onAppear {
            session.input.isMonitoring = true
            // Keys reach the test without being taken from the window.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                // A running game would receive the keys too.
                guard !session.isActive else { return event }
                if event.type == .keyDown, !event.isARepeat { session.input.keyDown(event.keyCode) }
                if event.type == .keyUp { session.input.keyUp(event.keyCode) }
                return event
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            session.input.reset()
            session.input.isMonitoring = false
        }
    }

    static func describe(_ state: PadState) -> String {
        let buttons = ControllerMapping.buttons.filter { input in
            input.button.map { state.buttonMask & (1 << UInt32($0.rawValue)) != 0 } ?? false
        }.map(\.title)
        var parts = buttons
        for (name, stick) in [("L", state.leftStick), ("R", state.rightStick)] where stick != .zero {
            parts.append(String(format: "%@(%.2f, %.2f)", name, stick.x, stick.y))
        }
        return parts.isEmpty ? "–" : parts.joined(separator: " ")
    }
}
