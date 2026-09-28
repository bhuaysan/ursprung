// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import MetalKit
import SwiftUI

/// SwiftUI wrapper for the Metal view that shows the emulator output and
/// receives keyboard and mouse input.
struct GameMetalView: NSViewRepresentable {
    let session: EmulationSession
    let filter: VideoFilter
    let integerScaling: Bool

    func makeNSView(context: Context) -> GameMTKView {
        let view = GameMTKView(frame: .zero, device: nil)
        view.session = session
        view.renderer = MetalRenderer(view: view)
        return view
    }

    func updateNSView(_ view: GameMTKView, context: Context) {
        view.renderer?.core = session.core
        view.renderer?.filter = filter
        view.renderer?.integerScaling = integerScaling
        if session.phase == .running, !session.isMenuVisible {
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
        switch event.keyCode {
        case HotKey.escape:
            if !event.isARepeat { session.toggleMenu() }
        case HotKey.fastForward:
            if !event.isARepeat { session.setFastForward(true) }
        case HotKey.quickSave:
            if !event.isARepeat { session.saveState(slot: 0) }
        case HotKey.quickLoad:
            if !event.isARepeat { session.loadState(slot: 0) }
        default:
            if !event.isARepeat { session.input.keyDown(event.keyCode) }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let session else { return }
        if event.keyCode == HotKey.fastForward {
            session.setFastForward(false)
        } else {
            session.input.keyUp(event.keyCode)
        }
    }

    /// Modifier keys (e.g. right shift for Select) only report flag changes.
    override func flagsChanged(with event: NSEvent) {
        guard let session else { return }
        let code = event.keyCode
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
