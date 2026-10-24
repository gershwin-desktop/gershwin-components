/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/**
 * The MPRIS2 side of the media hub: finds the media players on the session
 * bus, keeps what each of them is doing, and steers them.
 *
 * MPRIS2 is the interface every media player on a Linux or BSD session
 * speaks: VLC, mpv, Rhythmbox, a music player in a browser.  A player takes
 * a bus name of the form org.mpris.MediaPlayer2.<instance> and answers on
 * the object /org/mpris/MediaPlayer2, where the interface
 * org.mpris.MediaPlayer2.Player carries the six transport methods and the
 * PlaybackStatus and Metadata properties.
 *
 * All of this happens on a worker thread of its own, on a bus connection
 * that belongs to this object alone, because a blocking call on a bus is a
 * call that can hold the menu bar up, and because Menu's own bus connection
 * belongs to the global menu importer and must not be given another
 * object path to answer for.  Nothing here is called from the main thread
 * except -start, -stop, -players, -sendCommand:toPlayerWithBusName: and
 * -requestRefresh, and all of those answer at once: the work is queued for
 * the worker and the answer is what the last poll found.
 */

/// Posted on the main thread when the players or what they are doing
/// changed, so the menu bar can show it.
extern NSString * const MPRISMediaControllerChangedNotification;

/* The keys of one entry in -players.  The player's bus name is under
   MPRISPlayerBusNameKey, which is also what -sendCommand:toPlayerWithBusName:
   takes; the rest describe what the player is doing. */
extern NSString * const MPRISPlayerBusNameKey;
extern NSString * const MPRISPlayerIdentityKey;
extern NSString * const MPRISPlayerStatusKey;
extern NSString * const MPRISPlayerTitleKey;
extern NSString * const MPRISPlayerArtistKey;

@interface MPRISMediaController : NSObject

/// The one controller of the process.  It is not started by this call; see
/// -start.  +sharedController is @synchronized, so it may be reached from
/// any thread.
+ (instancetype)sharedController;

/**
 * Connects to the session bus and starts the worker, once.  Answers YES
 * when the worker runs, NO when the bus is not there or the worker was
 * already running.
 */
- (BOOL)start;

/// Stops the worker and drops the bus connection.  A stopped controller can
/// be started again.  Answers when the worker is gone.
- (void)stop;

/**
 * Every player that was on the bus at the last poll, as an array of
 * dictionaries keyed by the constants above, sorted by bus name.  The
 * states are the MPRIS ones spelled as GSMediaPlayer2 does: "Playing",
 * "Paused", "Stopped".  Empty when no player runs.
 */
@property (nonatomic, readonly, copy) NSArray<NSDictionary *> *players;

/**
 * Sends one transport method - Play, Pause, PlayPause, Stop, Next or
 * Previous - to a player.  Answers YES when the command was queued for a
 * player of that name, NO when the name is not one of the players, in which
 * case nothing is sent.  The answer says the command was sent, not that the
 * player acted on it: MPRIS has no way to ask that, and a player that has
 * gone away in between drops the message.
 */
- (BOOL)sendCommand:(NSString *)method toPlayerWithBusName:(NSString *)busName;

/// Looks the bus over again at once instead of at the next poll.
- (void)requestRefresh;

@end
