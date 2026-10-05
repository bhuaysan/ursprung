// SPDX-License-Identifier: GPL-3.0-or-later

#include "URRewindBuffer.h"

#include <compression.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint8_t *data;
    size_t length;
    bool raw; // stored uncompressed: LZ4 did not make it smaller
} URRewindEntry;

struct URRewindBuffer {
    size_t capacity;
    size_t used;

    // Circular list of differences, oldest at `head`.
    URRewindEntry *entries;
    size_t entryCapacity;
    size_t head;
    size_t count;

    // The newest state, and working memory for one state.
    uint8_t *current;
    uint8_t *delta;
    uint8_t *compressed;
    size_t stateSize;
    void *encodeScratch;
    void *decodeScratch;
};

URRewindBuffer *URRewindBufferCreate(size_t capacityBytes) {
    URRewindBuffer *buffer = calloc(1, sizeof(URRewindBuffer));
    if (!buffer) return NULL;
    buffer->capacity = capacityBytes;
    buffer->encodeScratch = malloc(compression_encode_scratch_buffer_size(COMPRESSION_LZ4));
    buffer->decodeScratch = malloc(compression_decode_scratch_buffer_size(COMPRESSION_LZ4));
    return buffer;
}

static void URRewindDropOldest(URRewindBuffer *buffer) {
    URRewindEntry *entry = &buffer->entries[buffer->head];
    buffer->used -= entry->length;
    free(entry->data);
    entry->data = NULL;
    buffer->head = (buffer->head + 1) % buffer->entryCapacity;
    buffer->count--;
}

void URRewindBufferClear(URRewindBuffer *buffer) {
    if (!buffer) return;
    while (buffer->count > 0) URRewindDropOldest(buffer);
    buffer->head = 0;
    free(buffer->current);
    free(buffer->delta);
    free(buffer->compressed);
    buffer->current = buffer->delta = buffer->compressed = NULL;
    buffer->stateSize = 0;
}

void URRewindBufferFree(URRewindBuffer *buffer) {
    if (!buffer) return;
    URRewindBufferClear(buffer);
    free(buffer->entries);
    free(buffer->encodeScratch);
    free(buffer->decodeScratch);
    free(buffer);
}

/// a ^= b over `size` bytes.
static void URXor(uint8_t *a, const uint8_t *b, size_t size) {
    size_t i = 0;
    for (; i + 8 <= size; i += 8) {
        uint64_t x, y;
        memcpy(&x, a + i, 8);
        memcpy(&y, b + i, 8);
        x ^= y;
        memcpy(a + i, &x, 8);
    }
    for (; i < size; i++) a[i] ^= b[i];
}

static bool URRewindAppend(URRewindBuffer *buffer, URRewindEntry entry) {
    if (buffer->count == buffer->entryCapacity) {
        size_t capacity = buffer->entryCapacity ? buffer->entryCapacity * 2 : 64;
        URRewindEntry *entries = calloc(capacity, sizeof(URRewindEntry));
        if (!entries) return false;
        for (size_t i = 0; i < buffer->count; i++) {
            entries[i] = buffer->entries[(buffer->head + i) % buffer->entryCapacity];
        }
        free(buffer->entries);
        buffer->entries = entries;
        buffer->entryCapacity = capacity;
        buffer->head = 0;
    }
    buffer->entries[(buffer->head + buffer->count) % buffer->entryCapacity] = entry;
    buffer->count++;
    buffer->used += entry.length;
    return true;
}

void URRewindBufferPush(URRewindBuffer *buffer, const void *state, size_t size) {
    if (!buffer || !state || size == 0) return;
    if (size != buffer->stateSize || !buffer->current) {
        URRewindBufferClear(buffer);
        buffer->current = malloc(size);
        buffer->delta = malloc(size);
        buffer->compressed = malloc(size);
        if (!buffer->current || !buffer->delta || !buffer->compressed) {
            URRewindBufferClear(buffer);
            return;
        }
        memcpy(buffer->current, state, size);
        buffer->stateSize = size;
        return;
    }

    // The difference that turns the new state back into the current one.
    memcpy(buffer->delta, buffer->current, size);
    URXor(buffer->delta, state, size);
    size_t length = compression_encode_buffer(buffer->compressed, size, buffer->delta, size,
                                              buffer->encodeScratch, COMPRESSION_LZ4);
    URRewindEntry entry = {0};
    entry.raw = length == 0;
    entry.length = entry.raw ? size : length;
    entry.data = malloc(entry.length);
    if (entry.data) {
        memcpy(entry.data, entry.raw ? buffer->delta : buffer->compressed, entry.length);
        if (!URRewindAppend(buffer, entry)) free(entry.data);
    }
    while (buffer->used > buffer->capacity && buffer->count > 0) URRewindDropOldest(buffer);
    memcpy(buffer->current, state, size);
}

bool URRewindBufferStepBack(URRewindBuffer *buffer, void *out, size_t size) {
    if (!buffer || buffer->count == 0 || size != buffer->stateSize) return false;
    size_t index = (buffer->head + buffer->count - 1) % buffer->entryCapacity;
    URRewindEntry *entry = &buffer->entries[index];
    if (entry->raw) {
        memcpy(buffer->delta, entry->data, size);
    } else {
        size_t decoded = compression_decode_buffer(buffer->delta, size, entry->data, entry->length,
                                                   buffer->decodeScratch, COMPRESSION_LZ4);
        if (decoded != size) {
            // Damaged entry: nothing older can be reconstructed.
            while (buffer->count > 0) URRewindDropOldest(buffer);
            return false;
        }
    }
    URXor(buffer->current, buffer->delta, size);
    buffer->used -= entry->length;
    free(entry->data);
    entry->data = NULL;
    buffer->count--;
    memcpy(out, buffer->current, size);
    return true;
}

size_t URRewindBufferDepth(const URRewindBuffer *buffer) {
    return buffer ? buffer->count : 0;
}

size_t URRewindBufferUsedBytes(const URRewindBuffer *buffer) {
    return buffer ? buffer->used : 0;
}
