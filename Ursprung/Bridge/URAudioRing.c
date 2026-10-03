// SPDX-License-Identifier: GPL-3.0-or-later

#include "URAudioRing.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define URAudioRingNoClear SIZE_MAX

void URAudioRingInit(URAudioRing *ring, size_t capacityFrames) {
    ring->buffer = calloc(capacityFrames * 2, sizeof(int16_t));
    ring->capacity = capacityFrames;
    atomic_store(&ring->readIndex, 0);
    atomic_store(&ring->writeIndex, 0);
    atomic_store(&ring->clearTarget, URAudioRingNoClear);
}

void URAudioRingFree(URAudioRing *ring) {
    free(ring->buffer);
    ring->buffer = NULL;
    ring->capacity = 0;
}

void URAudioRingClear(URAudioRing *ring) {
    // The reader may be copying frames right now and stores its read index
    // afterwards, so the writer only asks for the clear.
    atomic_store_explicit(&ring->clearTarget, atomic_load_explicit(&ring->writeIndex, memory_order_relaxed),
                          memory_order_release);
}

/// The read index once a pending clear has been applied.
static size_t URAudioRingEffectiveReadIndex(const URAudioRing *ring, size_t r) {
    size_t target = atomic_load_explicit(&ring->clearTarget, memory_order_acquire);
    return target != URAudioRingNoClear && target > r ? target : r;
}

size_t URAudioRingAvailable(const URAudioRing *ring) {
    size_t w = atomic_load_explicit(&ring->writeIndex, memory_order_acquire);
    size_t r = URAudioRingEffectiveReadIndex(ring, atomic_load_explicit(&ring->readIndex, memory_order_acquire));
    return w - r;
}

size_t URAudioRingWrite(URAudioRing *ring, const int16_t *samples, size_t frames) {
    if (!ring->buffer || frames == 0) return 0;
    size_t w = atomic_load_explicit(&ring->writeIndex, memory_order_relaxed);
    // The real read index, not the one after a pending clear: the reader may
    // still be copying the frames a clear discards.
    size_t r = atomic_load_explicit(&ring->readIndex, memory_order_acquire);
    size_t free = ring->capacity - (w - r);
    if (frames > free) frames = free;

    for (size_t i = 0; i < frames; i++) {
        size_t slot = ((w + i) % ring->capacity) * 2;
        ring->buffer[slot] = samples[i * 2];
        ring->buffer[slot + 1] = samples[i * 2 + 1];
    }
    atomic_store_explicit(&ring->writeIndex, w + frames, memory_order_release);
    return frames;
}

/// Applies a pending clear and returns the read index afterwards. Reader only.
static size_t URAudioRingApplyClear(URAudioRing *ring) {
    size_t r = atomic_load_explicit(&ring->readIndex, memory_order_relaxed);
    size_t target = atomic_exchange_explicit(&ring->clearTarget, URAudioRingNoClear, memory_order_acq_rel);
    if (target != URAudioRingNoClear && target > r) {
        r = target;
        atomic_store_explicit(&ring->readIndex, r, memory_order_release);
    }
    return r;
}

size_t URAudioRingReadFloat(URAudioRing *ring, float *left, float *right, size_t frames, float volume) {
    size_t r = URAudioRingApplyClear(ring);
    size_t w = atomic_load_explicit(&ring->writeIndex, memory_order_acquire);
    size_t available = w - r;
    size_t n = frames < available ? frames : available;
    const float scale = volume / 32768.0f;

    for (size_t i = 0; i < n; i++) {
        size_t slot = ((r + i) % ring->capacity) * 2;
        left[i] = (float)ring->buffer[slot] * scale;
        right[i] = (float)ring->buffer[slot + 1] * scale;
    }
    for (size_t i = n; i < frames; i++) {
        left[i] = 0.0f;
        right[i] = 0.0f;
    }
    atomic_store_explicit(&ring->readIndex, r + n, memory_order_release);
    return n;
}

size_t URAudioRingRender(URAudioRing *ring, bool *primed, size_t primeFrames,
                         float *left, float *right, size_t frames, float volume) {
    if (!*primed) {
        // Cleared frames are dropped while priming too: otherwise they fill
        // the buffer, the writer stops and the clear is never applied.
        if (ring) URAudioRingApplyClear(ring);
        if (!ring || URAudioRingAvailable(ring) < primeFrames) {
            memset(left, 0, frames * sizeof(float));
            if (right != left) memset(right, 0, frames * sizeof(float));
            return 0;
        }
        *primed = true;
    }
    size_t read = URAudioRingReadFloat(ring, left, right, frames, volume);
    if (read < frames) *primed = false; // underrun → re-prime
    return read;
}
