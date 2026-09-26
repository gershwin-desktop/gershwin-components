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
extern NSString * const GSMediaPlayer2Playing;
extern NSString * const GSMediaPlayer2Paused;
extern NSString * const GSMediaPlayer2Stopped;

/// The name Player registers its interface under.  Another player
/// registers its own name the same way, as MPRIS players register
/// org.mpris.MediaPlayer2.<identity>.
extern NSString * const GSMediaPlayer2PlayerServiceName;

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
