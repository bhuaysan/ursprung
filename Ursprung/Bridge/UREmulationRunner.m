// SPDX-License-Identifier: GPL-3.0-or-later

#import "UREmulationRunner.h"

#import <AVFoundation/AVFoundation.h>
#include <mach/mach_time.h>
#include <stdatomic.h>

/// Shared between the emulation thread and the audio render thread.
typedef struct {
    URAudioRing *ring;
    _Atomic size_t primeFrames; // start playback once this many frames are buffered
    bool primed; // render thread only, once playback starts
    _Atomic float volume;
} URAudioState;

@implementation UREmulationRunner {
    NSThread *_thread;
    NSLock *_commandLock;
    NSMutableArray<void (^)(URLibretroCore *)> *_commands;
    _Atomic bool _stopRequested;
    void (^_stopCompletion)(void);
    BOOL _threadFinished; // guarded by @synchronized(self)

    AVAudioEngine *_engine;
    AVAudioSourceNode *_sourceNode;
    URAudioState *_audio;
    double _audioSampleRate;

    mach_timebase_info_data_t _timebase;
    dispatch_semaphore_t _finished;
}

- (instancetype)initWithCore:(URLibretroCore *)core {
    self = [super init];
    if (self) {
        _core = core;
        _commandLock = [NSLock new];
        _commands = [NSMutableArray array];
        _finished = dispatch_semaphore_create(0);
        _audio = calloc(1, sizeof(URAudioState));
        atomic_store(&_audio->volume, 1.0f);
        mach_timebase_info(&_timebase);
    }
    return self;
}

- (void)dealloc {
    free(_audio);
}

- (void)setVolume:(float)volume {
    atomic_store(&_audio->volume, MAX(0.0f, MIN(1.0f, volume)));
}

- (float)volume {
    return atomic_load(&_audio->volume);
}

#pragma mark - Public API

- (void)startWithGamePath:(NSString *)path completion:(void (^)(NSError *_Nullable))completion {
    NSAssert(_thread == nil, @"Runner already started");
    __weak typeof(self) weakSelf = self;
    _thread = [[NSThread alloc] initWithBlock:^{
        [weakSelf threadMainWithPath:path completion:completion];
    }];
    _thread.name = @"Ursprung Emulation";
    _thread.qualityOfService = NSQualityOfServiceUserInteractive;
    _thread.stackSize = 16 * 1024 * 1024; // some cores recurse deeply
    [_thread start];
}

- (void)stopWithCompletion:(nullable void (^)(void))completion {
    // The thread counts as alive from start until it has unloaded the game,
    // including while the game is still loading (`running` is not yet set
    // then). Checking and registering the completion under one lock means the
    // thread either sees the request or has already finished.
    BOOL alive;
    @synchronized(self) {
        alive = _thread != nil && !_threadFinished;
        if (alive) {
            _stopCompletion = [completion copy];
            atomic_store(&_stopRequested, true);
        }
    }
    if (!alive && completion) dispatch_async(dispatch_get_main_queue(), completion);
}

- (void)stopAndWait {
    BOOL alive;
    @synchronized(self) {
        alive = _thread != nil && !_threadFinished;
        if (alive) atomic_store(&_stopRequested, true);
    }
    if (!alive) return;
    dispatch_semaphore_wait(_finished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
}

- (void)performOnEmulationThread:(void (^)(URLibretroCore *))block {
    [_commandLock lock];
    [_commands addObject:[block copy]];
    [_commandLock unlock];
}

#pragma mark - Thread

- (double)secondsFromTicks:(uint64_t)ticks {
    return (double)ticks * _timebase.numer / _timebase.denom / 1e9;
}

- (uint64_t)ticksFromSeconds:(double)seconds {
    return (uint64_t)(seconds * 1e9 * _timebase.denom / _timebase.numer);
}

- (void)threadMainWithPath:(NSString *)path completion:(void (^)(NSError *_Nullable))completion {
    URLibretroCore *core = self.core;
    NSError *error = nil;
    BOOL loaded;
    @autoreleasepool {
        loaded = [core loadGameAtPath:path error:&error];
    }
    if (!loaded) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
        [self finishThreadAfterRunningGame:NO];
        return;
    }

    _running = YES;
    [self startAudioWithSampleRate:core.sampleRate];
    dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });

    uint64_t nextFrame = mach_absolute_time();
    uint64_t lastSRAMWrite = nextFrame;
    uint64_t fpsWindowStart = nextFrame;
    NSInteger fpsFrames = 0;
    const uint64_t sramInterval = [self ticksFromSeconds:10.0];

    while (!atomic_load(&_stopRequested) && !core.shutdownRequested) {
        @autoreleasepool {
            [self drainCommands];

            if (self.paused) {
                [NSThread sleepForTimeInterval:0.008];
                nextFrame = mach_absolute_time();
                continue;
            }

            BOOL fastForward = self.fastForward;
            core.fastForwarding = fastForward;
            [core runFrame];
            fpsFrames++;

            if ([core consumeAVInfoChange] && fabs(core.sampleRate - _audioSampleRate) > 1.0) {
                [self stopAudio];
                [self startAudioWithSampleRate:core.sampleRate];
            }

            uint64_t now = mach_absolute_time();
            if (now - lastSRAMWrite > sramInterval) {
                [core writeSaveRAMIfChanged];
                lastSRAMWrite = now;
            }
            if (now - fpsWindowStart > [self ticksFromSeconds:1.0]) {
                _measuredFPS = fpsFrames / [self secondsFromTicks:now - fpsWindowStart];
                fpsFrames = 0;
                fpsWindowStart = now;
            }

            // Frame pacing. Audio is the master clock: nudge the frame
            // duration by up to ±0.5 % to keep the ring buffer near its target.
            double frameDuration = 1.0 / core.framesPerSecond;
            if (fastForward) {
                frameDuration /= 4.0;
                URAudioRingClear(core.audioRing);
            } else {
                double target = (double)atomic_load(&_audio->primeFrames);
                double fill = (double)URAudioRingAvailable(core.audioRing);
                if (target > 0) {
                    double deviation = MAX(-1.0, MIN(1.0, (fill - target) / target));
                    frameDuration *= 1.0 + 0.005 * deviation;
                    if (fill > target * 4) URAudioRingClear(core.audioRing);
                }
            }

            nextFrame += [self ticksFromSeconds:frameDuration];
            now = mach_absolute_time();
            if (now > nextFrame + [self ticksFromSeconds:frameDuration * 4]) {
                nextFrame = now; // fell far behind: resynchronise instead of racing
            } else if (nextFrame > now) {
                mach_wait_until(nextFrame);
            }
        }
    }

    [self stopAudio];
    @autoreleasepool {
        [self drainCommands];
        void (^willUnload)(URLibretroCore *) = self.willUnloadHandler;
        if (willUnload && atomic_load(&_stopRequested)) willUnload(core);
        [core unloadGame];
    }
    [self finishThreadAfterRunningGame:YES];
}

/// Marks the thread as finished and reports it. Runs as the last step of every
/// thread exit, whether or not the game ever loaded.
- (void)finishThreadAfterRunningGame:(BOOL)ranGame {
    void (^stopCompletion)(void);
    BOOL wasRequested;
    @synchronized(self) {
        _running = NO;
        _threadFinished = YES;
        stopCompletion = _stopCompletion;
        _stopCompletion = nil;
        wasRequested = atomic_load(&_stopRequested);
    }
    dispatch_semaphore_signal(_finished);

    void (^termination)(void) = self.terminationHandler;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (stopCompletion) stopCompletion();
        if (ranGame && !wasRequested && termination) termination();
    });
}

- (void)drainCommands {
    [_commandLock lock];
    NSArray *pending = [_commands copy];
    [_commands removeAllObjects];
    [_commandLock unlock];
    for (void (^command)(URLibretroCore *) in pending) {
        command(self.core);
    }
}

#pragma mark - Audio

- (void)startAudioWithSampleRate:(double)sampleRate {
    _audioSampleRate = sampleRate;
    URAudioState *state = _audio;
    state->ring = self.core.audioRing;
    atomic_store(&state->primeFrames, (size_t)(sampleRate * 0.064)); // ~64 ms latency target
    state->primed = false;

    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate channels:2];
    _sourceNode = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp, AVAudioFrameCount frameCount, AudioBufferList *output) {
        float *left = output->mBuffers[0].mData;
        float *right = output->mNumberBuffers > 1 ? output->mBuffers[1].mData : left;
        size_t read = URAudioRingRender(state->ring, &state->primed, atomic_load(&state->primeFrames),
                                        left, right, frameCount, atomic_load(&state->volume));
        if (read == 0) *isSilence = YES;
        return noErr;
    }];

    _engine = [AVAudioEngine new];
    [_engine attachNode:_sourceNode];
    [_engine connect:_sourceNode to:_engine.mainMixerNode format:format];
    NSError *error = nil;
    if (![_engine startAndReturnError:&error]) {
        NSLog(@"[Ursprung] Audio engine failed to start: %@", error);
    }
}

- (void)stopAudio {
    [_engine stop];
    if (_sourceNode) [_engine detachNode:_sourceNode];
    _sourceNode = nil;
    _engine = nil;
}

@end
