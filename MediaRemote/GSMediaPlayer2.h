/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef GSMediaPlayer2_h
#define GSMediaPlayer2_h

#import <Foundation/Foundation.h>

/**
 * The media player remote interface of Gershwin: how a program starts,
 * stops and pauses a media player running in the same session.
 *
 * This is the Distributed Objects counterpart of the XDG MPRIS interface
 * (org.mpris.MediaPlayer2.Player).  Gershwin components talk over an
 * NSConnection instead of D-Bus, so it keeps the shape of MPRIS - the
 * same method names, the same playback states, one registered name per
 * player - and adds the pause ownership below, which MPRIS has no need
 * for because it has no client that must silence the player for a while.
 *
 * MediaRemote/PROTOCOL.md describes the whole interface, including what
 * a client owes the player after it asked for silence.
 */

/// What -playbackStatus answers: the playback states of MPRIS, spelled
/// the same way.
///
/// These are the words MPRIS itself uses on the bus, and they are defined
/// here rather than in the .m so that a program which only needs to say
/// which state something is in - Menu, which steers players on the bus -
/// can use them without linking the client below.  A state read over D-Bus
/// compares equal to one of these.
#define GSMediaPlayer2Playing @"Playing"
#define GSMediaPlayer2Paused  @"Paused"
#define GSMediaPlayer2Stopped @"Stopped"

/// The name Player registers its interface under.  Another player
/// registers its own name the same way, as MPRIS players register
/// org.mpris.MediaPlayer2.<identity>.
///
/// A macro for the reason the states above are: Menu looks this name up to
/// steer Player, and it does not link the client below.  The name is the
/// wire name of the service and never changes.
#define GSMediaPlayer2PlayerServiceName @"io.github.gershwin-desktop.MediaPlayer2.Player"

/**
 * The remote interface itself.  The server class declares conformance
 * and the client sets it on its proxy with -setProtocolForProxy:, so
 * both sides agree on the qualifiers (bycopy) below.
 */
@protocol GSMediaPlayer2 <NSObject>

/* Transport control (MPRIS: Play, Pause, PlayPause, Stop, Next,
   Previous).  Each one does nothing when it makes no sense for what is
   loaded; they never raise. */

/// Plays the loaded item, or the loaded one again after Stop.
- (void)play;
/// Pauses what plays.  A live radio stream cannot be paused and is
/// stopped instead, which leaves the player silent all the same.
- (void)pause;
/// Plays when stopped or paused, pauses when it plays: the button.
- (void)playPause;
/// Stops playback; what is loaded stays loaded.
- (void)stop;
/// The item after the current one.
- (void)next;
/// The item before the current one.
- (void)previous;

/* State (MPRIS: PlaybackStatus, Identity). */

/// GSMediaPlayer2Playing, GSMediaPlayer2Paused or GSMediaPlayer2Stopped.
- (bycopy NSString *)playbackStatus;
/// The name of the player, e.g. "Player".
- (bycopy NSString *)identity;

/* Pausing for one client.  This is what MPRIS does not have, and the
   reason this interface exists: a program that must silence the player
   - Whisper while its microphone is open - pauses it and gives the pause
   back afterwards, without being able to take a player the user paused
   for themselves along with it.

   `client` is a token that stands for the asking process, see
   +[GSMediaPlayer2Client clientToken].

   The player keeps at most one pause at a time.  It is dropped when the
   player plays or stops for a reason of its own (the user pressing a
   button, a stream failing), and then -resumeForClient: has nothing to
   give back. */

/// Asks the player to fall silent for `client`.
/// Returns YES only when the player was playing and is now paused
/// because of this call - the client then owns the pause and owes the
/// player a -resumeForClient:.  A second -pauseForClient: from the same
/// client answers YES again and changes nothing.  It answers NO when
/// nothing plays (there is nothing to silence), when the player is
/// already paused for someone else or for the user (not ours to
/// resume), or when another client holds the pause.
- (BOOL)pauseForClient:(bycopy NSString *)client;
/// Gives back a pause taken with -pauseForClient: by the same `client`.
/// The player plays again if it can.  Returns YES when this client held
/// the pause and released it, NO when it held nothing - the caller then
/// must not assume the player is playing.
- (BOOL)resumeForClient:(bycopy NSString *)client;

/* Saying that something changed.
 *
 * Everything above is a question, and a question is answered with the state
 * as it was when the player last looked.  That is enough for a client that
 * only presses buttons - it presses one and the player does what it was
 * asked - but not for a client that *shows* the state, such as Menu's media
 * extra.  Shown state has to be current, and a client cannot get that by
 * asking, because asking is what it is trying to avoid doing sixty times a
 * minute to no purpose.  MPRIS solves this with a PropertiesChanged signal;
 * there is no such thing here, so the player is asked to push instead.
 *
 * A client subscribes by giving the player the name it is registered under,
 * and the player calls -stateDidChange on that name whenever its state
 * moves.  The call is oneway: the player is in the middle of playing a track
 * or answering somebody else, and must not wait for a listener to be ready.
 *
 * A name and not a connection because this runtime cannot send one: an
 * NSConnection is not encodable across Distributed Objects at all
 * (-[NSConnection encodeWithCoder:] raises by design), so a client that
 * handed over its connection would get an exception instead of a
 * subscription.  A registered name is what every other part of Gershwin uses
 * to be found, and it encodes as the string it is.
 *
 * Both methods are optional.  A client asks for the subscription with
 * -respondsToSelector: first, because an older player does not have them
 * and a client that assumes they exist gets an exception instead of a
 * slower but working display.  The two are optional together: a player that
 * has -subscribeWatcher: has -stateDidChange.
 */

/* Subscribes the service registered under `serviceName`: it is sent
 * -stateDidChange whenever the player starts, stops, pauses or resumes.
 * Answers NO when the player will not take a subscription, and the client
 * then falls back to asking on a timer. */
- (BOOL)subscribeWatcher:(bycopy NSString *)serviceName;

/// Sent to a subscriber when the player starts, stops, pauses or resumes.
/// The subscriber's job is to ask -playbackStatus again: this says that
/// something moved, not what it moved to, so a player that is mid-change
/// does not have to describe a state it has not settled into.
///
/// A subscriber that has gone away is dropped silently: watching a player is
/// not worth an error, and the player must not be held up by a listener that
/// is no longer listening.
- (oneway void)stateDidChange;

@end

/**
 * The client side: looks the player up over Distributed Objects and
 * pairs -pauseForClient: with -resumeForClient: for this process.
 */
@interface GSMediaPlayer2Client : NSObject
{
}

/// The token this process claims pauses with: its name and process id,
/// so two clients never share a pause.
+ (NSString *)clientToken;

/// A proxy for the player registered under `name`, or nil when no such
/// player runs.  The proxy carries this protocol and short timeouts, and
/// a call on it that fails because the player went away is retried once
/// against a fresh lookup by +pausePlayer and +resumePlayer.
+ (id<GSMediaPlayer2>)proxyForService:(NSString *)name;

/// Player's proxy, or nil when Player does not run.  Kept until
/// +forgetPlayer, so a player that quits and starts again is found again.
+ (id<GSMediaPlayer2>)playerProxy;
+ (void)forgetPlayer;

/// Asks Player to fall silent for this process.  YES means Player is
/// silent because of this call, which obliges the caller to send
/// +resumePlayer as soon as it needs the sound back - including when it
/// quits.  NO means there was nothing to give back later.
+ (BOOL)pausePlayer;

/// Gives back the pause +pausePlayer took.  YES when the pause was held
/// by this process and released.
+ (BOOL)resumePlayer;

@end

#endif /* GSMediaPlayer2_h */
