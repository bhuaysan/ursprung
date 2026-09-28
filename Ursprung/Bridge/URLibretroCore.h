// SPDX-License-Identifier: GPL-3.0-or-later
// Ursprung — libretro frontend host.
//
// URLibretroCore wraps a single dynamically loaded libretro core. libretro
// callbacks are global C functions, therefore only one core can be *active*
// (loaded with a game) at a time. All game-related calls (load, run, reset,
// serialize, unload) must happen on the same thread — UREmulationRunner owns
// that thread. Video, input and option accessors are thread-safe.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#import "URAudioRing.h"

NS_ASSUME_NONNULL_BEGIN

/// RetroPad buttons, values match RETRO_DEVICE_ID_JOYPAD_*.
typedef NS_ENUM(NSInteger, URRetroButton) {
    URRetroButtonB = 0,
    URRetroButtonY = 1,
    URRetroButtonSelect = 2,
    URRetroButtonStart = 3,
    URRetroButtonUp = 4,
    URRetroButtonDown = 5,
    URRetroButtonLeft = 6,
    URRetroButtonRight = 7,
    URRetroButtonA = 8,
    URRetroButtonX = 9,
    URRetroButtonL = 10,
    URRetroButtonR = 11,
    URRetroButtonL2 = 12,
    URRetroButtonR2 = 13,
    URRetroButtonL3 = 14,
    URRetroButtonR3 = 15,
} NS_SWIFT_NAME(RetroButton);

typedef NS_ENUM(NSInteger, URAnalogStick) {
    URAnalogStickLeft = 0,
    URAnalogStickRight = 1,
} NS_SWIFT_NAME(AnalogStick);

#define UR_MAX_PORTS 4
static const NSInteger URMaxPorts = UR_MAX_PORTS;

/// A core option as declared by the core (SET_VARIABLES / SET_CORE_OPTIONS*).
NS_SWIFT_NAME(CoreOption)
@interface URCoreOption : NSObject
@property (nonatomic, readonly, copy) NSString *key;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy, nullable) NSString *info;
@property (nonatomic, readonly, copy, nullable) NSString *category;
@property (nonatomic, readonly, copy) NSArray<NSString *> *values;
@property (nonatomic, readonly, copy) NSArray<NSString *> *labels;
@property (nonatomic, readonly, copy) NSString *defaultValue;
@end

NS_SWIFT_NAME(LibretroCore)
NS_SWIFT_SENDABLE
@interface URLibretroCore : NSObject

/// Opens the dylib and reads its system info. Does not initialise the core.
- (nullable instancetype)initWithPath:(NSString *)path error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly, copy) NSString *libraryName;
@property (nonatomic, readonly, copy) NSString *libraryVersion;
@property (nonatomic, readonly, copy) NSArray<NSString *> *validExtensions;
@property (nonatomic, readonly) BOOL needsFullPath;
@property (nonatomic, readonly) BOOL blockExtract;

// Configuration — set before -loadGameAtPath:.
@property (nonatomic, copy) NSString *systemDirectory;
@property (nonatomic, copy) NSString *saveDirectory;
@property (nonatomic, copy, nullable) NSString *saveRAMPath;
/// Values forced for specific core options (frontend defaults + user choices).
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *optionOverrides;
/// Two-letter language code reported to the core (e.g. "de").
@property (nonatomic, copy) NSString *languageCode;

// Lifecycle — call on the emulation thread.
- (BOOL)loadGameAtPath:(NSString *)path error:(NSError **)error;
- (void)runFrame;
- (void)reset;
- (void)unloadGame;
- (nullable NSData *)serializeState;
- (BOOL)unserializeState:(NSData *)state;
/// Writes battery-backed save RAM if it changed since the last write.
- (void)writeSaveRAMIfChanged;

// Multi-disc support — emulation thread.
@property (nonatomic, readonly) NSInteger diskCount;
@property (nonatomic, readonly) NSInteger currentDiskIndex;
- (BOOL)insertDiskAtIndex:(NSInteger)index;

// A/V information (valid after loading).
@property (nonatomic, readonly) double framesPerSecond;
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) float aspectRatio;
@property (nonatomic, readonly) unsigned baseWidth;
@property (nonatomic, readonly) unsigned baseHeight;
/// Rotation requested by the core, in multiples of 90° counter-clockwise.
@property (nonatomic, readonly) NSInteger rotation;
@property (nonatomic, readonly) BOOL usesHardwareRendering;
@property (nonatomic, readonly) BOOL shutdownRequested;
@property (nonatomic, readonly) URAudioRing *audioRing NS_RETURNS_INNER_POINTER;
/// Set by the core when the A/V timing changed; cleared by the reader.
- (BOOL)consumeAVInfoChange;

@property (atomic) BOOL fastForwarding;

// Video — thread-safe.
@property (nonatomic, readonly) uint64_t frameSerial;
/// Calls `block` with the most recent frame (BGRA8, little endian) while
/// holding the frame lock. Returns NO when no frame is available yet.
- (BOOL)accessLatestFrame:(void (NS_NOESCAPE ^)(const void *pixels, NSInteger width, NSInteger height, NSInteger pitch))block;
/// Snapshot of the latest frame (e.g. for save state thumbnails).
- (nullable CGImageRef)copyFrameImage CF_RETURNS_RETAINED;

// Input — thread-safe.
- (void)setButtonMask:(uint32_t)mask forPort:(NSInteger)port;
- (void)setAnalogStick:(URAnalogStick)stick x:(int16_t)x y:(int16_t)y forPort:(NSInteger)port;
/// Pointer/touch position in libretro coordinates (-0x7FFF…0x7FFF).
- (void)setPointerX:(int16_t)x y:(int16_t)y pressed:(BOOL)pressed;

// Options — thread-safe.
@property (nonatomic, readonly, copy) NSArray<URCoreOption *> *options;
- (nullable NSString *)valueForOption:(NSString *)key;
- (void)setValue:(NSString *)value forOption:(NSString *)key;

// Events — delivered on the main queue.
@property (nonatomic, copy, nullable) void (^NS_SWIFT_SENDABLE messageHandler)(NSString *message, NSTimeInterval duration);

@end

NS_ASSUME_NONNULL_END
