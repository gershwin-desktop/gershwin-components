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
    MediaRemote/GSMediaControl.h    what Menu serves, for programs with no bus
    Player/PlayerMediaRemote.m      Player's server side
    Menu/MediaHub.m                 Menu's side of both
    MediaRemote/PROTOCOL.md         this file

## The two directions

`GSMediaPlayer2` is what a **player** serves, so a program can reach a native
Gershwin player that speaks no D-Bus. Whisper uses it to fall silent while
its microphone is open.

`GSMediaControl` is what **Menu** serves, for the other direction: a program
that wants to steer whatever is playing, without a bus. Menu watches the
session bus for the players that implement MPRIS2 - VLC, mpv, Rhythmbox, a
player in a browser - and steers them there, so a program written against
`GSMediaControl` reaches all of them through one interface, and reaches a
native Gershwin player through the same one. The method names and the spelled
states are the same in all three interfaces, so a call reads the same
wherever it is written.

| | MPRIS2 | GSMediaPlayer2 | GSMediaControl |
| --- | --- | --- | --- |
| **served by** | VLC, mpv, ... | Player | Menu |
| **transport** | over D-Bus | over DO | over DO |
| **client** | any D-Bus program | Whisper | any program |
| **can say what plays** | yes | no | yes, from either side |

A native Gershwin player has no MPRIS metadata and no D-Bus, so
`GSMediaControl` is where the two halves meet: `MediaHub` in Menu keeps the
MPRIS players and the native one in a single list, shows the first playing
one, and sends each command to whichever kind it is.

## Using GSMediaControl

`MediaRemote/GSMediaControl.h` is the whole of the client side - it declares
the interface, the name Menu registers it under and `GSMediaControlProxy()`,
which looks that name up and hands back a proxy already set up. A program
includes it and links nothing:

```objc
#import "GSMediaControl.h"

id<GSMediaControl> media = GSMediaControlProxy();
if (media == nil) {
    // Menu.app is not running, so nothing is steering a player.
} else if ([media hasPlayers]) {
    [media playPause];
}
```

`GSMediaControlPlayers()` lists every player Menu can see, each as a
dictionary with `identifier`, `identity`, `playbackStatus`, `title`, `artist`
and `native`, and `-usePlayer:` picks which one the transport methods act on.
A transport method answers YES when the command was sent to a player and NO
when there was none; it does not wait for the player to act on it.
`-refresh` looks the bus over again at once, for a program that has just
started a player.

The list crosses the wire as one property list in a string, read by
`GSMediaControlPlayers()`. It has to: a returned collection does not survive
the trip on this runtime. An `NSArray` comes back as a proxy standing in for
the server's own array - it answers `-count` and `-objectAtIndex:` over the
wire, but it is not an `NSArray`, and every dictionary inside it is a proxy
too. That is the same with and without `bycopy`, which changes only how the
return is encoded. A string is a value and arrives as one, so the helper
decodes the list into real objects on the caller's side.

The states and the player service name are `#define`s in
`GSMediaPlayer2.h` rather than declared strings, so that a program which only
needs to say which state something is in can use them without linking
`GSMediaPlayer2.m` - which is what lets Menu speak both interfaces in one
binary.

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
`GSMediaPlayer2PlayerServiceName` cover the one Player registers.  Menu
looks that name up to steer Player from the menu bar; see the two
directions above.

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

## Interface reference: GSMediaControl

What Menu serves, as a client sees it.  Every method is on the proxy from
`GSMediaControlProxy()`; none of them waits for a player to act on a
command.

| method | answers |
| --- | --- |
| `-play` / `-pause` / `-playPause` / `-stop` / `-next` / `-previous` | `YES` when the command was sent to a player, `NO` when there was none to send it to |
| `-hasPlayers` | `YES` while a player runs that this interface can steer |
| `-playbackStatus` | `Playing`, `Paused` or `Stopped`, for the player the transport methods act on |
| `-identity` | that player's own name, e.g. `VLC` or `Player` |
| `-playersPropertyList` | the list of players as a property list in a string: one dictionary per player, with `identifier`, `identity`, `playbackStatus`, `title`, `artist`, `native`. Read it with `GSMediaControlPlayers()`, which is what a program should call |
| `-usePlayer:` | `YES` when that player is running, and it is steered from now on |
| `-refresh` | nothing; the request is queued |

The player the transport methods act on is the one the user picked, or else
the first one playing, or else the first one running.  A player that is
picked and then quits is not waited for.

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
