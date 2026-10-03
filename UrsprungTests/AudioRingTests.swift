// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import Ursprung

/// Drives the ring the way the emulation thread and the audio render callback do.
nonisolated private final class AudioRingHarness {
    let ring = UnsafeMutablePointer<URAudioRing>.allocate(capacity: 1)
    var primed = false
    let primeFrames: Int
    private var left: [Float]
    private var right: [Float]

    init(capacity: Int, primeFrames: Int, renderFrames: Int) {
        URAudioRingInit(ring, capacity)
        self.primeFrames = primeFrames
        left = Array(repeating: 0, count: renderFrames)
        right = Array(repeating: 0, count: renderFrames)
    }

    deinit {
        URAudioRingFree(ring)
        ring.deallocate()
    }

    /// One emulated frame of `frames` stereo frames.
    @discardableResult
    func write(_ frames: Int) -> Int {
        let samples = [Int16](repeating: 1000, count: frames * 2)
        return URAudioRingWrite(ring, samples, frames)
    }

    /// One render callback.
    @discardableResult
    func render() -> Int {
        URAudioRingRender(ring, &primed, primeFrames, &left, &right, left.count, 1)
    }
}

@Suite("Audio ring")
struct AudioRingTests {
    @Test func playbackResumesAfterFastForwardWhilePriming() {
        let audio = AudioRingHarness(capacity: 16, primeFrames: 4, renderFrames: 2)

        // Fast forward clears after every frame while the output still primes.
        for _ in 0..<20 {
            audio.write(2)
            URAudioRingClear(audio.ring)
            audio.render()
        }
        #expect(URAudioRingAvailable(audio.ring) == 0)

        // Back to normal speed: writing and playback must recover.
        var written = 0, read = 0
        for _ in 0..<100 {
            written += audio.write(2)
            read += audio.render()
        }
        #expect(written == 200)
        #expect(read > 150)
        #expect(audio.primed)
    }

    @Test func clearedFramesAreNotPlayed() {
        let audio = AudioRingHarness(capacity: 16, primeFrames: 4, renderFrames: 2)
        audio.write(8)
        URAudioRingClear(audio.ring)

        #expect(URAudioRingAvailable(audio.ring) == 0)
        #expect(audio.render() == 0, "Still priming: nothing left to play")
        #expect(audio.write(16) == 16, "The cleared frames no longer take up space")
    }

    @Test func underrunReprimes() {
        let audio = AudioRingHarness(capacity: 16, primeFrames: 4, renderFrames: 4)
        audio.write(4)
        #expect(audio.render() == 4)
        #expect(audio.primed)

        audio.write(2)
        #expect(audio.render() == 2)
        #expect(!audio.primed)
        audio.write(2)
        #expect(audio.render() == 0, "Waits for the prime level again")
    }
}
