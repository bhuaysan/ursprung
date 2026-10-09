// SPDX-License-Identifier: GPL-3.0-or-later
// Ursprung — converts frames that hardware-rendering cores hand over into the
// BGRA8 frame buffer the player shows (see URVulkanContext).

#ifndef URPixelConversion_h
#define URPixelConversion_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Pixel layouts read back from a Vulkan image, named like their VkFormat.
typedef enum {
    URPixelLayoutUnsupported = 0,
    URPixelLayoutB8G8R8A8,
    URPixelLayoutR8G8B8A8,
    URPixelLayoutA2B10G10R10,
    URPixelLayoutA2R10G10B10,
    URPixelLayoutR16G16B16A16Float,
    URPixelLayoutR5G6B5,
    URPixelLayoutA1R5G5B5,
    URPixelLayoutR5G5B5A1,
} URPixelLayout;

/// Where a channel of the shown frame comes from, with the values of
/// VkComponentSwizzle.
typedef enum {
    URSwizzleIdentity = 0,
    URSwizzleZero = 1,
    URSwizzleOne = 2,
    URSwizzleR = 3,
    URSwizzleG = 4,
    URSwizzleB = 5,
    URSwizzleA = 6,
} URSwizzle;

/// The channel mapping of the image view a core hands over
/// (VkComponentMapping).
typedef struct {
    URSwizzle r, g, b, a;
} URComponentMapping;

/// Bytes per pixel of `layout`, 0 when unsupported.
size_t URPixelLayoutBytesPerPixel(URPixelLayout layout);

/// Converts `width`×`height` pixels into opaque BGRA8 (row pitch `width * 4`),
/// through `mapping` (NULL: identity). Returns false for an unsupported layout.
bool URConvertPixelsToBGRA8(URPixelLayout layout, const void *source, size_t sourcePitch,
                            const URComponentMapping *mapping,
                            uint8_t *destination, unsigned width, unsigned height);

#ifdef __cplusplus
}
#endif

#endif
