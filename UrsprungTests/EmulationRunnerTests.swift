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
    let vulkanActive: @convention(c) () -> Bool
    let syncIndicesSeen: @convention(c) () -> UInt32
    let destroyDeviceCalls: @convention(c) () -> UInt32
    let contextDestroyCalls: @convention(c) () -> UInt32
    let vulkanPixel: @convention(c) (UInt32) -> UInt32

    /// How the core renders (see test_core.c).
    enum Rendering: Int32 {
        case software = 0
        /// Vulkan, submitting itself and handing over a semaphore.
        case vulkanSubmit = 1
        /// Vulkan, handing its command buffers to the frontend.
        case vulkanCommandBuffers = 2
    }

    static func load(rendering: Rendering = .software, preferring api: GraphicsAPI? = nil) throws -> TestCore {
        let url = try #require(Bundle(for: TestBundle.self).url(forResource: "ursprung-test-core", withExtension: "dylib"))
        let core = try LibretroCore(path: url.path(percentEncoded: false))
        // The same image the core opened, so the same state.
        let handle = try #require(dlopen(url.path(percentEncoded: false), RTLD_LAZY | RTLD_LOCAL))
        func function<T>(_ name: String, as type: T.Type) throws -> T {
            unsafeBitCast(try #require(dlsym(handle, name)), to: type)
        }
        let setVulkanMode = try function("ur_test_core_set_vulkan_mode", as: (@convention(c) (Int32) -> Void).self)
        setVulkanMode(rendering.rawValue)
        core.preferredGraphicsAPI = api ?? (rendering == .software ? .openGL : .vulkan)
        try core.loadGame(atPath: url.path(percentEncoded: false))
        return TestCore(core: core,
                        setUnserializeFails: try function("ur_test_core_set_unserialize_fails",
                                                          as: (@convention(c) (Bool) -> Void).self),
                        frame: try function("ur_test_core_frame", as: (@convention(c) () -> UInt32).self),
                        vulkanActive: try function("ur_test_core_vulkan_active", as: (@convention(c) () -> Bool).self),
                        syncIndicesSeen: try function("ur_test_core_sync_indices_seen",
                                                      as: (@convention(c) () -> UInt32).self),
                        destroyDeviceCalls: try function("ur_test_core_destroy_device_calls",
                                                         as: (@convention(c) () -> UInt32).self),
                        contextDestroyCalls: try function("ur_test_core_context_destroy_calls",
                                                          as: (@convention(c) () -> UInt32).self),
                        vulkanPixel: try function("ur_test_core_vulkan_pixel", as: (@convention(c) (UInt32) -> UInt32).self))
    }

    /// The top-left pixel of the latest frame (BGRA8 as a little-endian word).
    var latestPixel: UInt32? {
        var pixel: UInt32?
        _ = core.accessLatestFrame { pixels, _, _, _ in pixel = pixels.load(as: UInt32.self) }
        return pixel
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

extension EmulationRunnerTests {
    /// The Vulkan path through MoltenVK, with the test core rendering on the
    /// GPU. Nested so it never runs beside the other tests of the test core.
    /// Skipped where this Mac (or CI runner) offers no Vulkan device.
    @Suite("Vulkan rendering", .enabled(if: LibretroCore.vulkanAvailable))
    struct VulkanRendering {
        @Test(arguments: [TestCore.Rendering.vulkanSubmit, .vulkanCommandBuffers])
        fileprivate func framesReachTheFrameBuffer(rendering: TestCore.Rendering) throws {
            let test = try TestCore.load(rendering: rendering)
            defer { test.core.unloadGame() }
            #expect(test.vulkanActive())
            #expect(test.core.graphicsAPI == .vulkan)
            #expect(test.core.usesHardwareRendering)

            for _ in 0..<5 { test.core.runFrame() }
            #expect(test.core.frameSerial == 5)
            #expect(test.latestPixel == test.vulkanPixel(5))
            #expect(test.syncIndicesSeen() == 0b11, "Both sync indices were used")
        }

        @Test(arguments: [TestCore.Rendering.vulkanSubmit, .vulkanCommandBuffers])
        fileprivate func hiddenFramesStillRunOnTheGPU(rendering: TestCore.Rendering) throws {
            let test = try TestCore.load(rendering: rendering)
            defer { test.core.unloadGame() }
            test.core.runFrame()
            // Frames nobody sees (rewinding, a paused menu redraw) still consume
            // the core's command buffers and semaphores.
            test.core.videoEnabled = false
            for _ in 0..<4 { test.core.runFrame() }
            test.core.videoEnabled = true
            #expect(test.latestPixel == test.vulkanPixel(1))
            #expect(test.core.frameSerial == 1)
            test.core.runFrame()
            #expect(test.latestPixel == test.vulkanPixel(6))
        }

        @Test func runAheadStaysOffForHardwareRendering() throws {
            let test = try TestCore.load(rendering: .vulkanSubmit)
            defer { test.core.unloadGame() }
            let runner = EmulationRunner(core: test.core)
            runner.runAheadFrames = 2
            for index in 0..<10 { runner.runVisibleFrame(UInt(index), fastForward: false) }
            #expect(test.frame() == 10)
            #expect(test.latestPixel == test.vulkanPixel(10))
        }

        @Test func statesWorkWithVulkan() throws {
            let test = try TestCore.load(rendering: .vulkanCommandBuffers)
            defer { test.core.unloadGame() }
            for _ in 0..<3 { test.core.runFrame() }
            let state = try #require(test.core.serializeState())
            for _ in 0..<3 { test.core.runFrame() }
            #expect(test.core.unserializeState(state))
            test.core.runFrame()
            #expect(test.latestPixel == test.vulkanPixel(4))
        }

        @Test func loadingAndUnloadingRepeats() throws {
            let destroyedBefore = try TestCore.load(rendering: .vulkanSubmit)
            let devices = destroyedBefore.destroyDeviceCalls()
            let contexts = destroyedBefore.contextDestroyCalls()
            destroyedBefore.core.unloadGame()
            #expect(destroyedBefore.destroyDeviceCalls() == devices + 1)
            #expect(destroyedBefore.contextDestroyCalls() == contexts + 1)

            for round in 0..<12 {
                let test = try TestCore.load(rendering: round.isMultiple(of: 2) ? .vulkanSubmit : .vulkanCommandBuffers)
                for _ in 0..<3 { test.core.runFrame() }
                #expect(test.latestPixel == test.vulkanPixel(3))
                test.core.unloadGame()
            }
            #expect(destroyedBefore.destroyDeviceCalls() == devices + 13)
        }

        @Test func softwareCoresIgnoreTheVulkanPreference() throws {
            let test = try TestCore.load(rendering: .software, preferring: .vulkan)
            defer { test.core.unloadGame() }
            test.core.runFrame()
            #expect(test.core.graphicsAPI == .none)
            #expect(test.core.frameSerial == 1)
        }
    }
}
