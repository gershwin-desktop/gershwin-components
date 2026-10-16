/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef PlayerMediaRemote_h
#define PlayerMediaRemote_h

#import <Foundation/Foundation.h>
#import "GSMediaPlayer2.h"

/**
 * What PlayerMediaRemote needs of the player it serves.
 *
 * PlayerController implements this; a test supplies its own fake.  The
 * methods are idempotent commands ("make it play", not "toggle"), so the
 * pause bookkeeping lives entirely in PlayerMediaRemote above them.
 */
@protocol PlayerMediaRemoteTarget <NSObject>
/// GSMediaPlayer2Playing, GSMediaPlayer2Paused or GSMediaPlayer2Stopped.
- (NSString *)mediaRemotePlaybackStatus;
/// Plays what is loaded unless it already plays.
- (void)mediaRemotePlay;
/// Falls silent at once: pauses a file, stops a live stream.
- (void)mediaRemotePause;
/// Stops playback; what is loaded stays loaded.
- (void)mediaRemoteStop;
/// The item after the current one.
- (void)mediaRemoteNext;
/// The item before the current one.
- (void)mediaRemotePrevious;
@end

/**
 * The server side of the Gershwin media remote: Player's implementation
 * of GSMediaPlayer2, registered under GSMediaPlayer2PlayerServiceName
 * (see MediaRemote/PROTOCOL.md).
 *
 * Requests arrive on the run loop the connection was registered on - the
 * main thread - so these methods talk to the player directly.
 *
 * One pause at a time is held here, by the client token that took it.  It
 * stays held only while the player still reports the very status the
 * pause left it in; the player playing, stopping or failing for a reason
 * of its own ends the pause, and -resumeForClient: then answers NO.
 */
@interface PlayerMediaRemote : NSObject <GSMediaPlayer2>
{
    id<PlayerMediaRemoteTarget> player; // not retained: the player owns us
    NSString *pauseClient;  // retained: the token holding the pause, nil if none
    NSString *pausedStatus; // retained: the status the pause left behind
    NSString *watcherName;    // retained: the service name to tell, nil if none
}
- (id)initWithPlayer:(id<PlayerMediaRemoteTarget>)aPlayer;

/// Playback moved for a reason of its own (a button, a stream, the user):
/// a pause whose status no longer matches ends here.  The player calls
/// this from its state-change callbacks.
///
/// This is bookkeeping only.  It is also called from -playbackStatus, because
/// asking the player what it is doing is a moment at which a pause may have
/// ended, and a question is not a change - so it does not tell a watcher
/// anything.  Use -playbackStateDidChange: for that.
- (void)notePlaybackChanged;

/* Tells a subscriber that the state moved, if it did.
 *
 * The player calls this when the *user* moves playback - its own buttons and
 * keys, a stream that starts or fails - which is the case the transport
 * methods above cannot see, because those are only reached when somebody
 * else asked.  `wasStatus` is what the state was before; if it is the same
 * now, nothing is sent. */
- (void)playbackStateDidChange:(NSString *)wasStatus;

@end

#endif /* PlayerMediaRemote_h */
