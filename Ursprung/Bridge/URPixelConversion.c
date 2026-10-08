// SPDX-License-Identifier: GPL-3.0-or-later

#include "URPixelConversion.h"

size_t URPixelLayoutBytesPerPixel(URPixelLayout layout) {
    switch (layout) {
        case URPixelLayoutB8G8R8A8:
        case URPixelLayoutR8G8B8A8:
        case URPixelLayoutA2B10G10R10:
        case URPixelLayoutA2R10G10B10:
            return 4;
        case URPixelLayoutR16G16B16A16Float:
            return 8;
        case URPixelLayoutR5G6B5:
        case URPixelLayoutA1R5G5B5:
        case URPixelLayoutR5G5B5A1:
            return 2;
        case URPixelLayoutUnsupported:
            break;
    }
    return 0;
}

static inline uint32_t URPack(uint32_t r, uint32_t g, uint32_t b) {
    return 0xFF000000u | (r << 16) | (g << 8) | b;
}

static inline uint32_t URExpand5(uint32_t v) { return (v << 3) | (v >> 2); }

static inline uint32_t URUnitToByte(_Float16 value) {
    float v = (float)value;
    if (!(v > 0.0f)) return 0; // also NaN
    if (v >= 1.0f) return 255;
    return (uint32_t)(v * 255.0f + 0.5f);
}

bool URConvertPixelsToBGRA8(URPixelLayout layout, const void *source, size_t sourcePitch,
                            uint8_t *destination, unsigned width, unsigned height) {
    const uint8_t *src = source;
    size_t pitch = (size_t)width * 4;
    for (unsigned y = 0; y < height; y++) {
        const uint8_t *row = src + (size_t)y * sourcePitch;
        uint32_t *out = (uint32_t *)(destination + (size_t)y * pitch);
        switch (layout) {
            case URPixelLayoutB8G8R8A8: {
                const uint32_t *in = (const uint32_t *)row;
                for (unsigned x = 0; x < width; x++) out[x] = in[x] | 0xFF000000u;
                break;
            }
            case URPixelLayoutR8G8B8A8: {
                const uint32_t *in = (const uint32_t *)row;
                for (unsigned x = 0; x < width; x++) {
                    uint32_t p = in[x];
                    out[x] = URPack(p & 0xFF, (p >> 8) & 0xFF, (p >> 16) & 0xFF);
                }
                break;
            }
            case URPixelLayoutA2B10G10R10: {
                const uint32_t *in = (const uint32_t *)row;
                for (unsigned x = 0; x < width; x++) {
                    uint32_t p = in[x];
                    out[x] = URPack((p >> 2) & 0xFF, (p >> 12) & 0xFF, (p >> 22) & 0xFF);
                }
                break;
            }
            case URPixelLayoutA2R10G10B10: {
                const uint32_t *in = (const uint32_t *)row;
                for (unsigned x = 0; x < width; x++) {
                    uint32_t p = in[x];
                    out[x] = URPack((p >> 22) & 0xFF, (p >> 12) & 0xFF, (p >> 2) & 0xFF);
                }
                break;
            }
            case URPixelLayoutR16G16B16A16Float: {
                const _Float16 *in = (const _Float16 *)row;
                for (unsigned x = 0; x < width; x++) {
                    out[x] = URPack(URUnitToByte(in[x * 4]), URUnitToByte(in[x * 4 + 1]), URUnitToByte(in[x * 4 + 2]));
                }
                break;
            }
            case URPixelLayoutR5G6B5: {
                const uint16_t *in = (const uint16_t *)row;
                for (unsigned x = 0; x < width; x++) {
                    uint32_t p = in[x];
                    uint32_t r = (p >> 11) & 0x1F, g = (p >> 5) & 0x3F, b = p & 0x1F;
                    out[x] = URPack(URExpand5(r), (g << 2) | (g >> 4), URExpand5(b));
                }
                break;
            }
            case URPixelLayoutA1R5G5B5: {
                const uint16_t *in = (const uint16_t *)row;
                for (unsigned x = 0; x < width; x++) {
                    uint32_t p = in[x];
                    out[x] = URPack(URExpand5((p >> 10) & 0x1F), URExpand5((p >> 5) & 0x1F), URExpand5(p & 0x1F));
                }
                break;
            }
            case URPixelLayoutR5G5B5A1: {
                const uint16_t *in = (const uint16_t *)row;
                for (unsigned x = 0; x < width; x++) {
                    uint32_t p = in[x];
                    out[x] = URPack(URExpand5(p >> 11), URExpand5((p >> 6) & 0x1F), URExpand5((p >> 1) & 0x1F));
                }
                break;
            }
            case URPixelLayoutUnsupported:
                return false;
        }
    }
    return true;
}
