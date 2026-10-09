// SPDX-License-Identifier: GPL-3.0-or-later

#import "UREmulationRunner.h"
#import "UREmulationRunner+Testing.h"

#import "URRewindBuffer.h"

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
    _Atomic int _pendingSteps;
    void (^_stopCompletion)(void);
    BOOL _threadFinished; // guarded by @synchronized(self)

    AVAudioEngine *_engine;
    AVAudioSourceNode *_sourceNode;
    URAudioState *_audio;
    double _audioSampleRate;

    mach_timebase_info_data_t _timebase;
    dispatch_semaphore_t _finished;

    // Emulation thread only.
    URRewindBuffer *_rewind;
    NSInteger _rewindCapacityMB;
    NSUInteger _rewindInterval; // frames between recorded states
    NSMutableData *_state;      // the state of the latest frame (rewind, run-ahead)
    NSMutableData *_rewindState;
    BOOL _runAheadUsable;
}

/// States larger than this are not recorded for rewinding.
static const size_t URRewindMaxStateSize = 24 * 1024 * 1024;

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
        _fastForwardSpeed = 4.0;
        _rewindBufferMegabytes = 256;
        _state = [NSMutableData data];
        _rewindState = [NSMutableData data];
        _runAheadUsable = YES;
    }
    return self;
}

- (void)dealloc {
    free(_audio);
    URRewindBufferFree(_rewind);
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
    NSUInteger frameCount = 0;
    const uint64_t sramInterval = [self ticksFromSeconds:10.0];

    while (!atomic_load(&_stopRequested) && !core.shutdownRequested) {
        @autoreleasepool {
            [self drainCommands];

            if (self.paused && atomic_load(&_pendingSteps) > 0) {
                // One frame for the shader editor, silent: it would only click.
                atomic_fetch_sub(&_pendingSteps, 1);
                [self runVisibleFrame:frameCount++ fastForward:NO];
                URAudioRingClear(core.audioRing);
                nextFrame = mach_absolute_time();
                continue;
            }
            if (self.paused) {
                void (^frameHandler)(URLibretroCore *, BOOL) = self.frameHandler;
                if (frameHandler) frameHandler(core, NO);
                [NSThread sleepForTimeInterval:0.008];
                nextFrame = mach_absolute_time();
                continue;
            }

            atomic_store(&_pendingSteps, 0);
            [self updateRewindBuffer];
            BOOL fastForward = self.fastForward;
            core.fastForwarding = fastForward;
            if (self.rewinding && _rewind) {
                [self stepBack];
            } else {
                [self runVisibleFrame:frameCount++ fastForward:fastForward];
            }
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
                double speed = self.fastForwardSpeed;
                frameDuration = speed > 0 ? frameDuration / speed : 0;
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

- (void)stepFrame {
    if (self.paused) atomic_fetch_add(&_pendingSteps, 1);
}

#pragma mark - Frames

/// Runs the frame the player sees and hears, with run-ahead when enabled,
/// and records it for rewinding.
- (void)runVisibleFrame:(NSUInteger)frameIndex fastForward:(BOOL)fastForward {
    URLibretroCore *core = self.core;
    NSInteger runAhead = MIN(MAX(self.runAheadFrames, 0), 3);
    BOOL usesRunAhead = runAhead > 0 && _runAheadUsable && !fastForward && !core.usesHardwareRendering;
    BOOL records = _rewind && frameIndex % MAX(_rewindInterval, 1) == 0;

    if (usesRunAhead) core.videoEnabled = NO;
    [core runFrame];
    [core advanceTurboClock];
    void (^frameHandler)(URLibretroCore *, BOOL) = self.frameHandler;
    if (frameHandler) frameHandler(core, YES);

    BOOL hasState = (usesRunAhead || records) && [core serializeStateIntoBuffer:_state];
    if (records) [self recordState:hasState];

    if (!usesRunAhead) return;
    if (!hasState) {
        // The core cannot save states: no run-ahead for this game.
        _runAheadUsable = NO;
        core.videoEnabled = YES;
        return;
    }
    // Run ahead silently, show the last of those frames, and go back to the
    // real frame so the next input applies to it.
    core.audioEnabled = NO;
    for (NSInteger i = 0; i < runAhead; i++) {
        core.videoEnabled = i == runAhead - 1;
        [core runFrame];
    }
    core.videoEnabled = YES;
    core.audioEnabled = YES;
    if (![core unserializeStateFromBytes:_state.bytes length:_state.length]) {
        // The game stays ahead: no run-ahead for this game, or it would run
        // that many frames too fast from now on.
        _runAheadUsable = NO;
    }
}

/// Runs the game one recorded state backwards, silently.
- (void)stepBack {
    URLibretroCore *core = self.core;
    size_t size = _state.length;
    if (_rewindState.length != size) _rewindState.length = size;
    if (size == 0 || !URRewindBufferStepBack(_rewind, _rewindState.mutableBytes, size)) return; // nothing older
    if (![core unserializeStateFromBytes:_rewindState.bytes length:size]) {
        // The core takes states but can't go back to them: running on would
        // play forwards while rewinding.
        _rewindAvailability = URRewindAvailabilityUnsupported;
        URRewindBufferFree(_rewind);
        _rewind = NULL;
        _rewindSeconds = 0;
        // The game runs forwards again: so must the display and the shaders.
        self.rewinding = NO;
        void (^stopped)(void) = self.rewindStoppedHandler;
        if (stopped) dispatch_async(dispatch_get_main_queue(), stopped);
        return;
    }
    core.audioEnabled = NO;
    [core runFrame];
    core.audioEnabled = YES;
    double fps = core.framesPerSecond;
    _rewindSeconds = fps > 0 ? (double)(URRewindBufferDepth(_rewind) * MAX(_rewindInterval, 1)) / fps : 0;
    // The frame that follows rewinding continues from here.
    memcpy(_state.mutableBytes, _rewindState.bytes, size);
}

- (void)recordState:(BOOL)hasState {
    size_t size = _state.length;
    if (!hasState || size > URRewindMaxStateSize) {
        _rewindAvailability = URRewindAvailabilityUnsupported;
        URRewindBufferFree(_rewind);
        _rewind = NULL;
        return;
    }
    if (_rewindAvailability != URRewindAvailabilityAvailable) {
        // Larger states are recorded less often to keep the frame time down.
        _rewindInterval = size <= 512 * 1024 ? 1 : size <= 2 * 1024 * 1024 ? 2 : 4;
        _rewindAvailability = URRewindAvailabilityAvailable;
    }
    URRewindBufferPush(_rewind, _state.bytes, size);
    double fps = self.core.framesPerSecond;
    _rewindSeconds = fps > 0 ? (double)(URRewindBufferDepth(_rewind) * _rewindInterval) / fps : 0;
}

/// Creates, resizes or frees the rewind buffer to follow the settings.
- (void)updateRewindBuffer {
    BOOL enabled = self.rewindEnabled && _rewindAvailability != URRewindAvailabilityUnsupported;
    NSInteger megabytes = MAX(self.rewindBufferMegabytes, 16);
    if (!enabled) {
        if (_rewind) {
            URRewindBufferFree(_rewind);
            _rewind = NULL;
            _rewindSeconds = 0;
        }
        return;
    }
    if (_rewind && megabytes == _rewindCapacityMB) return;
    URRewindBufferFree(_rewind);
    _rewind = URRewindBufferCreate((size_t)megabytes * 1024 * 1024);
    _rewindCapacityMB = megabytes;
    _rewindSeconds = 0;
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
