// SPDX-License-Identifier: GPL-3.0-or-later
// Ursprung — memory-bounded history of save states for rewinding.
//
// The newest state is kept whole; every older one only as the compressed
// difference (XOR, then LZ4) to the state after it. Stepping back applies
// the newest difference to the newest state. When the buffer is full, the
// oldest differences are dropped. Used by the emulation thread only.

#ifndef URRewindBuffer_h
#define URRewindBuffer_h

#include <stdbool.h>
#include <stddef.h>

typedef struct URRewindBuffer URRewindBuffer;

/// A buffer that keeps at most `capacityBytes` of compressed history (plus
/// the newest state and working memory of about three state sizes).
URRewindBuffer *URRewindBufferCreate(size_t capacityBytes);
void URRewindBufferFree(URRewindBuffer *buffer);

/// Forgets every state.
void URRewindBufferClear(URRewindBuffer *buffer);

/// Records `state` as the newest state. A state of another size than the
/// previous ones starts the history over.
void URRewindBufferPush(URRewindBuffer *buffer, const void *state, size_t size);

/// Steps back one state: writes the state recorded before the newest one to
/// `out` (which must hold the state size) and makes it the newest. Returns
/// false when no older state is left.
bool URRewindBufferStepBack(URRewindBuffer *buffer, void *out, size_t size);

/// Older states that can still be reached.
size_t URRewindBufferDepth(const URRewindBuffer *buffer);
/// Bytes the compressed history takes.
size_t URRewindBufferUsedBytes(const URRewindBuffer *buffer);

#endif
