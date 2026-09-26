# GSMediaPlayer2 - the Gershwin media remote protocol

How one program in the session starts, stops and pauses a media player
running in the same session, over Distributed Objects, not D-Bus.

This is the shape of the XDG MPRIS interface
(`org.mpris.MediaPlayer2.Player`): the same method names, the same
spelled playback states, one registered name per player.  Gershwin has
no D-Bus, so the transport is an `NSConnection` with a registered name
instead of a bus name.  On top of MPRIS sits one addition MPRIS does
not need: a *pause with an owner*, for the client that must silence the
player for a while - Whisper, while its microphone is open.

    MediaRemote/GSMediaPlayer2.h    the interface and the client
    MediaRemote/GSMediaPlayer2.m    the client and the service name
    Player/PlayerMediaRemote.m      Player's server side
    MediaRemote/PROTOCOL.md         this file

## Looking a player up (client)

```objc
#import "GSMediaPlayer2.h"

if ([GSMediaPlayer2Client pausePlayer]) {
    /* Player is silent; go ahead */
}
/* Later, when done - and always before quitting: */
[GSMediaPlayer2Client resumePlayer];
```

`GSMediaPlayer2Client` wraps a lookup of
`GSMediaPlayer2PlayerServiceName`, sets `@protocol GSMediaPlayer2` on
the proxy, sends one message and drops the proxy again.  Every call
takes at most 3 seconds; a player that does not answer counts as
absent, so a client never blocks on a player that is not there.

## Serving (player)

```objc
mediaRemote = [[PlayerMediaRemote alloc] initWithPlayer:self];
mediaRemoteConnection = [[NSConnection alloc] init];
[mediaRemoteConnection setRootObject:mediaRemote];
[mediaRemoteConnection registerName:GSMediaPlayer2PlayerServiceName];
NSPort *receivePort = [mediaRemoteConnection receivePort];
[[NSRunLoop currentRunLoop] addPort:receivePort forMode:NSRunLoopCommonModes];
```

Requests are served on the run loop that registered the connection, so
the server may talk to the player's own objects directly.  Adding the
receive port to the common modes answers requests even while a panel is
up; a client that still times out treats the player as absent.

One registered name per player: several players may run, each under
its own name of its own choosing.  This document and
`GSMediaPlayer2PlayerServiceName` cover the one Player registers.

## Interface

### Transport (all `oneway`-free, they answer when done)

| method | does |
| --- | --- |
| `-play` | Plays what is loaded unless it already plays |
| `-pause` | Falls silent at once; pauses a file, stops a live stream |
| `-playPause` | Plays when stopped or paused, pauses when it plays |
| `-stop` | Stops playback; what is loaded stays loaded |
| `-next` | The item after the current one |
| `-previous` | The item before the current one |

### State

| method | answers |
| --- | --- |
| `-playbackStatus` | `GSMediaPlayer2Playing`, `GSMediaPlayer2Paused` or `GSMediaPlayer2Stopped` (spelled strings, bycopy) |
| `-identity` | A short stable name for this player, `@"Player"` |

### Pausing for one client

| method | answers |
| --- | --- |
| `-pauseForClient:` | `YES` when the player fell silent for that client token, `NO` when it did not and it is not this client's to give back |
| `-resumeForClient:` | `YES` when the pause was given back and the player plays again, `NO` when there was nothing to give back |

A pause has exactly one owner, the client token that took it:

- `-pauseForClient:` while nothing plays, or while the player sits
  paused for the user, answers `NO`: there is no pause to take.
- `-pauseForClient:` from a second client while one holds the pause
  answers `NO`.  The same token asking again answers `YES` without
  touching the player again.
- The pause ends by itself when the player moves for a reason of its
  own - a button, a stream that starts or fails, a stop.  The player
  reports that from its state-change callbacks, and every entry point
  of the interface checks it again, so a client that waited too long
  finds `NO` rather than a player it never paused.
- `-play`, `-stop` and `-playPause` end the pause first: they are the
  player acting for someone else.
- `-next` and `-previous` forward and then check again.
- `-resumeForClient:` gives the pause back only to its owner, and
  plays whatever the player now holds.

## States and modes

- Three states, spelled: `Playing`, `Paused`, `Stopped`.
- A live radio stream pauses by stopping: it cannot resume where it
  paused.  Resuming plays the station again from the moment it is
  reachable, which is as close to "as it was" as a live stream gets.
- While a station is tuning in, the player counts as `Playing`: it
  will be audible at once and a pause must silence it all the same.

## What a client owes the player

A client that got `YES` from `-pauseForClient:` owes the player one
`-resumeForClient:` with the same token:

- when its reason to silence the player is over (Whisper: the moment
  the microphone is closed again), and
- when it quits, before its process is gone (`applicationWillTerminate:`
  and `dealloc` are the two places a well-behaved client does this).

A client that got `NO` owes nothing: the player is not silent for it,
and it must not assume the player is playing either - only that it is
not this client's pause to give back.

Whisper pauses Player before the microphone opens and resumes it when
the recording is over or when Whisper quits, so Player is never audible
while Whisper listens, and never left silent by Whisper either.
