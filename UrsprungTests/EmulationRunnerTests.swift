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
    let signalsSeen: @convention(c) () -> UInt32
    let unloadGameCalls: @convention(c) () -> UInt32
    let deinitCalls: @convention(c) () -> UInt32
    let waitsReturned: @convention(c) () -> UInt32

    /// How the core renders (see test_core.c).
    enum Rendering: Int32 {
        case software = 0
        /// Vulkan, submitting itself and handing over a semaphore.
        case vulkanSubmit = 1
        /// Vulkan, handing its command buffers to the frontend.
        case vulkanCommandBuffers = 2
    }

    /// Cases of the Vulkan contract the core exercises (see test_core.c).
    struct Variant: OptionSet {
        let rawValue: Int
        /// The image view swaps red and blue.
        static let swizzledView = Variant(rawValue: 1 << 0)
        /// With command buffers, set_image also passes a semaphore nobody signals.
        static let ignoredSemaphore = Variant(rawValue: 1 << 1)
        /// Every run refreshes a duplicate frame and then the real one, each
        /// with its own signal semaphore.
        static let signalsFrames = Variant(rawValue: 1 << 2)
        /// After handing over a frame, the run waits for its sync index.
        static let waitsAfterFrame = Variant(rawValue: 1 << 3)
    }

    /// How often the core was torn down, call by call (counted across games).
    struct Teardown: Equatable {
        var contextDestroys: UInt32
        var gameUnloads: UInt32
        var deinits: UInt32
        var deviceDestroys: UInt32

        func plus(_ count: UInt32) -> Teardown {
            Teardown(contextDestroys: contextDestroys + count, gameUnloads: gameUnloads + count,
                     deinits: deinits + count, deviceDestroys: deviceDestroys + count)
        }
    }

    var teardown: Teardown { teardownReader() }

    /// Reads `teardown` without keeping the core alive.
    var teardownReader: () -> Teardown {
        let (contexts, unloads, deinits, devices) = (contextDestroyCalls, unloadGameCalls, deinitCalls, destroyDeviceCalls)
        return { Teardown(contextDestroys: contexts(), gameUnloads: unloads(), deinits: deinits(), deviceDestroys: devices()) }
    }

    static func load(rendering: Rendering = .software, preferring api: GraphicsAPI? = nil,
                     variant: Variant = []) throws -> TestCore {
        let url = try #require(Bundle(for: TestBundle.self).url(forResource: "ursprung-test-core", withExtension: "dylib"))
        let core = try LibretroCore(path: url.path(percentEncoded: false))
        // The same image the core opened, so the same state.
        let handle = try #require(dlopen(url.path(percentEncoded: false), RTLD_LAZY | RTLD_LOCAL))
        func function<T>(_ name: String, as type: T.Type) throws -> T {
            unsafeBitCast(try #require(dlsym(handle, name)), to: type)
        }
        let setVulkanMode = try function("ur_test_core_set_vulkan_mode", as: (@convention(c) (Int32) -> Void).self)
        setVulkanMode(rendering.rawValue)
        let switches: [(String, Variant)] = [("ur_test_core_set_swizzled_view", .swizzledView),
                                             ("ur_test_core_set_ignored_semaphore", .ignoredSemaphore),
                                             ("ur_test_core_set_signals_frames", .signalsFrames),
                                             ("ur_test_core_set_waits_after_frame", .waitsAfterFrame)]
        for (name, option) in switches {
            try function(name, as: (@convention(c) (Bool) -> Void).self)(variant.contains(option))
        }
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
                        vulkanPixel: try function("ur_test_core_vulkan_pixel", as: (@convention(c) (UInt32) -> UInt32).self),
                        signalsSeen: try function("ur_test_core_signals_seen", as: (@convention(c) () -> UInt32).self),
                        unloadGameCalls: try function("ur_test_core_unload_game_calls",
                                                      as: (@convention(c) () -> UInt32).self),
                        deinitCalls: try function("ur_test_core_deinit_calls", as: (@convention(c) () -> UInt32).self),
                        waitsReturned: try function("ur_test_core_waits_returned", as: (@convention(c) () -> UInt32).self))
    }

    /// Loads the core once the GPU has finished the frame that keeps the
    /// previous core alive; until then loading fails with code 7.
    static func loadOnceTheGPUIsDone(within timeout: Duration = .seconds(10)) throws -> TestCore {
        let deadline = ContinuousClock.now + timeout
        while true {
            do {
                return try load()
            } catch let error as NSError where error.code == 7 && ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
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
        runner.isRewinding = true
        runner.stepBack()
        #expect(test.frame() == 5, "Not a frame forwards while rewinding")
        #expect(runner.rewindAvailability == .unsupported)
        #expect(runner.rewindSeconds == 0)
        // The game runs forwards from here, so rewinding is over for the
        // display and the shaders too (B6 of the 2026-10-07 re-review).
        #expect(!runner.isRewinding)
    }

    @Test @MainActor func aFailedRewindTellsTheSession() async throws {
        let test = try TestCore.load()
        defer { test.core.unloadGame() }
        let runner = EmulationRunner(core: test.core)
        runner.rewindEnabled = true
        runner.updateRewindBuffer()
        for index in 0..<5 { runner.runVisibleFrame(UInt(index), fastForward: false) }
        test.setUnserializeFails(true)
        runner.isRewinding = true

        await withCheckedContinuation { continuation in
            runner.rewindStoppedHandler = { continuation.resume() }
            runner.stepBack()
        }
        #expect(!runner.isRewinding)
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

        /// With command buffers the core synchronises through barriers: the
        /// image's semaphores are ignored (libretro_vulkan.h, set_image), even
        /// one that is never signalled.
        @Test func commandBuffersIgnoreTheImageSemaphores() throws {
            let test = try TestCore.load(rendering: .vulkanCommandBuffers, variant: .ignoredSemaphore)
            defer { test.core.unloadGame() }
            for _ in 0..<3 { test.core.runFrame() }
            #expect(!test.core.shutdownRequested)
            #expect(test.latestPixel == test.vulkanPixel(3))
        }

        /// The signal semaphore belongs to the next video refresh, a duplicate
        /// frame's too, and is signalled within it.
        @Test(arguments: [TestCore.Rendering.vulkanSubmit, .vulkanCommandBuffers])
        fileprivate func everyRefreshSignalsItsSemaphore(rendering: TestCore.Rendering) throws {
            let test = try TestCore.load(rendering: rendering, variant: .signalsFrames)
            defer { test.core.unloadGame() }
            for _ in 0..<3 { test.core.runFrame() }
            #expect(test.signalsSeen() == 6, "A duplicate and a real frame per run")
            #expect(test.core.frameSerial == 3, "Duplicate frames keep the last frame")
            #expect(test.latestPixel == test.vulkanPixel(3))
        }

        @Test func theImageViewsChannelMappingApplies() throws {
            let test = try TestCore.load(rendering: .vulkanSubmit, variant: .swizzledView)
            defer { test.core.unloadGame() }
            test.core.runFrame()
            // Red and blue swap: the image's blue (0x80) shows as red, the
            // frame number as blue.
            #expect(test.latestPixel == 0xFF80_4001)
        }

        /// A frame the GPU does not finish in time (VK_TIMEOUT) or a lost
        /// device (VK_ERROR_DEVICE_LOST) stops the game: the core does not run
        /// on beside resources that may still be in use, and it still unloads
        /// (the timed-out frame is done by then).
        @Test(arguments: [Int32(2), -4])
        func aFailedFrameStopsTheGame(result: Int32) throws {
            let test = try TestCore.load(rendering: .vulkanSubmit)
            let teardown = test.teardown
            for _ in 0..<2 { test.core.runFrame() }
            #expect(!test.core.shutdownRequested)

            test.core.simulateVulkanFenceWaitResult(result)
            test.core.runFrame()
            #expect(test.core.shutdownRequested)
            #expect(test.latestPixel == test.vulkanPixel(2), "The failed frame is not shown")
            test.core.runFrame()
            #expect(test.frame() == 3, "No retro_run after the failure")
            #expect(!test.core.supportsSaveStates, "No states of a core whose GPU failed")

            test.core.unloadGame()
            #expect(test.teardown == teardown.plus(1))
        }

        /// wait_sync_index promises that the GPU is done with the frame, so
        /// after a timeout it returns only once that frame finished.
        @Test func waitingForTheSyncIndexWaitsForAnUnfinishedFrame() throws {
            let test = try TestCore.load(rendering: .vulkanSubmit, variant: .waitsAfterFrame)
            defer { test.core.unloadGame() }
            test.core.runFrame()
            let waits = test.waitsReturned()

            // The frame and wait_sync_index's first wait time out; its second
            // wait finds the frame done.
            test.core.simulateVulkanFenceWaitResult(2)
            test.core.simulateVulkanFenceWaitResult(2)
            test.core.runFrame()
            #expect(test.waitsReturned() == waits + 1)
            #expect(!test.core.vulkanBusy, "wait_sync_index returned only after the frame was done")
            #expect(test.core.shutdownRequested)
        }

        /// A frame that still runs when the game unloads keeps the core whole
        /// (no context_destroy, retro_unload_game, retro_deinit, nor its
        /// library or object going away) and blocks other games; once the
        /// frame is done, the next game tears it down first, exactly once.
        @Test func anUnfinishedFrameDefersTheTeardown() throws {
            weak var unfinished: LibretroCore?
            var before: TestCore.Teardown?
            var teardownNow: (() -> TestCore.Teardown)?
            try autoreleasepool {
                let test = try TestCore.load(rendering: .vulkanSubmit)
                before = test.teardown
                teardownNow = test.teardownReader
                test.core.runFrame()
                // Timeouts for the frame, the unload and the first other game.
                for _ in 0..<3 { test.core.simulateVulkanFenceWaitResult(2) }
                test.core.runFrame()
                #expect(test.core.vulkanBusy)
                test.core.unloadGame()
                unfinished = test.core
            }
            let teardown = try #require(before)
            let current = try #require(teardownNow)
            #expect(unfinished != nil, "The core stays while the GPU runs its frame")
            #expect(current() == teardown)

            let error = #expect(throws: (any Error).self) { _ = try TestCore.load() }
            #expect((error as? NSError)?.code == 7)
            #expect(current() == teardown, "Still running: nothing torn down")

            // Done once the frame's real fence has signalled. Loading only polls
            // it, and a CI runner's virtual GPU may still be at the frame.
            let next = try TestCore.loadOnceTheGPUIsDone()
            defer { next.core.unloadGame() }
            #expect(current() == teardown.plus(1))
            #expect(unfinished == nil, "The core went once torn down")
            next.core.runFrame()
            #expect(next.frame() == 1)
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
