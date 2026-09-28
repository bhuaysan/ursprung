// SPDX-License-Identifier: GPL-3.0-or-later
// Ursprung — offscreen OpenGL context used by libretro cores that request
// hardware rendering (N64, PSP, Dreamcast, …). The core renders into an FBO;
// the frame is read back into system memory and displayed through Metal.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface URGLContext : NSObject

/// Creates a context. `coreProfile` selects an OpenGL 4.1 core profile,
/// otherwise the legacy 2.1 profile is used.
- (nullable instancetype)initWithCoreProfile:(BOOL)coreProfile
                                       depth:(BOOL)depth
                                     stencil:(BOOL)stencil
                                       error:(NSError **)error;

- (void)makeCurrent;
+ (void)clearCurrent;

/// (Re)creates the framebuffer object for the given maximum size.
- (BOOL)resizeFramebufferWidth:(unsigned)width height:(unsigned)height;

@property (nonatomic, readonly) unsigned framebufferID;
@property (nonatomic, readonly) unsigned framebufferWidth;
@property (nonatomic, readonly) unsigned framebufferHeight;

/// Reads `width`×`height` pixels from the FBO as BGRA into `destination`
/// (row pitch = width * 4). Flips vertically when `bottomLeftOrigin`.
- (void)readPixelsWidth:(unsigned)width
                 height:(unsigned)height
       bottomLeftOrigin:(BOOL)bottomLeftOrigin
            destination:(uint8_t *)destination;

/// Resolves an OpenGL entry point for the core.
+ (nullable void *)procAddress:(const char *)symbol;

@end

NS_ASSUME_NONNULL_END
