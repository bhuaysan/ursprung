// SPDX-License-Identifier: GPL-3.0-or-later
// Ursprung — the runner's frame steps, for tests that drive a core frame by
// frame without the emulation thread, audio or pacing.

#import "UREmulationRunner.h"

NS_ASSUME_NONNULL_BEGIN

@interface UREmulationRunner ()

/// Runs the frame the player sees, with run-ahead and rewind recording.
- (void)runVisibleFrame:(NSUInteger)frameIndex fastForward:(BOOL)fastForward;
/// Runs the game one recorded state backwards.
- (void)stepBack;
/// Creates, resizes or frees the rewind buffer to follow the settings.
- (void)updateRewindBuffer;

@end

NS_ASSUME_NONNULL_END
