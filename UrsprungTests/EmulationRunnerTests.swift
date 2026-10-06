// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

private final class TestBundle {}

/// The test core (Tools/ursprung-test-core), loaded like a downloaded core,
/// with a game and its test switches.
private struct TestCore {
    let core: LibretroCore
    let setUnserializeFails: @convention(c) (Bool) -> Void
    let frame: @convention(c) () -> UInt32

    static func load() throws -> TestCore {
        let url = try #require(Bundle(for: TestBundle.self).url(forResource: "ursprung-test-core", withExtension: "dylib"))
        let core = try LibretroCore(path: url.path(percentEncoded: false))
        try core.loadGame(atPath: url.path(percentEncoded: false))
        // The same image the core opened, so the same state.
        let handle = try #require(dlopen(url.path(percentEncoded: false), RTLD_LAZY | RTLD_LOCAL))
        func function<T>(_ name: String, as type: T.Type) throws -> T {
            unsafeBitCast(try #require(dlsym(handle, name)), to: type)
        }
        return TestCore(core: core,
                        setUnserializeFails: try function("ur_test_core_set_unserialize_fails",
                                                          as: (@convention(c) (Bool) -> Void).self),
                        frame: try function("ur_test_core_frame", as: (@convention(c) () -> UInt32).self))
    }
}

/// Only one core can be loaded at a time.
@Suite("Emulation runner", .serialized)
struct EmulationRunnerTests {
    @Test func runAheadGoesBackToTheRealFrame() throws {
        let test = try TestCore.load()
        defer { test.core.unloadGame() }
        let runner = EmulationRunner(core: test.core)
        runner.runAheadFrames = 2

        for index in 0..<10 { runner.runVisibleFrame(UInt(index), fastForward: false) }
        #expect(test.frame() == 10)
    }

    @Test func runAheadStopsWhenTheCoreCantGoBack() throws {
        let test = try TestCore.load()
        defer { test.core.unloadGame() }
        let runner = EmulationRunner(core: test.core)
        runner.runAheadFrames = 2
        test.setUnserializeFails(true)

        for index in 0..<10 { runner.runVisibleFrame(UInt(index), fastForward: false) }
        // The first frame's look ahead stays; after that, one frame each.
        #expect(test.frame() == 12)
    }

    @Test func rewindStopsWhenTheCoreCantGoBack() throws {
        let test = try TestCore.load()
        defer { test.core.unloadGame() }
        let runner = EmulationRunner(core: test.core)
        runner.rewindEnabled = true
        runner.updateRewindBuffer()
        for index in 0..<5 { runner.runVisibleFrame(UInt(index), fastForward: false) }
        #expect(runner.rewindAvailability == .available)

        runner.stepBack()
        #expect(test.frame() == 5, "Back to the state before the last frame, then that frame again")

        test.setUnserializeFails(true)
        runner.stepBack()
        #expect(test.frame() == 5, "Not a frame forwards while rewinding")
        #expect(runner.rewindAvailability == .unsupported)
        #expect(runner.rewindSeconds == 0)
    }
}
