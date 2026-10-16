/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef GSMediaControl_h
#define GSMediaControl_h

#import <Foundation/Foundation.h>
#import <Foundation/NSConnection.h>

#import "GSMediaPlayer2.h"

/**
 * The media control interface of Gershwin: what a program asks Menu.app to
 * do to the media player that is playing.
 *
 * This is the other half of GSMediaPlayer2.  GSMediaPlayer2 is what a
 * *player* serves, so that programs can talk to a native Gershwin player
 * that speaks no D-Bus.  This is what Menu.app serves, so that programs can
 * talk to a player that is not a Gershwin player at all: Menu watches the
 * session bus for the players that implement MPRIS2 - VLC, mpv, Rhythmbox,
 * a browser, anything - and steers them there, so that a program which
 * speaks no D-Bus does not have to.  The method names and the spelled
 * playback states are the same as in GSMediaPlayer2 and in MPRIS itself, so
 * one call reads the same whichever side of the hub it is written for.
 *
 * Menu.app is the one that serves this, and it is the one extra in the menu
 * bar that shows what plays.  The extra is the only part that needs a bus:
 * where libdbus is missing, the extra is not built, and this interface keeps
 * answering - it simply reports that no player is running, and that the
 * native Gershwin player, if any, is the one it steers.
 *
 * This header is all a client needs: it declares the interface, the name
 * Menu registers it under and GSMediaControlProxy(), which looks that name
 * up and hands back a proxy that is already set up.  It is written to be
 * included unchanged by a program built with ARC and by one built without
 * it, like GSMediaPlayer2.h.
 *
 *     #import "GSMediaControl.h"
 *
 *     id<GSMediaControl> media = GSMediaControlProxy();
 *     if (media == nil) {
 *         // Menu.app is not running, so nothing is steering a player.
 *     } else if ([media hasPlayers]) {
 *         [media playPause];
 *     }
 *
 * MediaRemote/PROTOCOL.md describes the whole interface.
 */

/**
 * The name Menu registers this interface under.
 *
 * A macro and not an extern string, because this header is the whole of the
 * client side: a program must be able to include it and use it without
 * linking anything of ours.  The name is the wire name of the service and
 * never changes.
 */
#define GSMediaControlServiceName @"io.github.gershwin-desktop.MediaControl"

/**
 * The interface Menu.app serves.  The proxy carries this protocol, so both
 * sides agree on the qualifiers (bycopy) below.
 *
 * Every transport method answers YES when the command went to a player and
 * NO when there was no player to send it to, so a client that only wants to
 * pause what is playing can answer from the return value instead of asking
 * for the state first.  None of them waits for the player to act on the
 * command: a player that has gone away between the check and the send is
 * dropped, and the next state query says so.
 */
@protocol GSMediaControl <NSObject>

/* Transport (MPRIS: Play, Pause, PlayPause, Stop, Next, Previous). */

/// Plays what is loaded, or the loaded item again after Stop.
- (BOOL)play;
/// Falls silent: pauses a file, stops a live stream.
- (BOOL)pause;
/// Plays when stopped or paused, pauses when it plays: the button.
- (BOOL)playPause;
/// Stops playback; what is loaded stays loaded.
- (BOOL)stop;
/// The item after the current one.
- (BOOL)next;
/// The item before the current one.
- (BOOL)previous;

/* State (MPRIS: PlaybackStatus, Identity). */

/// YES while a player is running that this interface can steer.
- (BOOL)hasPlayers;

/// GSMediaPlayer2Playing, GSMediaPlayer2Paused or GSMediaPlayer2Stopped for
/// the player the transport methods above act on: the one the user picked,
/// or else the one that plays, or else the first one running.  Stopped when
/// there is no player.
- (bycopy NSString *)playbackStatus;

/// The name of that player, e.g. "VLC" or "Player".
- (bycopy NSString *)identity;

/**
 * Every player Menu can see, as one property list in a string: an array of
 * dictionaries, one per player.  Each holds:
 *
 *   identifier      the player's name on the bus, or the name it is
 *                   registered under over Distributed Objects.  This is
 *                   what -usePlayer: takes.
 *   identity        the player's own name for itself, e.g. "VLC"
 *   playbackStatus  GSMediaPlayer2Playing, -Paused or -Stopped
 *   title           the item playing, e.g. a track title.  Empty when the
 *                   player does not say, which is the case for a native
 *                   Gershwin player, which MPRIS metadata has no place for.
 *   artist          who plays it, e.g. a track artist.  Empty as above.
 *   native          YES for a player reached over Distributed Objects, NO
 *                   for one reached over MPRIS2.
 *
 * Carried as a string and not returned as an NSArray, because a returned
 * collection does not survive the trip on this runtime: it arrives as a proxy
 * standing in for the server's own array, so a client is handed something
 * that answers -count and -objectAtIndex: over the wire but is not an NSArray,
 * and every dictionary inside it is a proxy as well.  That is true with and
 * without bycopy - bycopy is not what decides it, and asking for it only
 * changes how the return is encoded.  A string is a value and comes across as
 * one, so the list travels as text and GSMediaControlPlayers() below turns it
 * back into real objects on the caller's side.
 *
 * Use GSMediaControlPlayers() rather than reading this directly.
 */
- (bycopy NSString *)playersPropertyList;

/// Steers `identifier` from now on, as -playbackStatus describes.  NO when
/// no player of that name is running.
- (BOOL)usePlayer:(bycopy NSString *)identifier;

/**
 * Looks the session bus over again at once instead of at the next poll.
 * A client that has just started a player can call this to see it without
 * waiting.  It answers as soon as the request is queued.
 */
- (void)refresh;

@end

/**
 * A proxy for the media control service, or nil when Menu.app is not
 * running.  The proxy carries @protocol(GSMediaControl) and short timeouts,
 * so a call on it cannot hold a program up for long.
 *
 * The proxy is looked up on every call and is not cached: Menu.app can be
 * restarted at any time, and a cached proxy to a program that is gone would
 * keep answering NO forever.
 */
static inline id<GSMediaControl> GSMediaControlProxy(void)
{
    NSDistantObject *proxy = [NSConnection rootProxyForConnectionWithRegisteredName:GSMediaControlServiceName
                                                                              host:nil];
    if (proxy == nil) {
        return nil;   // Menu.app is not running
    }
    [proxy setProtocolForProxy:@protocol(GSMediaControl)];
    NSConnection *connection = [proxy connectionForProxy];
    [connection setRequestTimeout:2.0];
    [connection setReplyTimeout:2.0];
    return (id<GSMediaControl>)proxy;
}

/**
 * Every player Menu can see, as a real NSArray of real NSDictionaries - one
 * per player, with the keys -playersPropertyList describes.
 *
 * An empty array when Menu.app is not running, cannot be reached, or has
 * nothing playing.  Never nil, and never a proxy standing in for the far
 * side: this is the whole reason the list travels as text.
 *
 * The array is autoreleased, as anything a convenience function hands back
 * here is.  A program built without ARC must not release it.
 */
static inline NSArray *GSMediaControlPlayers(id<GSMediaControl> control)
{
    if (control == nil) {
        return [NSArray array];
    }
    NSString *text = nil;
    @try {
        text = [control playersPropertyList];
    }
    @catch (NSException *e) {
        /* Menu.app went away between the lookup and the call, or answered
           with something that is not a list.  An empty list is the honest
           answer either way. */
        return [NSArray array];
    }
    if ([text length] == 0) {
        return [NSArray array];
    }
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) {
        return [NSArray array];
    }
    id decoded = [NSPropertyListSerialization propertyListWithData:data
                                                          options:NSPropertyListImmutable
                                                           format:NULL
                                                            error:NULL];
    if ([decoded isKindOfClass:[NSArray class]]) {
        return decoded;
    }
    return [NSArray array];
}

#endif /* GSMediaControl_h */
