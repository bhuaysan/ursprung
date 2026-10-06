// SPDX-License-Identifier: GPL-3.0-or-later
// Ursprung — a RetroArch slang preset compiled for Metal by librashader.
//
// Creating a chain parses the preset and compiles every pass, which takes
// from 50 ms to many seconds: do it off the main thread. A chain is not
// thread safe; after creation, only one thread may use it (the renderer's).

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@class URShaderParameter;

NS_ASSUME_NONNULL_BEGIN

/// Per-frame state handed to the shaders.
typedef struct NS_SWIFT_NAME(ShaderFrameOptions) {
    /// 1 while the game runs forwards, -1 while it rewinds.
    int32_t direction;
    /// The picture's intended aspect ratio (the core's, before rotation).
    float aspectRatio;
    /// The core's frame rate.
    float framesPerSecond;
    /// Milliseconds since the previous frame.
    uint32_t frameTimeDelta;
} URShaderFrameOptions;

NS_SWIFT_NAME(ShaderChain)
@interface URShaderChain : NSObject

/// Compiles the `.slangp` preset at `path`. `coreName` fills `$CORE$`
/// wildcards in the preset's paths, `rotation` (quarter turns) fills
/// `$CORE-REQ-ROT$`.
- (nullable instancetype)initWithPresetAtPath:(NSString *)path
                                        queue:(id<MTLCommandQueue>)queue
                                     coreName:(nullable NSString *)coreName
                                     rotation:(NSInteger)rotation
                                        error:(NSError **)error NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// The preset's parameters in declaration order, with the values it starts with.
@property (nonatomic, readonly, copy) NSArray<URShaderParameter *> *parameters;
/// The number of passes in the preset.
@property (nonatomic, readonly) NSInteger passCount;
/// Only the first passes render (for showing the output of one pass).
/// librashader 0.12.0 aborts the process (a Rust panic) in the next frame
/// when a later pass's output is read by an earlier pass (crt-royale); the
/// shader editor compiles a shortened preset instead.
@property (nonatomic) NSInteger activePassCount;

/// Renders `input` through all active passes into the whole of `output`.
/// `commandBuffer` must be empty; the caller commits it.
- (BOOL)renderTexture:(id<MTLTexture>)input
            toTexture:(id<MTLTexture>)output
        commandBuffer:(id<MTLCommandBuffer>)commandBuffer
           frameCount:(NSUInteger)frameCount
              options:(URShaderFrameOptions)options
                error:(NSError **)error NS_SWIFT_NAME(render(_:to:commandBuffer:frameCount:options:));

/// The current value of a parameter, or nil when the preset has none of that name.
- (nullable NSNumber *)valueForParameter:(NSString *)name;
/// Changes a parameter for the next frame, without recompiling.
- (BOOL)setValue:(float)value forParameter:(NSString *)name error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
