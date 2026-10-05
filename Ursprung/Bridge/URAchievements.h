// SPDX-License-Identifier: GPL-3.0-or-later
// Ursprung — RetroAchievements through rcheevos' rc_client: signing in,
// identifying the running game, evaluating its achievements every frame and
// reporting unlocks. One client lives for the whole app session.
//
// Threads: sign-in and game loading may be started from any thread and
// complete on the main queue. -doFrameWithCore: and -idleWithCore: belong to
// the emulation thread; they are the only calls that read the game's memory.

#import <Foundation/Foundation.h>

#import "URLibretroCore.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, URAchievementEventKind) {
    URAchievementEventKindUnlocked,
    URAchievementEventKindLeaderboardStarted,
    URAchievementEventKindLeaderboardFailed,
    URAchievementEventKindLeaderboardSubmitted,
    URAchievementEventKindChallengeShown,
    URAchievementEventKindChallengeHidden,
    URAchievementEventKindProgressShown,
    URAchievementEventKindProgressHidden,
    URAchievementEventKindTrackerShown,
    URAchievementEventKindTrackerHidden,
    URAchievementEventKindTrackerUpdated,
    URAchievementEventKindGameCompleted,
    URAchievementEventKindSubsetCompleted,
    URAchievementEventKindServerError,
    URAchievementEventKindDisconnected,
    URAchievementEventKindReconnected,
    /// Hardcore mode was switched on: the game has to restart.
    URAchievementEventKindResetRequired,
} NS_SWIFT_NAME(AchievementEventKind);

/// Something the player should hear about, e.g. an unlocked achievement.
NS_SWIFT_NAME(AchievementEvent)
NS_SWIFT_SENDABLE
@interface URAchievementEvent : NSObject
@property (nonatomic, readonly) URAchievementEventKind kind;
/// The achievement, leaderboard or tracker this is about.
@property (nonatomic, readonly) NSUInteger itemID;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy, nullable) NSString *detail;
/// A value to show: a progress ("3/10"), a score or a tracker reading.
@property (nonatomic, readonly, copy, nullable) NSString *value;
@property (nonatomic, readonly, copy, nullable) NSString *imageURL;
@property (nonatomic, readonly) NSInteger points;
@end

/// One achievement of the loaded game.
NS_SWIFT_NAME(AchievementInfo)
NS_SWIFT_SENDABLE
@interface URAchievementInfo : NSObject
@property (nonatomic, readonly) NSUInteger achievementID;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSString *detail;
@property (nonatomic, readonly) NSInteger points;
@property (nonatomic, readonly) BOOL isUnlocked;
/// The game can't evaluate it with this version of rcheevos.
@property (nonatomic, readonly) BOOL isUnsupported;
@property (nonatomic, readonly, copy, nullable) NSDate *unlockDate;
/// e.g. "250/1000"; empty when the achievement measures nothing.
@property (nonatomic, readonly, copy) NSString *progress;
@property (nonatomic, readonly) float progressFraction;
@property (nonatomic, readonly, copy, nullable) NSString *imageURL;
/// Share of players who unlocked it, 0…100.
@property (nonatomic, readonly) float rarity;
@end

/// The loaded game as RetroAchievements knows it.
NS_SWIFT_NAME(AchievementGameInfo)
NS_SWIFT_SENDABLE
@interface URAchievementGameInfo : NSObject
@property (nonatomic, readonly) NSUInteger gameID;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy, nullable) NSString *imageURL;
@property (nonatomic, readonly) NSInteger achievementCount;
@property (nonatomic, readonly) NSInteger unlockedCount;
@property (nonatomic, readonly) NSInteger points;
@property (nonatomic, readonly) NSInteger unlockedPoints;
@end

/// The signed-in user.
NS_SWIFT_NAME(AchievementUser)
NS_SWIFT_SENDABLE
@interface URAchievementUser : NSObject
@property (nonatomic, readonly, copy) NSString *username;
@property (nonatomic, readonly, copy) NSString *displayName;
/// Store this to sign in again later without the password.
@property (nonatomic, readonly, copy) NSString *token;
@property (nonatomic, readonly) NSInteger score;
@property (nonatomic, readonly) NSInteger softcoreScore;
@property (nonatomic, readonly, copy, nullable) NSString *imageURL;
@end

NS_SWIFT_NAME(AchievementClient)
NS_SWIFT_SENDABLE
@interface URAchievements : NSObject

- (instancetype)initWithClientName:(NSString *)name version:(NSString *)version NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Hardcore: unlocks count fully, but states, rewind and cheats are off.
/// Set it before -loadGameAtPath:…; it takes effect in order with game
/// loading and unloading.
@property (atomic) BOOL hardcoreEnabled;

/// Events, delivered on the main queue.
@property (atomic, copy, nullable) void (^NS_SWIFT_SENDABLE eventHandler)(URAchievementEvent *event);

- (void)loginWithUsername:(NSString *)username password:(NSString *)password
               completion:(void (^NS_SWIFT_SENDABLE)(URAchievementUser *_Nullable user, NSError *_Nullable error))completion;
- (void)loginWithUsername:(NSString *)username token:(NSString *)token
               completion:(void (^NS_SWIFT_SENDABLE)(URAchievementUser *_Nullable user, NSError *_Nullable error))completion;
- (void)logout;
@property (nonatomic, readonly, nullable) URAchievementUser *user;

/// Identifies the game file at `path` for RetroAchievements console
/// `consoleID` and loads its achievements. The completion has nil and nil
/// when the game has no achievements.
- (void)loadGameAtPath:(NSString *)path consoleID:(NSInteger)consoleID
            completion:(void (^NS_SWIFT_SENDABLE)(URAchievementGameInfo *_Nullable game, NSError *_Nullable error))completion;
/// Stops evaluating the game. Call after its core has unloaded.
- (void)unloadGame;
/// The game restarted (reset): progress starts over.
- (void)resetGame;
/// A state was loaded: progress that depended on the previous moment is dropped.
- (void)stateLoaded;

@property (nonatomic, readonly) BOOL isGameLoaded;
@property (nonatomic, readonly, nullable) URAchievementGameInfo *gameInfo;
@property (nonatomic, readonly, copy) NSArray<URAchievementInfo *> *achievements;
/// What the player is doing, as RetroAchievements shows it to others.
@property (nonatomic, readonly, copy, nullable) NSString *richPresence;

// Emulation thread.
- (void)doFrameWithCore:(URLibretroCore *)core;
- (void)idleWithCore:(URLibretroCore *)core;

/// Whether RetroAchievements accepts `coreName` (libretro library name) for the console.
+ (BOOL)isCore:(NSString *)coreName allowedForConsole:(NSInteger)consoleID;
/// The first core option among `options` that hardcore mode doesn't allow, or nil.
+ (nullable NSString *)disallowedOptionForCore:(NSString *)coreName console:(NSInteger)consoleID
                                      options:(NSDictionary<NSString *, NSString *> *)options;

@end

NS_ASSUME_NONNULL_END
