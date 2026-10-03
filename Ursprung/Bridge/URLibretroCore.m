// SPDX-License-Identifier: GPL-3.0-or-later

#import "URLibretroCore.h"

#import "URGLContext.h"
#import "libretro.h"

#include <dlfcn.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <os/log.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <sys/xattr.h>

static NSString *const URCoreErrorDomain = @"Ursprung.Core";

static os_log_t URCoreLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("io.github.bhuaysan.Ursprung", "core"); });
    return log;
}

#pragma mark - Core option model

@implementation URCoreOption
- (instancetype)initWithKey:(NSString *)key
                      title:(NSString *)title
                       info:(nullable NSString *)info
                   category:(nullable NSString *)category
                     values:(NSArray<NSString *> *)values
                     labels:(NSArray<NSString *> *)labels
               defaultValue:(NSString *)defaultValue {
    self = [super init];
    if (self) {
        _key = [key copy];
        _title = [title copy];
        _info = [info copy];
        _category = [category copy];
        _values = [values copy];
        _labels = [labels copy];
        _defaultValue = [defaultValue copy];
    }
    return self;
}
@end

#pragma mark - Symbols

typedef struct {
    void (*init)(void);
    void (*deinit)(void);
    unsigned (*api_version)(void);
    void (*get_system_info)(struct retro_system_info *);
    void (*get_system_av_info)(struct retro_system_av_info *);
    void (*set_environment)(retro_environment_t);
    void (*set_video_refresh)(retro_video_refresh_t);
    void (*set_audio_sample)(retro_audio_sample_t);
    void (*set_audio_sample_batch)(retro_audio_sample_batch_t);
    void (*set_input_poll)(retro_input_poll_t);
    void (*set_input_state)(retro_input_state_t);
    void (*set_controller_port_device)(unsigned, unsigned);
    void (*reset)(void);
    void (*run)(void);
    size_t (*serialize_size)(void);
    bool (*serialize)(void *, size_t);
    bool (*unserialize)(const void *, size_t);
    bool (*load_game)(const struct retro_game_info *);
    void (*unload_game)(void);
    void *(*get_memory_data)(unsigned);
    size_t (*get_memory_size)(unsigned);
} URCoreSymbols;

typedef struct {
    uint8_t *data;
    size_t capacity;
    unsigned width;
    unsigned height;
} URFrameBuffer;

// Global input state (one active core at a time).
static _Atomic uint32_t gButtonMasks[UR_MAX_PORTS];
static _Atomic int16_t gAnalog[UR_MAX_PORTS][2][2];
static _Atomic int16_t gPointerX, gPointerY;
static _Atomic bool gPointerPressed;

@class URLibretroCore;
static __unsafe_unretained URLibretroCore *gActiveCore = nil;

@interface URLibretroCore ()
- (void)postMessage:(NSString *)message duration:(NSTimeInterval)duration;
@end

@implementation URLibretroCore {
@public
    void *_handle;
    URCoreSymbols _sym;

    char *_systemDirC;
    char *_saveDirC;
    char *_corePathC;
    char *_gamePathC;
    char *_usernameC;
    NSData *_gameData;

    enum retro_pixel_format _pixelFormat;
    struct retro_system_av_info _avInfo;
    _Atomic bool _avInfoChanged;

    // Video
    os_unfair_lock _frameLock;
    URFrameBuffer _back;
    URFrameBuffer _ready;
    BOOL _hasFrame;
    _Atomic uint64_t _frameSerial;

    // Audio
    URAudioRing _ring;

    // Hardware rendering
    struct retro_hw_render_callback _hwRender;
    URGLContext *_gl;

    // Options
    NSMutableDictionary<NSString *, NSData *> *_optionValues;
    // Every option value string ever handed to the core, keyed by its text.
    // Cores may still read a pointer from GET_VARIABLE when the user changes
    // the option, so these strings live as long as the core.
    NSMutableDictionary<NSString *, NSData *> *_optionCStrings;
    NSMutableArray<URCoreOption *> *_optionDefinitions;
    BOOL _optionsUpdated;

    // Save RAM
    NSData *_lastSavedRAM;

    // Misc callbacks
    struct retro_frame_time_callback _frameTimeCallback;
    BOOL _hasFrameTimeCallback;
    struct retro_disk_control_ext_callback _disk;
    BOOL _hasDiskControl;
    BOOL _gameLoaded;
    BOOL _initialized;
    NSInteger _rotation;
    BOOL _shutdownRequested;
}

#pragma mark - Init

- (nullable instancetype)initWithPath:(NSString *)path error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    _path = [path copy];
    _systemDirectory = NSTemporaryDirectory();
    _saveDirectory = NSTemporaryDirectory();
    _optionOverrides = @{};
    _languageCode = @"en";
    _frameLock = OS_UNFAIR_LOCK_INIT;
    _optionValues = [NSMutableDictionary dictionary];
    _optionCStrings = [NSMutableDictionary dictionary];
    _optionDefinitions = [NSMutableArray array];
    _pixelFormat = RETRO_PIXEL_FORMAT_0RGB1555;

    // Files downloaded by the app must not carry a quarantine flag, otherwise
    // dlopen refuses them.
    removexattr(path.fileSystemRepresentation, "com.apple.quarantine", 0);

    _handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
    if (!_handle) {
        if (error) *error = [NSError errorWithDomain:URCoreErrorDomain code:1 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not load core: %s", dlerror()]
        }];
        return nil;
    }

#define UR_LOAD(field, name)                                                                  \
    _sym.field = dlsym(_handle, name);                                                        \
    if (!_sym.field) {                                                                        \
        if (error) *error = [NSError errorWithDomain:URCoreErrorDomain code:2 userInfo:@{     \
            NSLocalizedDescriptionKey: @"The core is missing the libretro symbol " @name "."  \
        }];                                                                                   \
        dlclose(_handle);                                                                     \
        _handle = NULL;                                                                       \
        return nil;                                                                           \
    }
    UR_LOAD(init, "retro_init")
    UR_LOAD(deinit, "retro_deinit")
    UR_LOAD(api_version, "retro_api_version")
    UR_LOAD(get_system_info, "retro_get_system_info")
    UR_LOAD(get_system_av_info, "retro_get_system_av_info")
    UR_LOAD(set_environment, "retro_set_environment")
    UR_LOAD(set_video_refresh, "retro_set_video_refresh")
    UR_LOAD(set_audio_sample, "retro_set_audio_sample")
    UR_LOAD(set_audio_sample_batch, "retro_set_audio_sample_batch")
    UR_LOAD(set_input_poll, "retro_set_input_poll")
    UR_LOAD(set_input_state, "retro_set_input_state")
    UR_LOAD(set_controller_port_device, "retro_set_controller_port_device")
    UR_LOAD(reset, "retro_reset")
    UR_LOAD(run, "retro_run")
    UR_LOAD(serialize_size, "retro_serialize_size")
    UR_LOAD(serialize, "retro_serialize")
    UR_LOAD(unserialize, "retro_unserialize")
    UR_LOAD(load_game, "retro_load_game")
    UR_LOAD(unload_game, "retro_unload_game")
    UR_LOAD(get_memory_data, "retro_get_memory_data")
    UR_LOAD(get_memory_size, "retro_get_memory_size")
#undef UR_LOAD

    if (_sym.api_version() != RETRO_API_VERSION) {
        if (error) *error = [NSError errorWithDomain:URCoreErrorDomain code:3 userInfo:@{
            NSLocalizedDescriptionKey: @"The core uses an incompatible libretro API version."
        }];
        dlclose(_handle);
        _handle = NULL;
        return nil;
    }

    struct retro_system_info info = {0};
    _sym.get_system_info(&info);
    _libraryName = info.library_name ? @(info.library_name) : path.lastPathComponent;
    _libraryVersion = info.library_version ? @(info.library_version) : @"";
    _needsFullPath = info.need_fullpath;
    _blockExtract = info.block_extract;
    NSString *extensions = info.valid_extensions ? @(info.valid_extensions) : @"";
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *ext in [extensions componentsSeparatedByString:@"|"]) {
        if (ext.length) [list addObject:ext.lowercaseString];
    }
    _validExtensions = list;
    return self;
}

- (void)dealloc {
    if (_gameLoaded) [self unloadGame];
    if (_handle) dlclose(_handle);
    free(_systemDirC);
    free(_saveDirC);
    free(_corePathC);
    free(_gamePathC);
    free(_usernameC);
    free(_back.data);
    free(_ready.data);
    URAudioRingFree(&_ring);
}

- (URAudioRing *)audioRing { return &_ring; }

#pragma mark - Lifecycle

- (BOOL)loadGameAtPath:(NSString *)path error:(NSError **)error {
    if (gActiveCore && gActiveCore != self) {
        if (error) *error = [NSError errorWithDomain:URCoreErrorDomain code:4 userInfo:@{
            NSLocalizedDescriptionKey: @"Another game is already running."
        }];
        return NO;
    }
    gActiveCore = self;

    free(_systemDirC); _systemDirC = strdup(self.systemDirectory.fileSystemRepresentation);
    free(_saveDirC); _saveDirC = strdup(self.saveDirectory.fileSystemRepresentation);
    free(_corePathC); _corePathC = strdup(self.path.fileSystemRepresentation);
    free(_gamePathC); _gamePathC = strdup(path.fileSystemRepresentation);
    free(_usernameC); _usernameC = strdup(NSUserName().UTF8String ?: "Player");

    for (NSInteger port = 0; port < URMaxPorts; port++) {
        atomic_store(&gButtonMasks[port], 0);
        for (int s = 0; s < 2; s++) {
            atomic_store(&gAnalog[port][s][0], 0);
            atomic_store(&gAnalog[port][s][1], 0);
        }
    }

    extern bool URCoreEnvironment(unsigned cmd, void *data);
    extern void URCoreVideoRefresh(const void *data, unsigned width, unsigned height, size_t pitch);
    extern void URCoreAudioSample(int16_t left, int16_t right);
    extern size_t URCoreAudioSampleBatch(const int16_t *data, size_t frames);
    extern void URCoreInputPoll(void);
    extern int16_t URCoreInputState(unsigned port, unsigned device, unsigned index, unsigned id);

    _sym.set_environment(URCoreEnvironment);
    _sym.init();
    _initialized = YES;
    _sym.set_video_refresh(URCoreVideoRefresh);
    _sym.set_audio_sample(URCoreAudioSample);
    _sym.set_audio_sample_batch(URCoreAudioSampleBatch);
    _sym.set_input_poll(URCoreInputPoll);
    _sym.set_input_state(URCoreInputState);

    struct retro_game_info game = {0};
    game.path = _gamePathC;
    if (!_needsFullPath) {
        _gameData = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];
        if (!_gameData) {
            [self teardownAfterFailedLoad];
            return NO;
        }
        game.data = _gameData.bytes;
        game.size = _gameData.length;
    }

    if (!_sym.load_game(&game)) {
        if (error) *error = [NSError errorWithDomain:URCoreErrorDomain code:5 userInfo:@{
            NSLocalizedDescriptionKey: @"The core could not load this game. The file may be damaged, unsupported, or a required BIOS file is missing."
        }];
        [self teardownAfterFailedLoad];
        return NO;
    }
    _gameLoaded = YES;

    _sym.get_system_av_info(&_avInfo);
    [self sanitizeAVInfo];
    URAudioRingFree(&_ring);
    URAudioRingInit(&_ring, (size_t)MAX(_avInfo.timing.sample_rate, 8000.0) / 2); // 500 ms
    for (unsigned port = 0; port < URMaxPorts; port++) {
        _sym.set_controller_port_device(port, RETRO_DEVICE_JOYPAD);
    }

    if (_gl) {
        [_gl makeCurrent];
        [_gl resizeFramebufferWidth:_avInfo.geometry.max_width height:_avInfo.geometry.max_height];
        if (_hwRender.context_reset) _hwRender.context_reset();
    }

    [self loadSaveRAM];
    return YES;
}

- (void)teardownAfterFailedLoad {
    if (_initialized) _sym.deinit();
    _initialized = NO;
    _gameData = nil;
    _gl = nil;
    gActiveCore = nil;
}

- (void)sanitizeAVInfo {
    if (_avInfo.timing.fps <= 0 || _avInfo.timing.fps > 500) _avInfo.timing.fps = 60.0;
    if (_avInfo.timing.sample_rate <= 0) _avInfo.timing.sample_rate = 44100.0;
    if (_avInfo.geometry.max_width < _avInfo.geometry.base_width) _avInfo.geometry.max_width = _avInfo.geometry.base_width;
    if (_avInfo.geometry.max_height < _avInfo.geometry.base_height) _avInfo.geometry.max_height = _avInfo.geometry.base_height;
}

- (void)runFrame {
    if (!_gameLoaded) return;
    if (_hasFrameTimeCallback && _frameTimeCallback.callback) {
        _frameTimeCallback.callback(_frameTimeCallback.reference);
    }
    if (_gl) [_gl makeCurrent];
    _sym.run();
}

- (void)reset {
    if (_gameLoaded) _sym.reset();
}

- (void)unloadGame {
    if (!_gameLoaded) return;
    [self writeSaveRAMIfChanged];
    if (_gl) {
        [_gl makeCurrent];
        if (_hwRender.context_destroy) _hwRender.context_destroy();
    }
    _sym.unload_game();
    _sym.deinit();
    _gameLoaded = NO;
    _initialized = NO;
    _gl = nil;
    [URGLContext clearCurrent];
    _gameData = nil;
    if (gActiveCore == self) gActiveCore = nil;
}

- (nullable NSData *)serializeState {
    if (!_gameLoaded) return nil;
    size_t size = _sym.serialize_size();
    if (size == 0) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (!_sym.serialize(data.mutableBytes, size)) return nil;
    return data;
}

- (BOOL)unserializeState:(NSData *)state {
    if (!_gameLoaded || state.length == 0) return NO;
    return _sym.unserialize(state.bytes, state.length);
}

#pragma mark - Save RAM

- (void)loadSaveRAM {
    if (!self.saveRAMPath) return;
    void *memory = _sym.get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t size = _sym.get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!memory || size == 0) return;
    NSData *file = [NSData dataWithContentsOfFile:self.saveRAMPath];
    if (file.length) {
        memcpy(memory, file.bytes, MIN(size, file.length));
    }
    _lastSavedRAM = [NSData dataWithBytes:memory length:size];
}

- (void)writeSaveRAMIfChanged {
    if (!_gameLoaded || !self.saveRAMPath) return;
    void *memory = _sym.get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t size = _sym.get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!memory || size == 0) return;
    if (_lastSavedRAM.length == size && memcmp(_lastSavedRAM.bytes, memory, size) == 0) return;

    NSData *snapshot = [NSData dataWithBytes:memory length:size];
    NSString *directory = self.saveRAMPath.stringByDeletingLastPathComponent;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    if ([snapshot writeToFile:self.saveRAMPath atomically:YES]) {
        _lastSavedRAM = snapshot;
    }
}

#pragma mark - Disks

- (NSInteger)diskCount {
    return (_hasDiskControl && _disk.get_num_images) ? (NSInteger)_disk.get_num_images() : 0;
}

- (NSInteger)currentDiskIndex {
    return (_hasDiskControl && _disk.get_image_index) ? (NSInteger)_disk.get_image_index() : 0;
}

- (BOOL)insertDiskAtIndex:(NSInteger)index {
    if (!_hasDiskControl || index < 0 || index >= self.diskCount) return NO;
    _disk.set_eject_state(true);
    BOOL ok = _disk.set_image_index((unsigned)index);
    _disk.set_eject_state(false);
    return ok;
}

#pragma mark - A/V

- (double)framesPerSecond { return _avInfo.timing.fps; }
- (double)sampleRate { return _avInfo.timing.sample_rate; }
- (unsigned)baseWidth { return _avInfo.geometry.base_width; }
- (unsigned)baseHeight { return _avInfo.geometry.base_height; }
- (BOOL)usesHardwareRendering { return _gl != nil; }

- (float)aspectRatio {
    float aspect = _avInfo.geometry.aspect_ratio;
    if (aspect <= 0.0f && _avInfo.geometry.base_height > 0) {
        aspect = (float)_avInfo.geometry.base_width / (float)_avInfo.geometry.base_height;
    }
    return aspect > 0.0f ? aspect : 4.0f / 3.0f;
}

- (BOOL)consumeAVInfoChange {
    return atomic_exchange(&_avInfoChanged, false);
}

- (uint64_t)frameSerial { return atomic_load(&_frameSerial); }

- (BOOL)accessLatestFrame:(void (NS_NOESCAPE ^)(const void *, NSInteger, NSInteger, NSInteger))block {
    os_unfair_lock_lock(&_frameLock);
    BOOL has = _hasFrame && _ready.data;
    if (has) block(_ready.data, _ready.width, _ready.height, _ready.width * 4);
    os_unfair_lock_unlock(&_frameLock);
    return has;
}

- (nullable CGImageRef)copyFrameImage {
    __block CGImageRef image = NULL;
    [self accessLatestFrame:^(const void *pixels, NSInteger width, NSInteger height, NSInteger pitch) {
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context = CGBitmapContextCreate(NULL, (size_t)width, (size_t)height, 8, (size_t)pitch, space,
                                                     kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst);
        if (context) {
            memcpy(CGBitmapContextGetData(context), pixels, (size_t)(pitch * height));
            image = CGBitmapContextCreateImage(context);
            CGContextRelease(context);
        }
        CGColorSpaceRelease(space);
    }];
    return image;
}

- (void)publishBackBuffer {
    os_unfair_lock_lock(&_frameLock);
    URFrameBuffer tmp = _ready;
    _ready = _back;
    _back = tmp;
    _hasFrame = YES;
    os_unfair_lock_unlock(&_frameLock);
    atomic_fetch_add(&_frameSerial, 1);
}

static void URFrameBufferEnsure(URFrameBuffer *buffer, unsigned width, unsigned height) {
    size_t needed = (size_t)width * height * 4;
    if (buffer->capacity < needed) {
        free(buffer->data);
        buffer->data = malloc(needed);
        buffer->capacity = needed;
    }
    buffer->width = width;
    buffer->height = height;
}

#pragma mark - Input

- (void)setButtonMask:(uint32_t)mask forPort:(NSInteger)port {
    if (port >= 0 && port < URMaxPorts) atomic_store(&gButtonMasks[port], mask);
}

- (void)setAnalogStick:(URAnalogStick)stick x:(int16_t)x y:(int16_t)y forPort:(NSInteger)port {
    if (port < 0 || port >= URMaxPorts) return;
    atomic_store(&gAnalog[port][stick][0], x);
    atomic_store(&gAnalog[port][stick][1], y);
}

- (void)setPointerX:(int16_t)x y:(int16_t)y pressed:(BOOL)pressed {
    atomic_store(&gPointerX, x);
    atomic_store(&gPointerY, y);
    atomic_store(&gPointerPressed, pressed);
}

#pragma mark - Options

- (NSArray<URCoreOption *> *)options {
    @synchronized(self) { return [_optionDefinitions copy]; }
}

- (nullable NSString *)valueForOption:(NSString *)key {
    @synchronized(self) {
        NSData *value = _optionValues[key];
        return value ? [[NSString alloc] initWithUTF8String:value.bytes] : nil;
    }
}

- (void)setValue:(NSString *)value forOption:(NSString *)key {
    @synchronized(self) {
        [self storeOption:key value:value];
        _optionsUpdated = YES;
    }
}

/// Must be called while synchronized on self.
- (void)storeOption:(NSString *)key value:(NSString *)value {
    NSString *text = value ?: @"";
    NSData *string = _optionCStrings[text];
    if (!string) {
        const char *utf8 = text.UTF8String ?: "";
        string = [NSData dataWithBytes:utf8 length:strlen(utf8) + 1];
        _optionCStrings[text] = string;
    }
    _optionValues[key] = string;
}

- (void)registerOption:(URCoreOption *)option {
    @synchronized(self) {
        NSUInteger existing = [_optionDefinitions indexOfObjectPassingTest:^BOOL(URCoreOption *o, NSUInteger idx, BOOL *stop) {
            return [o.key isEqualToString:option.key];
        }];
        if (existing != NSNotFound) {
            [_optionDefinitions replaceObjectAtIndex:existing withObject:option];
        } else {
            [_optionDefinitions addObject:option];
        }
        NSString *override = self.optionOverrides[option.key];
        if (override && [option.values containsObject:override]) {
            [self storeOption:option.key value:override];
        } else if (!_optionValues[option.key] || ![option.values containsObject:[self valueForOption:option.key]]) {
            [self storeOption:option.key value:option.defaultValue];
        }
    }
}

- (void)resetOptionDefinitions {
    @synchronized(self) { [_optionDefinitions removeAllObjects]; }
}

- (const char *)optionValueCString:(const char *)key {
    @synchronized(self) {
        NSString *k = @(key);
        NSData *value = _optionValues[k];
        if (!value) {
            NSString *override = self.optionOverrides[k];
            if (override) {
                [self storeOption:k value:override];
                value = _optionValues[k];
            }
        }
        return value ? value.bytes : NULL;
    }
}

- (BOOL)consumeOptionsUpdated {
    @synchronized(self) {
        BOOL updated = _optionsUpdated;
        _optionsUpdated = NO;
        return updated;
    }
}

#pragma mark - Messages

- (void)postMessage:(NSString *)message duration:(NSTimeInterval)duration {
    void (^handler)(NSString *, NSTimeInterval) = self.messageHandler;
    if (!handler || message.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(message, duration); });
}

@end

#pragma mark - libretro callbacks

static void URCoreLogPrintf(enum retro_log_level level, const char *fmt, ...) {
    char buffer[2048];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);
    size_t length = strlen(buffer);
    while (length > 0 && (buffer[length - 1] == '\n' || buffer[length - 1] == '\r')) buffer[--length] = 0;

    static int mirrorToStderr = -1;
    if (mirrorToStderr < 0) mirrorToStderr = getenv("URSPRUNG_CORE_LOG") != NULL;
    if (mirrorToStderr) fprintf(stderr, "[core:%d] %s\n", (int)level, buffer);

    switch (level) {
        case RETRO_LOG_DEBUG: os_log_debug(URCoreLog(), "%{public}s", buffer); break;
        case RETRO_LOG_INFO: os_log_info(URCoreLog(), "%{public}s", buffer); break;
        case RETRO_LOG_WARN: os_log(URCoreLog(), "[warn] %{public}s", buffer); break;
        default: os_log_error(URCoreLog(), "%{public}s", buffer); break;
    }
}

static retro_time_t URPerfGetTimeUsec(void) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    return (retro_time_t)(mach_absolute_time() * timebase.numer / timebase.denom / 1000);
}
static retro_perf_tick_t URPerfGetCounter(void) { return mach_absolute_time(); }
static uint64_t URPerfGetCPUFeatures(void) { return RETRO_SIMD_NEON | RETRO_SIMD_ASIMD; }
static void URPerfLog(void) {}
static void URPerfRegister(struct retro_perf_counter *counter) { counter->registered = true; }
static void URPerfStart(struct retro_perf_counter *counter) {
    counter->call_cnt++;
    counter->start = URPerfGetCounter();
}
static void URPerfStop(struct retro_perf_counter *counter) {
    counter->total += URPerfGetCounter() - counter->start;
}

static bool URCoreSetRumble(unsigned port, enum retro_rumble_effect effect, uint16_t strength) {
    return true;
}

static uintptr_t URCoreHWGetFramebuffer(void) {
    URLibretroCore *core = gActiveCore;
    return core ? core->_gl.framebufferID : 0;
}

static retro_proc_address_t URCoreHWGetProcAddress(const char *symbol) {
    return (retro_proc_address_t)[URGLContext procAddress:symbol];
}

static NSString *URString(const char *value) {
    return value ? ([NSString stringWithUTF8String:value] ?: @"") : @"";
}

static void URRegisterOptionsV1(URLibretroCore *core, const struct retro_core_option_definition *definitions) {
    [core resetOptionDefinitions];
    for (const struct retro_core_option_definition *def = definitions; def && def->key; def++) {
        NSMutableArray *values = [NSMutableArray array];
        NSMutableArray *labels = [NSMutableArray array];
        for (int i = 0; i < RETRO_NUM_CORE_OPTION_VALUES_MAX && def->values[i].value; i++) {
            [values addObject:URString(def->values[i].value)];
            [labels addObject:def->values[i].label ? URString(def->values[i].label) : URString(def->values[i].value)];
        }
        if (values.count == 0) continue;
        NSString *defaultValue = def->default_value ? URString(def->default_value) : values.firstObject;
        [core registerOption:[[URCoreOption alloc] initWithKey:URString(def->key)
                                                         title:URString(def->desc)
                                                          info:def->info ? URString(def->info) : nil
                                                      category:nil
                                                        values:values
                                                        labels:labels
                                                  defaultValue:defaultValue]];
    }
}

static void URRegisterOptionsV2(URLibretroCore *core, const struct retro_core_options_v2 *options) {
    [core resetOptionDefinitions];
    if (!options || !options->definitions) return;
    for (const struct retro_core_option_v2_definition *def = options->definitions; def->key; def++) {
        NSMutableArray *values = [NSMutableArray array];
        NSMutableArray *labels = [NSMutableArray array];
        for (int i = 0; i < RETRO_NUM_CORE_OPTION_VALUES_MAX && def->values[i].value; i++) {
            [values addObject:URString(def->values[i].value)];
            [labels addObject:def->values[i].label ? URString(def->values[i].label) : URString(def->values[i].value)];
        }
        if (values.count == 0) continue;
        NSString *defaultValue = def->default_value ? URString(def->default_value) : values.firstObject;
        [core registerOption:[[URCoreOption alloc] initWithKey:URString(def->key)
                                                         title:URString(def->desc)
                                                          info:def->info ? URString(def->info) : nil
                                                      category:def->category_key ? URString(def->category_key) : nil
                                                        values:values
                                                        labels:labels
                                                  defaultValue:defaultValue]];
    }
}

static void URRegisterVariables(URLibretroCore *core, const struct retro_variable *variables) {
    [core resetOptionDefinitions];
    for (const struct retro_variable *var = variables; var && var->key; var++) {
        // Format: "Description; value1|value2|value3" — first value is the default.
        NSString *spec = URString(var->value);
        NSRange separator = [spec rangeOfString:@"; "];
        NSString *title = separator.location != NSNotFound ? [spec substringToIndex:separator.location] : URString(var->key);
        NSString *list = separator.location != NSNotFound ? [spec substringFromIndex:NSMaxRange(separator)] : spec;
        NSArray *values = [list componentsSeparatedByString:@"|"];
        if (values.count == 0) continue;
        [core registerOption:[[URCoreOption alloc] initWithKey:URString(var->key)
                                                         title:title
                                                          info:nil
                                                      category:nil
                                                        values:values
                                                        labels:values
                                                  defaultValue:values.firstObject]];
    }
}

bool URCoreEnvironment(unsigned cmd, void *data) {
    URLibretroCore *core = gActiveCore;
    if (!core) return false;

    // Only a few commands legitimately pass NULL; never dereference it otherwise.
    if (!data) {
        switch (cmd) {
            case RETRO_ENVIRONMENT_SHUTDOWN:
            case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
            case RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE:
            case RETRO_ENVIRONMENT_SET_VARIABLE:
            case RETRO_ENVIRONMENT_SET_VARIABLES:
            case RETRO_ENVIRONMENT_SET_CORE_OPTIONS:
            case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2:
            case RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE:
            case RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE:
                break;
            default:
                return false;
        }
    }

    switch (cmd) {
        case RETRO_ENVIRONMENT_GET_CAN_DUPE:
            *(bool *)data = true;
            return true;

        case RETRO_ENVIRONMENT_GET_OVERSCAN:
            *(bool *)data = false;
            return true;

        case RETRO_ENVIRONMENT_SET_ROTATION: {
            core->_rotation = (NSInteger)(*(const unsigned *)data % 4);
            return true;
        }

        case RETRO_ENVIRONMENT_SET_MESSAGE: {
            const struct retro_message *msg = data;
            if (msg && msg->msg) [core postMessage:URString(msg->msg) duration:MAX(msg->frames / 60.0, 2.0)];
            return true;
        }

        case RETRO_ENVIRONMENT_SET_MESSAGE_EXT: {
            const struct retro_message_ext *msg = data;
            if (!msg || !msg->msg) return true;
            if (msg->target == RETRO_MESSAGE_TARGET_LOG) {
                URCoreLogPrintf(msg->level, "%s", msg->msg);
            } else if (msg->type != RETRO_MESSAGE_TYPE_PROGRESS) {
                [core postMessage:URString(msg->msg) duration:MAX(msg->duration / 1000.0, 2.0)];
            }
            return true;
        }

        case RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION:
            *(unsigned *)data = 1;
            return true;

        case RETRO_ENVIRONMENT_SHUTDOWN:
            core->_shutdownRequested = YES;
            return true;

        case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL:
            return true;

        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
        case RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY:
            *(const char **)data = core->_systemDirC;
            return true;

        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            *(const char **)data = core->_saveDirC;
            return true;

        case RETRO_ENVIRONMENT_GET_LIBRETRO_PATH:
            *(const char **)data = core->_corePathC;
            return true;

        case RETRO_ENVIRONMENT_GET_USERNAME:
            *(const char **)data = core->_usernameC;
            return true;

        case RETRO_ENVIRONMENT_GET_LANGUAGE: {
            NSString *lang = core.languageCode;
            unsigned value = RETRO_LANGUAGE_ENGLISH;
            if ([lang hasPrefix:@"de"]) value = RETRO_LANGUAGE_GERMAN;
            else if ([lang hasPrefix:@"fr"]) value = RETRO_LANGUAGE_FRENCH;
            else if ([lang hasPrefix:@"es"]) value = RETRO_LANGUAGE_SPANISH;
            else if ([lang hasPrefix:@"it"]) value = RETRO_LANGUAGE_ITALIAN;
            else if ([lang hasPrefix:@"ja"]) value = RETRO_LANGUAGE_JAPANESE;
            *(unsigned *)data = value;
            return true;
        }

        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
            enum retro_pixel_format format = *(const enum retro_pixel_format *)data;
            if (format > RETRO_PIXEL_FORMAT_XRGB2101010) return false;
            core->_pixelFormat = format;
            return true;
        }

        case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
        case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
        case RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO:
        case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
        case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
        case RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS:
        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK:
        case RETRO_ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE:
        case RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS:
        case RETRO_ENVIRONMENT_SET_MINIMUM_AUDIO_LATENCY:
        case RETRO_ENVIRONMENT_SET_KEYBOARD_CALLBACK:
            return true;

        case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
            return true;

        case RETRO_ENVIRONMENT_GET_INPUT_MAX_USERS:
            *(unsigned *)data = (unsigned)URMaxPorts;
            return true;

        case RETRO_ENVIRONMENT_GET_INPUT_DEVICE_CAPABILITIES:
            *(uint64_t *)data = (1 << RETRO_DEVICE_JOYPAD) | (1 << RETRO_DEVICE_ANALOG) | (1 << RETRO_DEVICE_POINTER);
            return true;

        case RETRO_ENVIRONMENT_GET_VARIABLE: {
            struct retro_variable *var = data;
            if (!var || !var->key) return false;
            var->value = [core optionValueCString:var->key];
            return var->value != NULL;
        }

        case RETRO_ENVIRONMENT_SET_VARIABLES:
            URRegisterVariables(core, data);
            return true;

        case RETRO_ENVIRONMENT_SET_VARIABLE: {
            const struct retro_variable *var = data;
            if (!data) return true; // query for support
            if (var->key && var->value) [core setValue:URString(var->value) forOption:URString(var->key)];
            return true;
        }

        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
            *(bool *)data = [core consumeOptionsUpdated];
            return true;

        case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
            *(unsigned *)data = 2;
            return true;

        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS:
            URRegisterOptionsV1(core, data);
            return true;

        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL: {
            const struct retro_core_options_intl *intl = data;
            URRegisterOptionsV1(core, intl ? intl->us : NULL);
            return true;
        }

        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2:
            URRegisterOptionsV2(core, data);
            return true;

        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL: {
            const struct retro_core_options_v2_intl *intl = data;
            URRegisterOptionsV2(core, intl ? intl->us : NULL);
            return true;
        }

        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: {
            struct retro_log_callback *cb = data;
            cb->log = URCoreLogPrintf;
            return true;
        }

        case RETRO_ENVIRONMENT_GET_PERF_INTERFACE: {
            struct retro_perf_callback *cb = data;
            cb->get_time_usec = URPerfGetTimeUsec;
            cb->get_cpu_features = URPerfGetCPUFeatures;
            cb->get_perf_counter = URPerfGetCounter;
            cb->perf_register = URPerfRegister;
            cb->perf_start = URPerfStart;
            cb->perf_stop = URPerfStop;
            cb->perf_log = URPerfLog;
            return true;
        }

        case RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE: {
            struct retro_rumble_interface *rumble = data;
            rumble->set_rumble_state = URCoreSetRumble;
            return true;
        }

        case RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK: {
            const struct retro_frame_time_callback *cb = data;
            core->_frameTimeCallback = *cb;
            core->_hasFrameTimeCallback = cb->callback != NULL;
            return true;
        }

        case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: {
            const struct retro_system_av_info *info = data;
            core->_avInfo = *info;
            [core sanitizeAVInfo];
            if (core->_gl) {
                [core->_gl resizeFramebufferWidth:MAX(core->_gl.framebufferWidth, info->geometry.max_width)
                                           height:MAX(core->_gl.framebufferHeight, info->geometry.max_height)];
            }
            atomic_store(&core->_avInfoChanged, true);
            return true;
        }

        case RETRO_ENVIRONMENT_SET_GEOMETRY: {
            const struct retro_game_geometry *geometry = data;
            core->_avInfo.geometry.base_width = geometry->base_width;
            core->_avInfo.geometry.base_height = geometry->base_height;
            core->_avInfo.geometry.aspect_ratio = geometry->aspect_ratio;
            return true;
        }

        case RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER:
            *(unsigned *)data = RETRO_HW_CONTEXT_OPENGL_CORE;
            return true;

        case RETRO_ENVIRONMENT_SET_HW_RENDER: {
            struct retro_hw_render_callback *hw = data;
            BOOL coreProfile;
            if (hw->context_type == RETRO_HW_CONTEXT_OPENGL_CORE) {
                coreProfile = YES;
            } else if (hw->context_type == RETRO_HW_CONTEXT_OPENGL) {
                coreProfile = NO;
            } else {
                return false; // Vulkan / GLES are not available.
            }
            NSError *error = nil;
            URGLContext *gl = [[URGLContext alloc] initWithCoreProfile:coreProfile depth:hw->depth stencil:hw->stencil error:&error];
            if (!gl) {
                URCoreLogPrintf(RETRO_LOG_ERROR, "%s", error.localizedDescription.UTF8String);
                return false;
            }
            [gl makeCurrent];
            hw->get_current_framebuffer = URCoreHWGetFramebuffer;
            hw->get_proc_address = URCoreHWGetProcAddress;
            core->_hwRender = *hw;
            core->_gl = gl;
            return true;
        }

        case RETRO_ENVIRONMENT_GET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_SUPPORT:
        case RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE:
        case RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE:
        case RETRO_ENVIRONMENT_SET_HW_SHARED_CONTEXT:
            return false;

        case RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION:
            *(unsigned *)data = 1;
            return true;

        case RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE: {
            const struct retro_disk_control_callback *cb = data;
            memset(&core->_disk, 0, sizeof(core->_disk));
            if (cb) memcpy(&core->_disk, cb, sizeof(*cb));
            core->_hasDiskControl = cb && cb->get_num_images && cb->set_image_index && cb->set_eject_state;
            return true;
        }

        case RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE: {
            const struct retro_disk_control_ext_callback *cb = data;
            memset(&core->_disk, 0, sizeof(core->_disk));
            if (cb) core->_disk = *cb;
            core->_hasDiskControl = cb && cb->get_num_images && cb->set_image_index && cb->set_eject_state;
            return true;
        }

        case RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE:
            if (data) *(int *)data = 1 | 2;
            return true;

        case RETRO_ENVIRONMENT_GET_FASTFORWARDING:
            *(bool *)data = core.fastForwarding;
            return true;

        case RETRO_ENVIRONMENT_GET_TARGET_REFRESH_RATE:
            *(float *)data = 60.0f;
            return true;

        case RETRO_ENVIRONMENT_GET_JIT_CAPABLE:
            *(bool *)data = true;
            return true;

        case RETRO_ENVIRONMENT_GET_SAVESTATE_CONTEXT:
            *(int *)data = RETRO_SAVESTATE_CONTEXT_NORMAL;
            return true;

        default:
            return false;
    }
}

static inline uint32_t URConvert565(uint16_t p) {
    uint32_t r = (p >> 11) & 0x1F, g = (p >> 5) & 0x3F, b = p & 0x1F;
    return 0xFF000000u | (((r << 3) | (r >> 2)) << 16) | (((g << 2) | (g >> 4)) << 8) | ((b << 3) | (b >> 2));
}

static inline uint32_t URConvert1555(uint16_t p) {
    uint32_t r = (p >> 10) & 0x1F, g = (p >> 5) & 0x1F, b = p & 0x1F;
    return 0xFF000000u | (((r << 3) | (r >> 2)) << 16) | (((g << 3) | (g >> 2)) << 8) | ((b << 3) | (b >> 2));
}

static inline uint32_t URConvert2101010(uint32_t p) {
    uint32_t r = (p >> 22) & 0xFF, g = (p >> 12) & 0xFF, b = (p >> 2) & 0xFF;
    return 0xFF000000u | (r << 16) | (g << 8) | b;
}

void URCoreVideoRefresh(const void *data, unsigned width, unsigned height, size_t pitch) {
    URLibretroCore *core = gActiveCore;
    if (!core || !data || width == 0 || height == 0) return; // NULL = duplicate frame

    URFrameBuffer *back = &core->_back;
    URFrameBufferEnsure(back, width, height);

    if (data == RETRO_HW_FRAME_BUFFER_VALID) {
        if (!core->_gl) return;
        [core->_gl readPixelsWidth:width height:height
                  bottomLeftOrigin:core->_hwRender.bottom_left_origin
                       destination:back->data];
        [core publishBackBuffer];
        return;
    }

    const uint8_t *src = data;
    uint32_t *dst = (uint32_t *)back->data;
    switch (core->_pixelFormat) {
        case RETRO_PIXEL_FORMAT_XRGB8888:
            for (unsigned y = 0; y < height; y++) {
                memcpy(dst + (size_t)y * width, src + (size_t)y * pitch, (size_t)width * 4);
            }
            break;
        case RETRO_PIXEL_FORMAT_RGB565:
            for (unsigned y = 0; y < height; y++) {
                const uint16_t *row = (const uint16_t *)(src + (size_t)y * pitch);
                uint32_t *out = dst + (size_t)y * width;
                for (unsigned x = 0; x < width; x++) out[x] = URConvert565(row[x]);
            }
            break;
        case RETRO_PIXEL_FORMAT_XRGB2101010:
            for (unsigned y = 0; y < height; y++) {
                const uint32_t *row = (const uint32_t *)(src + (size_t)y * pitch);
                uint32_t *out = dst + (size_t)y * width;
                for (unsigned x = 0; x < width; x++) out[x] = URConvert2101010(row[x]);
            }
            break;
        default:
            for (unsigned y = 0; y < height; y++) {
                const uint16_t *row = (const uint16_t *)(src + (size_t)y * pitch);
                uint32_t *out = dst + (size_t)y * width;
                for (unsigned x = 0; x < width; x++) out[x] = URConvert1555(row[x]);
            }
            break;
    }
    [core publishBackBuffer];
}

void URCoreAudioSample(int16_t left, int16_t right) {
    URLibretroCore *core = gActiveCore;
    if (!core) return;
    int16_t frame[2] = {left, right};
    URAudioRingWrite(&core->_ring, frame, 1);
}

size_t URCoreAudioSampleBatch(const int16_t *data, size_t frames) {
    URLibretroCore *core = gActiveCore;
    if (!core) return frames;
    URAudioRingWrite(&core->_ring, data, frames);
    return frames;
}

void URCoreInputPoll(void) {}

int16_t URCoreInputState(unsigned port, unsigned device, unsigned index, unsigned id) {
    if (port >= URMaxPorts) return 0;
    switch (device & RETRO_DEVICE_MASK) {
        case RETRO_DEVICE_JOYPAD: {
            uint32_t mask = atomic_load_explicit(&gButtonMasks[port], memory_order_relaxed);
            if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)(mask & 0xFFFF);
            return (id < 16) ? (int16_t)((mask >> id) & 1) : 0;
        }
        case RETRO_DEVICE_ANALOG: {
            if (index < 2 && id < 2) return atomic_load_explicit(&gAnalog[port][index][id], memory_order_relaxed);
            if (index == RETRO_DEVICE_INDEX_ANALOG_BUTTON && id < 16) {
                uint32_t mask = atomic_load_explicit(&gButtonMasks[port], memory_order_relaxed);
                return ((mask >> id) & 1) ? 0x7FFF : 0;
            }
            return 0;
        }
        case RETRO_DEVICE_POINTER: {
            if (port != 0 || index != 0) return 0;
            switch (id) {
                case RETRO_DEVICE_ID_POINTER_X: return atomic_load(&gPointerX);
                case RETRO_DEVICE_ID_POINTER_Y: return atomic_load(&gPointerY);
                case RETRO_DEVICE_ID_POINTER_PRESSED: return atomic_load(&gPointerPressed) ? 1 : 0;
                case RETRO_DEVICE_ID_POINTER_COUNT: return 1;
                default: return 0;
            }
        }
        default:
            return 0;
    }
}
