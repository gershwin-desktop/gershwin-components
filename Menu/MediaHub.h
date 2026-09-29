/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

#import "GSMediaControl.h"

@class MediaHub;

/**
 * One player the hub can steer, whichever side of it the player is reached
 * from: a player on the session bus that speaks MPRIS2, or a native Gershwin
 * player that speaks GSMediaPlayer2 over Distributed Objects.
 */
@interface MediaPlayerEntry : NSObject

/// How the player is addressed: its bus name, or the name it is registered
/// under over Distributed Objects.  Stable for as long as the player runs.
@property (nonatomic, readonly, copy) NSString *identifier;
/// The name the player calls itself, e.g. "VLC" or "Player".
@property (nonatomic, readonly, copy) NSString *identity;
/// GSMediaPlayer2Playing, GSMediaPlayer2Paused or GSMediaPlayer2Stopped.
@property (nonatomic, readonly, copy) NSString *playbackStatus;
/// What plays, e.g. a track title.  Empty when the player does not say.
@property (nonatomic, readonly, copy) NSString *title;
/// Who plays it, e.g. a track artist.  Empty when the player does not say.
@property (nonatomic, readonly, copy) NSString *artist;
/// YES for a player reached over Distributed Objects, NO for one reached
/// over MPRIS2.  A player on the bus is the one that can say what it is
/// playing; a native player is the one a program can ask to be quiet.
@property (nonatomic, readonly) BOOL native;

@end

/// Posted on the main thread when the players, or what they are doing,
/// changed.  The hub is `object` of the notification.
extern NSString * const MediaHubChangedNotification;

/**
 * The one place that knows every media player in the session, and steers
 * them: the MPRIS2 players Menu found on the session bus, and the native
 * Gershwin player, if one runs.  It is what the Media extra in the menu bar
 * shows, and what serves GSMediaControl to the programs that ask over
 * Distributed Objects.
 *
 * A player is asked, never waited for: the MPRIS side has a worker thread
 * and a bus connection of its own, the native side has a queue of its own,
 * and every answer here is the state as of the last poll.
 */
@interface MediaHub : NSObject <GSMediaControl>

/// The one hub of the process, already started.  @synchronized, so it may be
/// reached from any thread; the methods below must be used from the main
/// thread, which is where the hub's answer is delivered.
+ (instancetype)sharedHub;

/// Every player the hub can see, the MPRIS ones first in bus name order and
/// the native player last.  Empty when nothing runs that can be steered.
@property (nonatomic, readonly, copy) NSArray<MediaPlayerEntry *> *knownPlayers;

/// The player the transport methods act on: the one the user picked, or else
/// the first one that plays, or else the first one running.  nil when there
/// is none.
@property (nonatomic, readonly) MediaPlayerEntry *currentPlayer;

/// Steers `identifier` from now on, until that player is gone.  NO when no
/// player of that name is running.
- (BOOL)usePlayerWithIdentifier:(NSString *)identifier;

/// Looks the session bus over again at once, and asks the native player
/// again, instead of at the next poll.
- (void)refresh;

/**
 * The name the native Gershwin player is looked up under, which is
 * GSMediaPlayer2PlayerServiceName unless this says otherwise.  It is read
 * when the hub starts, so it must be set before then; only a test that
 * stands a player of its own where Player would be has a reason to.
 */
@property (nonatomic, copy) NSString *nativePlayerServiceName;

/**
 * Starts the hub: the bus worker, the poll of the native player, and the
 * service other programs call into.  +sharedHub does this, so a caller
 * that has the hub rather than the shared one needs it - a test, or a
 * program that wants a hub of its own without taking the name.
 *
 * Answers whether it is running.  Starting a started hub does nothing and
 * answers YES.
 */
- (BOOL)start;

/**
 * Stops the hub: no more polls, no more bus worker, and the service name
 * given up.  Deliberately not called -stop, which is the Player
 * interface's - the one the extra and every other client press - and which
 * steers a player rather than the hub.
 */
- (void)shutdown;

@end
