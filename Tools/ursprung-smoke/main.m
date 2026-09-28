// SPDX-License-Identifier: GPL-3.0-or-later
// ursprung-smoke — headless test harness for the libretro host.
//
//   ursprung-smoke <core.dylib> <rom> [frames] [output.png] [system-dir]
//
// Loads a core and a game, runs the given number of frames without pacing and
// writes the last frame as PNG. Useful to verify cores on CI / new macOS
// versions without launching the app.

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "URLibretroCore.h"

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
        core.systemDirectory = systemDir;
        core.saveDirectory = NSTemporaryDirectory();
        if (![core loadGameAtPath:romPath error:&error]) {
            fprintf(stderr, "error: %s\n", error.localizedDescription.UTF8String);
            return 2;
        }
        printf("loaded: %.3f fps, %.1f Hz, %ux%u, aspect %.3f, hw=%d, options=%lu\n", core.framesPerSecond,
               core.sampleRate, core.baseWidth, core.baseHeight, core.aspectRatio, core.usesHardwareRendering,
               (unsigned long)core.options.count);

        // URSMOKE_REALTIME=1 paces frames at the core's rate (needed for cores
        // that boot asynchronously in wall-clock time, e.g. PPSSPP).
        BOOL realtime = getenv("URSMOKE_REALTIME") != NULL;
        NSDate *start = [NSDate date];
        size_t audioFrames = 0;
        for (NSInteger i = 0; i < frames; i++) {
            // Press START periodically so title screens advance.
            [core setButtonMask:((i / 30) % 2 == 1) ? (1u << URRetroButtonStart) : 0 forPort:0];
            [core runFrame];
            if (realtime) [NSThread sleepForTimeInterval:1.0 / core.framesPerSecond];
            audioFrames += URAudioRingAvailable(core.audioRing);
            URAudioRingClear(core.audioRing);
        }
        NSTimeInterval elapsed = -start.timeIntervalSinceNow;
        printf("ran %ld frames in %.2fs (%.0f fps uncapped), %zu audio frames, %llu video frames\n", (long)frames,
               elapsed, frames / elapsed, audioFrames, core.frameSerial);

        NSData *state = [core serializeState];
        printf("save state: %lu bytes, restore=%d\n", (unsigned long)state.length,
               state ? [core unserializeState:state] : 0);

        if (output) {
            CGImageRef image = [core copyFrameImage];
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
        return core.frameSerial > 0 ? 0 : 3;
    }
}
