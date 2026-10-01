// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// The button that shows and learns one input binding, shared by the
/// keyboard mapping in Controls and the gamepad mapping sheet
/// (docs/DESIGN_SPEC.md, section L). The host owns the listening state and
/// receives the input; this view only ends listening on Esc or a click
/// anywhere outside it.
struct InputBindingButton: View {
    /// The input's name, for VoiceOver.
    let title: String
    /// The current binding, nil when unassigned.
    let binding: String?
    let isListening: Bool
    /// Shown while listening, e.g. “Press a key…”.
    let prompt: LocalizedStringKey
    /// VoiceOver hint, e.g. “Press to assign a new key”.
    let hint: LocalizedStringKey
    /// Click on the button: starts listening, or ends it when it is listening.
    let toggle: () -> Void
    let clear: () -> Void
    let endListening: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            Button(action: toggle) {
                Group {
                    if isListening {
                        Label(prompt, systemImage: "dot.radiowaves.left.and.right")
                    } else if let binding {
                        Text(verbatim: binding).monospaced()
                    } else {
                        Text("Not Assigned").foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 120)
            }
            .buttonStyle(.bordered)
            .tint(isListening ? .accentColor : nil)
            .background {
                if isListening { ListeningMonitor(end: endListening) }
            }
            .onDeleteCommand {
                if binding != nil, !isListening { clear() }
            }
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityValue(isListening ? Text("Waiting for input") : binding.map { Text(verbatim: $0) } ?? Text("Not Assigned"))
            .accessibilityHint(hint)

            let canClear = binding != nil && !isListening
            Button(action: clear) {
                Label("Clear", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24) // pointer target
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .help("Clear")
            // Keeps its room when hidden, so the binding buttons line up.
            .opacity(canClear ? 1 : 0)
            .disabled(!canClear)
            .accessibilityHidden(!canClear)
        }
        .onChange(of: isListening) { _, listening in
            if listening { AccessibilityNotification.Announcement(String(localized: "Waiting for input")).post() }
        }
    }
}

/// Ends listening on Esc or on a click outside the button it backs. The
/// click still goes through, so clicking another binding button starts
/// listening there; a click on the button itself is left to its action.
private struct ListeningMonitor: NSViewRepresentable {
    let end: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.end = end
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stop()
    }

    final class MonitorView: NSView {
        var end: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self else { return event }
                switch event.type {
                case .keyDown where event.keyCode == HotKey.escape:
                    // Only the listening ends, not the sheet around it.
                    end?()
                    return nil
                case .leftMouseDown, .rightMouseDown:
                    let isInside = event.window === window && bounds.contains(convert(event.locationInWindow, from: nil))
                    if !isInside { end?() }
                    return event
                default:
                    return event
                }
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
