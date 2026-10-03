// SPDX-License-Identifier: GPL-3.0-or-later
// Ursprung — owns the emulation thread for one URLibretroCore: loads the game,
// paces frames against the audio clock and plays audio via AVAudioEngine.

#import <Foundation/Foundation.h>

#import "URLibretroCore.h"

NS_ASSUME_NONNULL_BEGIN

NS_SWIFT_NAME(EmulationRunner)
NS_SWIFT_SENDABLE
@interface UREmulationRunner : NSObject

- (instancetype)initWithCore:(URLibretroCore *)core NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) URLibretroCore *core;

/// Spawns the emulation thread and loads the game there. `completion` runs on
/// the main queue with nil on success.
- (void)startWithGamePath:(NSString *)path
               completion:(void (^NS_SWIFT_SENDABLE)(NSError *_Nullable error))completion;

/// Stops emulation, writes save RAM and unloads the game. `completion` runs
/// on the main queue once the thread has finished.
- (void)stopWithCompletion:(nullable void (^NS_SWIFT_SENDABLE)(void))completion;

/// Blocks until the emulation thread has saved and unloaded the game. For app
/// termination, where the main queue will not run again.
- (void)stopAndWait;

/// Runs `block` on the emulation thread between two frames.
- (void)performOnEmulationThread:(void (^NS_SWIFT_SENDABLE)(URLibretroCore *core))block NS_SWIFT_NAME(performOnEmulationThread(_:));

@property (atomic, getter=isPaused) BOOL paused;
@property (atomic) BOOL fastForward;
/// Output volume 0…1.
@property (atomic) float volume;
@property (atomic, readonly) double measuredFPS;
@property (atomic, readonly, getter=isRunning) BOOL running;

/// Called on the emulation thread right before a game that was asked to stop
/// is unloaded (also from -stopAndWait), e.g. to save its state. Not called
/// when the core shuts itself down.
@property (atomic, copy, nullable) void (^NS_SWIFT_SENDABLE willUnloadHandler)(URLibretroCore *core);

/// Called on the main queue if the core asks to shut down or the thread ends
/// unexpectedly.
@property (nonatomic, copy, nullable) void (^NS_SWIFT_SENDABLE terminationHandler)(void);

@end

NS_ASSUME_NONNULL_END
