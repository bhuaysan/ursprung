// SPDX-License-Identifier: GPL-3.0-or-later
// Exposes the Objective-C libretro host, the shader presets and zlib to Swift.

#import "URLibretroCore.h"
#import "URLibretroCore+Testing.h"
#import "UREmulationRunner.h"
#import "UREmulationRunner+Testing.h"
#import "URAudioRing.h"
#import "URAchievements.h"
#import "URRewindBuffer.h"
#import "URPixelConversion.h"
#import "URShaderPreset.h"
#import "URShaderChain.h"

#include <zlib.h>
