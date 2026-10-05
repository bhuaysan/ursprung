// SPDX-License-Identifier: GPL-3.0-or-later

#import "URAchievements.h"

#import "URLibretroCore+Internal.h"
#import "rc_client.h"
#import "rc_consoles.h"
#import "rc_libretro.h"

#include <os/log.h>
#include <stdatomic.h>

static NSString *const URAchievementsErrorDomain = @"Ursprung.Achievements";

static os_log_t URAchievementsLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("io.github.bhuaysan.Ursprung", "achievements"); });
    return log;
}

static NSString *URStringOrNil(const char *value) {
    return (value && *value) ? [NSString stringWithUTF8String:value] : nil;
}

static NSString *URStringOrEmpty(const char *value) {
    return URStringOrNil(value) ?: @"";
}

#pragma mark - Value objects

@implementation URAchievementEvent
- (instancetype)initWithKind:(URAchievementEventKind)kind itemID:(NSUInteger)itemID title:(NSString *)title
                      detail:(nullable NSString *)detail value:(nullable NSString *)value
                    imageURL:(nullable NSString *)imageURL points:(NSInteger)points {
    self = [super init];
    if (self) {
        _kind = kind;
        _itemID = itemID;
        _title = [title copy];
        _detail = [detail copy];
        _value = [value copy];
        _imageURL = [imageURL copy];
        _points = points;
    }
    return self;
}
@end

@implementation URAchievementInfo
- (instancetype)initWithAchievement:(const rc_client_achievement_t *)achievement hardcore:(BOOL)hardcore {
    self = [super init];
    if (self) {
        _achievementID = achievement->id;
        _title = URStringOrEmpty(achievement->title);
        _detail = URStringOrEmpty(achievement->description);
        _points = achievement->points;
        uint8_t needed = hardcore ? RC_CLIENT_ACHIEVEMENT_UNLOCKED_HARDCORE : RC_CLIENT_ACHIEVEMENT_UNLOCKED_SOFTCORE;
        _isUnlocked = (achievement->unlocked & needed) != 0;
        _isUnsupported = achievement->state == RC_CLIENT_ACHIEVEMENT_STATE_DISABLED;
        _unlockDate = (_isUnlocked && achievement->unlock_time > 0)
            ? [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)achievement->unlock_time] : nil;
        _progress = URStringOrEmpty(achievement->measured_progress);
        _progressFraction = achievement->measured_percent / 100.0f;
        _imageURL = URStringOrNil(_isUnlocked ? achievement->badge_url : achievement->badge_locked_url);
        _rarity = hardcore ? achievement->rarity_hardcore : achievement->rarity;
    }
    return self;
}
@end

@implementation URAchievementGameInfo
- (instancetype)initWithGame:(const rc_client_game_t *)game summary:(const rc_client_user_game_summary_t *)summary {
    self = [super init];
    if (self) {
        _gameID = game->id;
        _title = URStringOrEmpty(game->title);
        _imageURL = URStringOrNil(game->badge_url);
        _achievementCount = summary->num_core_achievements;
        _unlockedCount = summary->num_unlocked_achievements;
        _points = summary->points_core;
        _unlockedPoints = summary->points_unlocked;
    }
    return self;
}
@end

@implementation URAchievementUser
- (instancetype)initWithUser:(const rc_client_user_t *)user {
    self = [super init];
    if (self) {
        _username = URStringOrEmpty(user->username);
        _displayName = URStringOrNil(user->display_name) ?: _username;
        _token = URStringOrEmpty(user->token);
        _score = user->score;
        _softcoreScore = user->score_softcore;
        _imageURL = URStringOrNil(user->avatar_url);
    }
    return self;
}
@end

#pragma mark - Client

@interface URAchievements ()
@property (nonatomic, copy) NSString *userAgent;
- (void)deliverEvent:(const rc_client_event_t *)event;
@end

/// The core whose memory `rc_libretro_memory_init` asks about (emulation thread).
static __unsafe_unretained URLibretroCore *gMemoryCore;

static void URGetCoreMemoryInfo(uint32_t id, rc_libretro_core_memory_info_t *info) {
    size_t size = 0;
    void *data = [gMemoryCore memoryDataOfType:id size:&size];
    info->data = data;
    info->size = data ? size : 0;
}

@implementation URAchievements {
    rc_client_t *_client;
    NSURLSession *_session;
    dispatch_queue_t _queue;

    // Emulation thread only.
    rc_libretro_memory_regions_t _regions;
    BOOL _hasRegions;
    NSUInteger _regionsRevision;
    __weak URLibretroCore *_regionsCore;
    _Atomic uint32_t _consoleID;
}

static uint32_t URReadMemory(uint32_t address, uint8_t *buffer, uint32_t numBytes, rc_client_t *client) {
    URAchievements *achievements = (__bridge URAchievements *)rc_client_get_userdata(client);
    if (!achievements || !achievements->_hasRegions) return 0;
    return rc_libretro_memory_read(&achievements->_regions, address, buffer, numBytes);
}

static void URServerCall(const rc_api_request_t *request, rc_client_server_callback_t callback, void *callbackData,
                         rc_client_t *client) {
    URAchievements *achievements = (__bridge URAchievements *)rc_client_get_userdata(client);
    NSURL *url = request->url ? [NSURL URLWithString:@(request->url)] : nil;
    if (!achievements || !url) {
        rc_api_server_response_t response = {0};
        response.http_status_code = RC_API_SERVER_RESPONSE_CLIENT_ERROR;
        callback(&response, callbackData);
        return;
    }
    NSMutableURLRequest *httpRequest = [NSMutableURLRequest requestWithURL:url];
    [httpRequest setValue:achievements.userAgent forHTTPHeaderField:@"User-Agent"];
    httpRequest.timeoutInterval = 30;
    if (request->post_data) {
        httpRequest.HTTPMethod = @"POST";
        httpRequest.HTTPBody = [NSData dataWithBytes:request->post_data length:strlen(request->post_data)];
        [httpRequest setValue:request->content_type ? @(request->content_type) : @"application/x-www-form-urlencoded"
           forHTTPHeaderField:@"Content-Type"];
    }
    // The request carries the password or token: it is never logged.
    NSURLSessionDataTask *task = [achievements->_session dataTaskWithRequest:httpRequest
        completionHandler:^(NSData *data, NSURLResponse *urlResponse, NSError *error) {
            rc_api_server_response_t response = {0};
            NSData *body = data;
            if (error) {
                body = [error.localizedDescription dataUsingEncoding:NSUTF8StringEncoding];
                response.http_status_code = RC_API_SERVER_RESPONSE_RETRYABLE_CLIENT_ERROR;
            } else {
                response.http_status_code = (int)((NSHTTPURLResponse *)urlResponse).statusCode;
            }
            response.body = body.bytes;
            response.body_length = body.length;
            callback(&response, callbackData);
        }];
    [task resume];
}

static void URLogMessage(const char *message, const rc_client_t *client) {
    os_log(URAchievementsLog(), "%{public}s", message);
}

static void UREventHandler(const rc_client_event_t *event, rc_client_t *client) {
    URAchievements *achievements = (__bridge URAchievements *)rc_client_get_userdata(client);
    [achievements deliverEvent:event];
}

- (instancetype)initWithClientName:(NSString *)name version:(NSString *)version {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("io.github.bhuaysan.Ursprung.achievements", DISPATCH_QUEUE_SERIAL);
        NSOperationQueue *delegateQueue = [NSOperationQueue new];
        delegateQueue.maxConcurrentOperationCount = 1;
        delegateQueue.underlyingQueue = _queue;
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:nil delegateQueue:delegateQueue];

        _client = rc_client_create(URReadMemory, URServerCall);
        rc_client_set_userdata(_client, (__bridge void *)self);
        rc_client_set_event_handler(_client, UREventHandler);
        rc_client_enable_logging(_client, RC_CLIENT_LOG_LEVEL_WARN, URLogMessage);
        // Memory is only read on the emulation thread, in -doFrame and -idle.
        rc_client_set_allow_background_memory_reads(_client, 0);

        char clause[128] = {0};
        rc_client_get_user_agent_clause(_client, clause, sizeof(clause));
        _userAgent = [NSString stringWithFormat:@"%@/%@ (macOS) %s", name, version, clause];
    }
    return self;
}

- (void)dealloc {
    if (_client) rc_client_destroy(_client);
    if (_hasRegions) rc_libretro_memory_destroy(&_regions);
}

- (BOOL)hardcoreEnabled {
    return rc_client_get_hardcore_enabled(_client) != 0;
}

- (void)setHardcoreEnabled:(BOOL)enabled {
    // In order with loading and unloading games: switching it while the
    // previous game is still loaded would reset that game.
    rc_client_t *client = _client;
    dispatch_async(_queue, ^{ rc_client_set_hardcore_enabled(client, enabled ? 1 : 0); });
}

#pragma mark Sign in

typedef void (^URLoginCompletion)(URAchievementUser *_Nullable, NSError *_Nullable);

static NSError *URError(int result, const char *message) {
    NSString *text = URStringOrNil(message) ?: URStringOrNil(rc_error_str(result)) ?: @"";
    return [NSError errorWithDomain:URAchievementsErrorDomain code:result userInfo:@{NSLocalizedDescriptionKey: text}];
}

static void URLoginCallback(int result, const char *errorMessage, rc_client_t *client, void *userdata) {
    URLoginCompletion completion = (__bridge_transfer URLoginCompletion)userdata;
    const rc_client_user_t *info = result == RC_OK ? rc_client_get_user_info(client) : NULL;
    URAchievementUser *user = info ? [[URAchievementUser alloc] initWithUser:info] : nil;
    NSError *error = user ? nil : URError(result, errorMessage);
    dispatch_async(dispatch_get_main_queue(), ^{ completion(user, error); });
}

- (void)loginWithUsername:(NSString *)username password:(NSString *)password
               completion:(void (^)(URAchievementUser *, NSError *))completion {
    URLoginCompletion callback = [completion copy];
    rc_client_begin_login_with_password(_client, username.UTF8String, password.UTF8String, URLoginCallback,
                                        (__bridge_retained void *)callback);
}

- (void)loginWithUsername:(NSString *)username token:(NSString *)token
               completion:(void (^)(URAchievementUser *, NSError *))completion {
    URLoginCompletion callback = [completion copy];
    rc_client_begin_login_with_token(_client, username.UTF8String, token.UTF8String, URLoginCallback,
                                     (__bridge_retained void *)callback);
}

- (void)logout {
    rc_client_logout(_client);
}

- (nullable URAchievementUser *)user {
    const rc_client_user_t *info = rc_client_get_user_info(_client);
    return info ? [[URAchievementUser alloc] initWithUser:info] : nil;
}

#pragma mark Games

typedef void (^URLoadCompletion)(URAchievementGameInfo *_Nullable, NSError *_Nullable);

static void URLoadCallback(int result, const char *errorMessage, rc_client_t *client, void *userdata) {
    URLoadCompletion completion = (__bridge_transfer URLoadCompletion)userdata;
    URAchievements *achievements = (__bridge URAchievements *)rc_client_get_userdata(client);
    URAchievementGameInfo *game = result == RC_OK ? achievements.gameInfo : nil;
    // An unknown game simply has no achievements.
    NSError *error = (result == RC_OK || result == RC_NO_GAME_LOADED) ? nil : URError(result, errorMessage);
    dispatch_async(dispatch_get_main_queue(), ^{ completion(game, error); });
}

- (void)loadGameAtPath:(NSString *)path consoleID:(NSInteger)consoleID
            completion:(void (^)(URAchievementGameInfo *, NSError *))completion {
    URLoadCompletion callback = [completion copy];
    atomic_store(&_consoleID, (uint32_t)consoleID);
    NSString *filePath = [path copy];
    rc_client_t *client = _client;
    // Hashing reads the file, which can take a moment for discs.
    dispatch_async(_queue, ^{
        rc_client_begin_identify_and_load_game(client, (uint32_t)consoleID, filePath.fileSystemRepresentation, NULL, 0,
                                               URLoadCallback, (__bridge_retained void *)callback);
    });
}

- (void)unloadGame {
    rc_client_t *client = _client;
    dispatch_async(_queue, ^{ rc_client_unload_game(client); });
    atomic_store(&_consoleID, RC_CONSOLE_UNKNOWN);
}

- (void)resetGame {
    rc_client_reset(_client);
}

- (void)stateLoaded {
    rc_client_deserialize_progress(_client, NULL);
}

- (BOOL)isGameLoaded {
    return rc_client_is_game_loaded(_client) != 0;
}

- (nullable URAchievementGameInfo *)gameInfo {
    const rc_client_game_t *game = rc_client_get_game_info(_client);
    if (!game || game->id == 0) return nil;
    rc_client_user_game_summary_t summary = {0};
    rc_client_get_user_game_summary(_client, &summary);
    return [[URAchievementGameInfo alloc] initWithGame:game summary:&summary];
}

- (NSArray<URAchievementInfo *> *)achievements {
    rc_client_achievement_list_t *list = rc_client_create_achievement_list(
        _client, RC_CLIENT_ACHIEVEMENT_CATEGORY_CORE, RC_CLIENT_ACHIEVEMENT_LIST_GROUPING_LOCK_STATE);
    if (!list) return @[];
    BOOL hardcore = self.hardcoreEnabled;
    NSMutableArray *result = [NSMutableArray array];
    for (uint32_t b = 0; b < list->num_buckets; b++) {
        const rc_client_achievement_bucket_t *bucket = &list->buckets[b];
        for (uint32_t i = 0; i < bucket->num_achievements; i++) {
            [result addObject:[[URAchievementInfo alloc] initWithAchievement:bucket->achievements[i] hardcore:hardcore]];
        }
    }
    rc_client_destroy_achievement_list(list);
    return result;
}

- (nullable NSString *)richPresence {
    if (!rc_client_has_rich_presence(_client)) return nil;
    char buffer[256] = {0};
    rc_client_get_rich_presence_message(_client, buffer, sizeof(buffer));
    return URStringOrNil(buffer);
}

#pragma mark Frames

/// Maps the game's memory for RetroAchievements' addresses, again whenever
/// the core declares a new memory map.
- (void)prepareMemoryOfCore:(URLibretroCore *)core {
    uint32_t consoleID = atomic_load(&_consoleID);
    if (consoleID == RC_CONSOLE_UNKNOWN) return;
    if (_regionsCore == core && _regionsRevision == core.memoryMapRevision) return;
    if (_hasRegions) rc_libretro_memory_destroy(&_regions);
    gMemoryCore = core;
    _hasRegions = rc_libretro_memory_init(&_regions, [core memoryMap], URGetCoreMemoryInfo, consoleID) != 0;
    gMemoryCore = nil;
    _regionsCore = core;
    _regionsRevision = core.memoryMapRevision;
}

- (void)doFrameWithCore:(URLibretroCore *)core {
    [self prepareMemoryOfCore:core];
    rc_client_do_frame(_client);
}

- (void)idleWithCore:(URLibretroCore *)core {
    [self prepareMemoryOfCore:core];
    rc_client_idle(_client);
}

#pragma mark Events

- (void)deliverEvent:(const rc_client_event_t *)event {
    void (^handler)(URAchievementEvent *) = self.eventHandler;
    if (!handler) return;
    URAchievementEvent *result = nil;
    const rc_client_achievement_t *achievement = event->achievement;
    const rc_client_leaderboard_t *leaderboard = event->leaderboard;
    switch (event->type) {
        case RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED:
        case RC_CLIENT_EVENT_ACHIEVEMENT_CHALLENGE_INDICATOR_SHOW:
        case RC_CLIENT_EVENT_ACHIEVEMENT_CHALLENGE_INDICATOR_HIDE:
        case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_SHOW:
        case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_UPDATE:
        case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_HIDE: {
            URAchievementEventKind kind;
            switch (event->type) {
                case RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED: kind = URAchievementEventKindUnlocked; break;
                case RC_CLIENT_EVENT_ACHIEVEMENT_CHALLENGE_INDICATOR_SHOW: kind = URAchievementEventKindChallengeShown; break;
                case RC_CLIENT_EVENT_ACHIEVEMENT_CHALLENGE_INDICATOR_HIDE: kind = URAchievementEventKindChallengeHidden; break;
                case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_HIDE: kind = URAchievementEventKindProgressHidden; break;
                default: kind = URAchievementEventKindProgressShown; break;
            }
            if (!achievement && kind != URAchievementEventKindProgressHidden) return;
            result = [[URAchievementEvent alloc] initWithKind:kind itemID:achievement ? achievement->id : 0
                                                        title:achievement ? URStringOrEmpty(achievement->title) : @""
                                                       detail:achievement ? URStringOrNil(achievement->description) : nil
                                                        value:achievement ? URStringOrNil(achievement->measured_progress) : nil
                                                     imageURL:achievement ? URStringOrNil(achievement->badge_url) : nil
                                                       points:achievement ? achievement->points : 0];
            break;
        }
        case RC_CLIENT_EVENT_LEADERBOARD_STARTED:
        case RC_CLIENT_EVENT_LEADERBOARD_FAILED:
        case RC_CLIENT_EVENT_LEADERBOARD_SUBMITTED: {
            if (!leaderboard) return;
            URAchievementEventKind kind = event->type == RC_CLIENT_EVENT_LEADERBOARD_STARTED ? URAchievementEventKindLeaderboardStarted
                : event->type == RC_CLIENT_EVENT_LEADERBOARD_FAILED ? URAchievementEventKindLeaderboardFailed
                : URAchievementEventKindLeaderboardSubmitted;
            result = [[URAchievementEvent alloc] initWithKind:kind itemID:leaderboard->id
                                                        title:URStringOrEmpty(leaderboard->title)
                                                       detail:URStringOrNil(leaderboard->description)
                                                        value:URStringOrNil(leaderboard->tracker_value)
                                                     imageURL:nil points:0];
            break;
        }
        case RC_CLIENT_EVENT_LEADERBOARD_TRACKER_SHOW:
        case RC_CLIENT_EVENT_LEADERBOARD_TRACKER_HIDE:
        case RC_CLIENT_EVENT_LEADERBOARD_TRACKER_UPDATE: {
            const rc_client_leaderboard_tracker_t *tracker = event->leaderboard_tracker;
            if (!tracker) return;
            URAchievementEventKind kind = event->type == RC_CLIENT_EVENT_LEADERBOARD_TRACKER_SHOW ? URAchievementEventKindTrackerShown
                : event->type == RC_CLIENT_EVENT_LEADERBOARD_TRACKER_HIDE ? URAchievementEventKindTrackerHidden
                : URAchievementEventKindTrackerUpdated;
            result = [[URAchievementEvent alloc] initWithKind:kind itemID:tracker->id title:@"" detail:nil
                                                        value:URStringOrNil(tracker->display) imageURL:nil points:0];
            break;
        }
        case RC_CLIENT_EVENT_GAME_COMPLETED: {
            const rc_client_game_t *game = rc_client_get_game_info(_client);
            result = [[URAchievementEvent alloc] initWithKind:URAchievementEventKindGameCompleted itemID:game ? game->id : 0
                                                        title:game ? URStringOrEmpty(game->title) : @"" detail:nil value:nil
                                                     imageURL:game ? URStringOrNil(game->badge_url) : nil points:0];
            break;
        }
        case RC_CLIENT_EVENT_SUBSET_COMPLETED: {
            const rc_client_subset_t *subset = event->subset;
            result = [[URAchievementEvent alloc] initWithKind:URAchievementEventKindSubsetCompleted itemID:subset ? subset->id : 0
                                                        title:subset ? URStringOrEmpty(subset->title) : @"" detail:nil value:nil
                                                     imageURL:subset ? URStringOrNil(subset->badge_url) : nil points:0];
            break;
        }
        case RC_CLIENT_EVENT_SERVER_ERROR: {
            const rc_client_server_error_t *error = event->server_error;
            result = [[URAchievementEvent alloc] initWithKind:URAchievementEventKindServerError itemID:error ? error->related_id : 0
                                                        title:error ? URStringOrEmpty(error->api) : @""
                                                       detail:error ? URStringOrNil(error->error_message) : nil
                                                        value:nil imageURL:nil points:0];
            break;
        }
        case RC_CLIENT_EVENT_DISCONNECTED:
        case RC_CLIENT_EVENT_RECONNECTED:
        case RC_CLIENT_EVENT_RESET: {
            URAchievementEventKind kind = event->type == RC_CLIENT_EVENT_DISCONNECTED ? URAchievementEventKindDisconnected
                : event->type == RC_CLIENT_EVENT_RECONNECTED ? URAchievementEventKindReconnected
                : URAchievementEventKindResetRequired;
            result = [[URAchievementEvent alloc] initWithKind:kind itemID:0 title:@"" detail:nil value:nil imageURL:nil points:0];
            break;
        }
        default:
            return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ handler(result); });
}

#pragma mark Rules

+ (BOOL)isCore:(NSString *)coreName allowedForConsole:(NSInteger)consoleID {
    return rc_libretro_is_system_allowed(coreName.UTF8String, (uint32_t)consoleID) != 0;
}

+ (nullable NSString *)disallowedOptionForCore:(NSString *)coreName console:(NSInteger)consoleID
                                      options:(NSDictionary<NSString *, NSString *> *)options {
    // Rules for the core on every console, and for this console only.
    const rc_disallowed_setting_t *lists[] = {
        rc_libretro_get_disallowed_settings(coreName.UTF8String),
        rc_libretro_get_disallowed_settings_for_system(coreName.UTF8String, (uint32_t)consoleID),
    };
    for (NSString *key in [options.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        for (size_t i = 0; i < sizeof(lists) / sizeof(lists[0]); i++) {
            if (lists[i] && !rc_libretro_is_setting_allowed(lists[i], key.UTF8String, options[key].UTF8String)) return key;
        }
    }
    return nil;
}

@end
