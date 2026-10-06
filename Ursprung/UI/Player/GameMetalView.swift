// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import MetalKit
import SwiftUI

/// SwiftUI wrapper for the Metal view that shows the emulator output and
/// receives keyboard and mouse input.
struct GameMetalView: NSViewRepresentable {
    let session: EmulationSession
    let selection: ShaderSelection
    let integerScaling: Bool
    let bezel: BezelStyle
    let bezelImage: URL?

    func makeNSView(context: Context) -> GameMTKView {
        let view = GameMTKView(frame: .zero, device: nil)
        view.session = session
        view.renderer = MetalRenderer(view: view)
        view.renderer?.workspace = session.shader
        view.renderer?.onShaderError = { [weak session] message in
            session?.showToast(message, kind: .warning, duration: 5)
        }
        #if DEBUG
        view.renderer?.debugSnapshotName = "shader-output"
        #endif
        return view
    }

    func updateNSView(_ view: GameMTKView, context: Context) {
        view.renderer?.source = session.core
        view.renderer?.selection = selection
        view.renderer?.integerScaling = integerScaling
        view.renderer?.bezel = bezel
        view.renderer?.bezelImageURL = bezelImage
        view.renderer?.isRewinding = session.isRewinding
        // With the shader panel open, keys reach the game until a field in
        // the panel is clicked; clicking the game gives them back.
        if session.phase == .running, !session.isMenuVisible, !session.isShaderPanelVisible {
            view.window?.makeFirstResponder(view)
        }
    }
}

final class GameMTKView: MTKView {
    weak var session: EmulationSession?
    var renderer: MetalRenderer?

    private var pressedModifiers = Set<UInt16>()

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let session else { return }
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        NSCursor.setHiddenUntilMouseMoves(true)
        let action = session.input.hotkeys.action(forKeyCode: event.keyCode)
        if session.isTyping {
            // Every key types on the emulated computer, except the one that ends typing.
            if action == .typing, !event.isARepeat { session.toggleTyping() } else { session.typeKey(event, isDown: true) }
            return
        }
        guard !event.isARepeat else { return }
        switch action {
        case .menu: session.toggleMenu()
        case .fastForward: session.setFastForward(true)
        case .fastForwardToggle: session.toggleFastForward()
        case .rewind: session.setRewinding(true)
        case .quickSave: session.saveState(slot: 0)
        case .quickLoad: session.loadState(slot: 0)
        case .screenshot: session.takeScreenshot()
        case .turbo: session.toggleTurbo()
        case .typing: session.toggleTyping()
        case .shaderPanel: session.toggleShaderPanel()
        case nil: session.input.keyDown(event.keyCode)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let session else { return }
        if session.isTyping {
            session.typeKey(event, isDown: false)
            return
        }
        switch session.input.hotkeys.action(forKeyCode: event.keyCode) {
        case .fastForward: session.setFastForward(false)
        case .rewind: session.setRewinding(false)
        default: session.input.keyUp(event.keyCode)
        }
    }

    /// Modifier keys (e.g. right shift for Select) only report flag changes.
    override func flagsChanged(with event: NSEvent) {
        guard let session else { return }
        let code = event.keyCode
        if session.isTyping {
            session.typeKey(event, isDown: EmulatedKeyboard.isModifierDown(keyCode: code, flags: event.modifierFlags))
            return
        }
        if pressedModifiers.remove(code) != nil {
            session.input.keyUp(code)
        } else {
            pressedModifiers.insert(code)
            session.input.keyDown(code)
        }
    }

    // MARK: Pointer (touch screens, light guns)

    override func mouseDown(with event: NSEvent) { updatePointer(event, pressed: true) }
    override func mouseDragged(with event: NSEvent) { updatePointer(event, pressed: true) }
    override func mouseUp(with event: NSEvent) { updatePointer(event, pressed: false) }

    private func updatePointer(_ event: NSEvent, pressed: Bool) {
        guard let core = session?.core, let rect = renderer?.imageRect, rect.width > 0, rect.height > 0 else { return }
        let location = convert(event.locationInWindow, from: nil)
        let nx = (location.x - rect.minX) / rect.width
        let ny = 1 - (location.y - rect.minY) / rect.height
        let inside = (0...1).contains(nx) && (0...1).contains(ny)
        let x = Int16(clamping: Int((min(max(nx, 0), 1) * 2 - 1) * 0x7FFF))
        let y = Int16(clamping: Int((min(max(ny, 0), 1) * 2 - 1) * 0x7FFF))
        core.setPointerX(x, y: y, pressed: pressed && inside)
    }
}
