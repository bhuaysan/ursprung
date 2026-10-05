// SPDX-License-Identifier: GPL-3.0-or-later
// Ursprung — parts of URLibretroCore that use libretro types, for other
// Objective-C code of the host (achievements). Not exposed to Swift.

#import "URLibretroCore.h"
#import "libretro.h"

NS_ASSUME_NONNULL_BEGIN

@interface URLibretroCore (Internal)

/// The memory map the core declared (SET_MEMORY_MAPS), or NULL. Valid on the
/// emulation thread until the core declares another one.
- (nullable const struct retro_memory_map *)memoryMap;

@end

NS_ASSUME_NONNULL_END
