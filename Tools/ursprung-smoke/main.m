// SPDX-License-Identifier: GPL-3.0-or-later
// ursprung-smoke — headless test harness for the libretro host.
//
//   ursprung-smoke <core.dylib> <rom> [frames] [output.png] [system-dir]
//
// Loads a core and a game, runs the given number of frames without pacing and
// writes the last frame as PNG. Useful to verify cores on CI / new macOS
// versions without launching the app. URSMOKE_SHADER=<preset.slangp> renders
// the last frame through a RetroArch preset first, at URSMOKE_SHADER_HEIGHT
// (default 4× the frame) and the core's aspect ratio. URSMOKE_RENDERER=vulkan
// asks the core for Vulkan instead of OpenGL; the option defaults that go
// with it (SystemCatalog) are passed with URSMOKE_OPTIONS. The run fails when
// the game then renders with another API, unless URSMOKE_ALLOW_FALLBACK=1
// (to check the fallback itself). URSMOKE_LIST_OPTIONS=1
// prints the core's options with their values; URSMOKE_REPEAT=n plays the game
// n times in one process; URSMOKE_SAVE_STATE / URSMOKE_LOAD_STATE=<file> write
// the final state and load one after the first frame.

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "URLibretroCore.h"
#import "URShaderChain.h"

/// The core's latest frame rendered through `presetPath`, or NULL with a message on stderr.
static CGImageRef CopyShadedFrame(URLibretroCore *core, NSString *presetPath) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    NSError *error = nil;
    NSDate *start = [NSDate date];
    URShaderChain *chain = [[URShaderChain alloc] initWithPresetAtPath:presetPath queue:queue coreName:core.libraryName
                                                              rotation:core.rotation error:&error];
    if (!chain) {
        fprintf(stderr, "shader error: %s\n", error.localizedDescription.UTF8String);
        return NULL;
    }
    printf("shader: %ld passes, compiled in %.0f ms\n", (long)chain.passCount, -start.timeIntervalSinceNow * 1000);

    __block id<MTLTexture> input = nil;
    [core accessLatestFrame:^(const void *pixels, NSInteger width, NSInteger height, NSInteger pitch) {
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                              width:width height:height
                                                                                          mipmapped:NO];
        input = [device newTextureWithDescriptor:descriptor];
        [input replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:pixels bytesPerRow:pitch];
    }];
    if (!input) return NULL;

    const char *heightValue = getenv("URSMOKE_SHADER_HEIGHT");
    NSUInteger height = heightValue ? (NSUInteger)atol(heightValue) : input.height * 4;
    float aspect = core.aspectRatio > 0 ? core.aspectRatio : (float)input.width / input.height;
    NSUInteger width = (NSUInteger)lroundf(height * aspect);
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:width height:height
                                                                                      mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> output = [device newTextureWithDescriptor:descriptor];

    id<MTLCommandBuffer> buffer = [queue commandBuffer];
    URShaderFrameOptions options = {.direction = 1, .aspectRatio = aspect, .framesPerSecond = (float)core.framesPerSecond,
                                    .frameTimeDelta = (uint32_t)lround(1000 / core.framesPerSecond)};
    if (![chain renderTexture:input toTexture:output commandBuffer:buffer frameCount:(NSUInteger)core.frameSerial
                      options:options error:&error]) {
        fprintf(stderr, "shader error: %s\n", error.localizedDescription.UTF8String);
        return NULL;
    }
    [buffer commit];
    [buffer waitUntilCompleted];

    NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
    [output getBytes:pixels.mutableBytes bytesPerRow:width * 4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    // The final pass leaves alpha at 0: ignore it.
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, width * 4, space,
                                                 kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return image;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: %s <core.dylib> <rom> [frames] [output.png] [system-dir]\n", argv[0]);
            return 64;
        }
        NSString *corePath = @(argv[1]);
        NSString *romPath = @(argv[2]);
        NSInteger frames = argc > 3 ? atol(argv[3]) : 300;
        NSString *output = argc > 4 ? @(argv[4]) : nil;
        NSString *systemDir = argc > 5 ? @(argv[5]) : NSTemporaryDirectory();

        NSError *error = nil;
        URLibretroCore *core = [[URLibretroCore alloc] initWithPath:corePath error:&error];
        if (!core) {
            fprintf(stderr, "error: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        printf("core: %s %s (fullpath=%d, extensions=%s)\n", core.libraryName.UTF8String,
               core.libraryVersion.UTF8String, core.needsFullPath,
               [core.validExtensions componentsJoinedByString:@","].UTF8String);

        // URSMOKE_OPTIONS="key=value;key=value" overrides core options.
        const char *overrides = getenv("URSMOKE_OPTIONS");
        if (overrides) {
            NSMutableDictionary *options = [NSMutableDictionary dictionary];
            for (NSString *pair in [@(overrides) componentsSeparatedByString:@";"]) {
                NSArray *kv = [pair componentsSeparatedByString:@"="];
                if (kv.count == 2) options[kv[0]] = kv[1];
            }
            core.optionOverrides = options;
        }
        const char *renderer = getenv("URSMOKE_RENDERER");
        if (renderer && strcmp(renderer, "vulkan") == 0) core.preferredGraphicsAPI = URGraphicsAPIVulkan;
        core.systemDirectory = systemDir;
        core.saveDirectory = NSTemporaryDirectory();
        // URSMOKE_REPEAT=n loads, runs and unloads the game n times in one
        // process, to check that the core (and its GPU context) tears down cleanly.
        const char *repeatValue = getenv("URSMOKE_REPEAT");
        NSInteger rounds = repeatValue ? MAX(atol(repeatValue), 1) : 1;
        for (NSInteger round = 0; round < rounds; round++) {
            if (rounds > 1) printf("round %ld of %ld\n", (long)round + 1, (long)rounds);
            if (![core loadGameAtPath:romPath error:&error]) {
                fprintf(stderr, "error: %s\n", error.localizedDescription.UTF8String);
                return 2;
            }
            static const char *apis[] = {"none", "opengl", "vulkan"};
            printf("loaded: %.3f fps, %.1f Hz, %ux%u, aspect %.3f, hw=%s, options=%lu\n", core.framesPerSecond,
                   core.sampleRate, core.baseWidth, core.baseHeight, core.aspectRatio, apis[core.graphicsAPI],
                   (unsigned long)core.options.count);
            if (renderer && strcmp(renderer, "vulkan") == 0 && core.graphicsAPI != URGraphicsAPIVulkan
                && !getenv("URSMOKE_ALLOW_FALLBACK")) {
                fprintf(stderr, "error: asked for Vulkan, but the game renders with %s (renderer options in "
                                "URSMOKE_OPTIONS? URSMOKE_ALLOW_FALLBACK=1 accepts it)\n", apis[core.graphicsAPI]);
                [core unloadGame];
                return 2;
            }

            if (getenv("URSMOKE_LIST_OPTIONS")) {
                for (URCoreOption *option in core.options) {
                    printf("option %s = %s [%s]\n", option.key.UTF8String, [core valueForOption:option.key].UTF8String,
                           [option.values componentsJoinedByString:@"|"].UTF8String);
                }
            }

            // URSMOKE_REALTIME=1 paces frames at the core's rate (needed for cores
            // that boot asynchronously in wall-clock time, e.g. PPSSPP).
            BOOL realtime = getenv("URSMOKE_REALTIME") != NULL;
            NSDate *start = [NSDate date];
            NSTimeInterval busy = 0;
            size_t audioFrames = 0;
            // URSMOKE_LOAD_STATE=<file> loads a state after the first frame,
            // URSMOKE_SAVE_STATE=<file> writes one after the last.
            const char *loadState = getenv("URSMOKE_LOAD_STATE");
            for (NSInteger i = 0; i < frames; i++) {
                if (i == 1 && loadState) {
                    NSData *saved = [NSData dataWithContentsOfFile:@(loadState)];
                    printf("load state: %lu bytes, result=%d\n", (unsigned long)saved.length,
                           saved ? [core unserializeState:saved] : 0);
                }
                // Press START periodically so title screens advance.
                [core setButtonMask:((i / 30) % 2 == 1) ? (1u << URRetroButtonStart) : 0 forPort:0];
                NSDate *frameStart = [NSDate date];
                [core runFrame];
                busy -= frameStart.timeIntervalSinceNow;
                if (realtime) [NSThread sleepForTimeInterval:1.0 / core.framesPerSecond];
                audioFrames += URAudioRingAvailable(core.audioRing);
                URAudioRingClear(core.audioRing);
            }
            NSTimeInterval elapsed = -start.timeIntervalSinceNow;
            printf("ran %ld frames in %.2fs (%.0f fps uncapped, %.2f ms per frame in the core), %zu audio frames, %llu video frames\n",
                   (long)frames, elapsed, frames / elapsed, busy * 1000 / frames, audioFrames, core.frameSerial);

            NSData *state = [core serializeState];
            printf("save state: %lu bytes, restore=%d\n", (unsigned long)state.length,
                   state ? [core unserializeState:state] : 0);
            const char *saveState = getenv("URSMOKE_SAVE_STATE");
            if (saveState && state) [state writeToFile:@(saveState) atomically:YES];

            if (output) {
                const char *shader = getenv("URSMOKE_SHADER");
                CGImageRef image = shader ? CopyShadedFrame(core, @(shader)) : [core copyFrameImage];
                if (image) {
                    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
                        (__bridge CFURLRef)[NSURL fileURLWithPath:output], (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
                    CGImageDestinationAddImage(dest, image, NULL);
                    CGImageDestinationFinalize(dest);
                    CFRelease(dest);
                    printf("frame: %zux%zu -> %s\n", CGImageGetWidth(image), CGImageGetHeight(image), output.UTF8String);
                    CGImageRelease(image);
                } else {
                    printf("frame: none\n");
                }
            }
            [core unloadGame];
        }
        return core.frameSerial > 0 ? 0 : 3;
    }
}
