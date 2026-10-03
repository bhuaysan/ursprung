// SPDX-License-Identifier: GPL-3.0-or-later
// Ursprung — lock-free single-producer / single-consumer ring buffer for
// interleaved stereo int16 samples. The emulation thread writes, the audio
// render thread reads.

#ifndef URAudioRing_h
#define URAudioRing_h

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct URAudioRing {
    int16_t *buffer;
    size_t capacity;          // in frames (one frame = L + R)
    _Atomic size_t readIndex; // monotonically increasing frame counters
    _Atomic size_t writeIndex;
    // Write index up to which the reader drops frames; URAudioRingNoClear
    // when no clear is pending. Only the reader moves readIndex.
    _Atomic size_t clearTarget;
} URAudioRing;

void URAudioRingInit(URAudioRing *ring, size_t capacityFrames);
void URAudioRingFree(URAudioRing *ring);
/// Discards the buffered frames. Called by the writer; the reader drops the
/// frames before its next read, so a read in progress cannot undo the clear.
void URAudioRingClear(URAudioRing *ring);

/// Number of frames currently buffered.
size_t URAudioRingAvailable(const URAudioRing *ring);

/// Writes up to `frames` stereo frames. Returns frames actually written
/// (excess samples are dropped when the buffer is full).
size_t URAudioRingWrite(URAudioRing *ring, const int16_t *samples, size_t frames);

/// Reads up to `frames` frames, de-interleaving into float buffers. Missing
/// frames are filled with silence. Returns frames actually read.
size_t URAudioRingReadFloat(URAudioRing *ring, float *left, float *right, size_t frames, float volume);

/// One audio render step: outputs silence until `primeFrames` are buffered,
/// then reads; an underrun re-primes. `primed` belongs to the reader. Returns
/// frames read (0 while priming).
size_t URAudioRingRender(URAudioRing *ring, bool *primed, size_t primeFrames,
                         float *left, float *right, size_t frames, float volume);

#endif
