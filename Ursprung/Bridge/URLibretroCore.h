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

/// A graphics API a core renders with.
typedef NS_ENUM(NSInteger, URGraphicsAPI) {
    /// Software rendering: the core hands over pixels.
    URGraphicsAPINone = 0,
    URGraphicsAPIOpenGL = 1,
    URGraphicsAPIVulkan = 2,
} NS_SWIFT_NAME(GraphicsAPI);

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
/// Real-time clock data (RETRO_MEMORY_RTC), for cores that keep it apart from save RAM.
@property (nonatomic, copy, nullable) NSString *rtcPath;
/// Values forced for specific core options (frontend defaults + user choices).
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *optionOverrides;
/// Two-letter language code reported to the core (e.g. "de").
@property (nonatomic, copy) NSString *languageCode;
/// The API the core is asked to render with (GET_PREFERRED_HW_RENDER):
/// OpenGL (default) or Vulkan. Vulkan is asked for only where available.
@property (nonatomic) URGraphicsAPI preferredGraphicsAPI;
/// Whether this Mac offers Vulkan (through MoltenVK).
@property (class, nonatomic, readonly) BOOL vulkanAvailable;

// Lifecycle — call on the emulation thread.
- (BOOL)loadGameAtPath:(NSString *)path error:(NSError **)error;
- (void)runFrame;
- (void)reset;
- (void)unloadGame;
/// Whether the loaded game can be saved as a state (the core reports a state size).
@property (nonatomic, readonly) BOOL supportsSaveStates;
- (nullable NSData *)serializeState;
- (BOOL)unserializeState:(NSData *)state;
/// Bytes a state of the loaded game takes; 0 without state support.
@property (nonatomic, readonly) size_t stateSize;
/// Serializes into `buffer`, resizing it to the state size. For states taken
/// every frame (rewind, run-ahead), without allocating each time.
- (BOOL)serializeStateIntoBuffer:(NSMutableData *)buffer;
- (BOOL)unserializeStateFromBytes:(const void *)bytes length:(size_t)length;
/// Writes battery-backed save RAM and RTC data if they changed since the last
/// write. A failure is reported once through `saveErrorHandler` until a
/// write succeeds again.
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
/// The API the loaded game renders with.
@property (nonatomic, readonly) URGraphicsAPI graphicsAPI;
/// The core asked to quit, or its GPU context failed and it must not run on.
@property (nonatomic, readonly) BOOL shutdownRequested;
@property (nonatomic, readonly) URAudioRing *audioRing NS_RETURNS_INNER_POINTER;
/// Set by the core when the A/V timing changed; cleared by the reader.
- (BOOL)consumeAVInfoChange;

@property (atomic) BOOL fastForwarding;
/// While NO, frames and sound the core produces are dropped (run-ahead,
/// rewinding); the core is told so through GET_AUDIO_VIDEO_ENABLE.
@property (atomic) BOOL videoEnabled;
@property (atomic) BOOL audioEnabled;

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
/// Buttons of `port` that fire repeatedly while held (RetroPad bit mask).
- (void)setTurboMask:(uint32_t)mask forPort:(NSInteger)port;
/// Frames a turbo button stays pressed, and then released (default 3).
@property (atomic) NSInteger turboPeriod;
/// Advances the turbo rhythm by one emulated frame; the runner calls it once
/// per frame that counts (not for run-ahead frames).
- (void)advanceTurboClock;

/// Whether the core reads a keyboard (it registered a keyboard callback).
@property (nonatomic, readonly) BOOL wantsKeyboard;
/// A key of the emulated keyboard (`retroKey` is a RETROK_* value).
/// `character` is the UTF-32 text the key produces, 0 for none;
/// `modifiers` are RETROKMOD_* flags. Thread-safe; the core sees the key
/// before its next frame.
- (void)setKey:(unsigned)retroKey pressed:(BOOL)pressed character:(uint32_t)character modifiers:(uint16_t)modifiers;
/// Releases every key of the emulated keyboard.
- (void)releaseAllKeys;

// Options — thread-safe.
@property (nonatomic, readonly, copy) NSArray<URCoreOption *> *options;
- (nullable NSString *)valueForOption:(NSString *)key;
- (void)setValue:(NSString *)value forOption:(NSString *)key;

// Cheats — emulation thread.
/// Whether the core exports the cheat functions; many still ignore them.
@property (nonatomic, readonly) BOOL supportsCheats;
- (void)resetCheats;
- (void)setCheatAtIndex:(NSUInteger)index enabled:(BOOL)enabled code:(NSString *)code;

// Memory — emulation thread.
/// A memory region of the loaded game (RETRO_MEMORY_*), or NULL.
- (nullable void *)memoryDataOfType:(unsigned)type size:(size_t *)size NS_RETURNS_INNER_POINTER;
/// Bumped whenever the core declares a new memory map (SET_MEMORY_MAPS).
@property (nonatomic, readonly) NSUInteger memoryMapRevision;

// Events — delivered on the main queue.
@property (nonatomic, copy, nullable) void (^NS_SWIFT_SENDABLE messageHandler)(NSString *message, NSTimeInterval duration);
/// A battery save or clock file could not be written; the reason is the system's description.
@property (nonatomic, copy, nullable) void (^NS_SWIFT_SENDABLE saveErrorHandler)(NSString *reason);
/// The core changed a rumble motor of `port`: `strong` is the large motor,
/// otherwise the small one; `strength` 0…0xFFFF. Called on the emulation
/// thread, only when the value changed.
@property (atomic, copy, nullable) void (^NS_SWIFT_SENDABLE rumbleHandler)(NSInteger port, BOOL strong, uint16_t strength);

@end

NS_ASSUME_NONNULL_END
