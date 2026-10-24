# networkmidid control interface

How network MIDI clients (the MIDI preference pane, through
`MIDINetworkDaemonBackend`) talk to `networkmidid`, the per-user network MIDI
daemon. The binding contract is `MIDINetworkControl.h`; this document
explains it. Protocol version: **1** (`MIDINETWORK_CONTROL_PROTOCOL_VERSION`).

## Process and transport

- `networkmidid` runs once per logged-in user, as that user (no root). It is a
  GNUstep tool installed to the SYSTEM Tools directory
  (`/System/Library/Tools/networkmidid`); the client treats "installed" as
  "this file exists and is executable" and shows "not installed" otherwise.
  Starting it at login is the session's job, not the pane's.
- Transport: Distributed Objects over `NSMessagePort`, registered with
  `[NSMessagePortNameServer sharedInstance]` under
  `MIDINetworkDaemonServiceName()` = `io.github.gershwin-desktop.networkmidid.<uid>`.
  Message ports are Unix domain sockets in the user's private GNUstep
  directory, so only the same user can connect; this works the same on
  Linux, FreeBSD, NextBSD and OpenBSD. No TCP, no D-Bus.
- The daemon vends one root object conforming to `MIDINetworkDaemonControl`:

```objc
NSConnection *c = [NSConnection serviceConnectionWithName:MIDINetworkDaemonServiceName()
                                               rootObject:controller
                                          usingNameServer:[NSMessagePortNameServer sharedInstance]];
```

  If the name is already registered, another networkmidid of this user runs:
  exit with an error instead of starting a second one.
- Clients set request and reply timeouts of 5 s. Every daemon method must
  answer quickly; anything slow (an invitation, discovery) answers at once
  and reports the outcome later through the client callbacks.

## Data

Every argument and result is a property list passed `bycopy` (plus `BOOL`
and `int`), so the same messages could travel over a socket as JSON later.
The keys are the constants in `MIDINetworkModels.h` and `MIDINetworkState.h`;
build and parse them with the model classes (`-propertyList`,
`+...WithPropertyList:`) rather than by hand.

| Object | Keys |
|---|---|
| session | `identifier`, `name` (local MIDI port name), `advertisedName`, `port` (UDP control port; data uses port + 1), `enabled` (bool), `policy` (`anyone`, `directory`, `nobody`) |
| host | `identifier`, `name`, `address`, `port`, `source` (`discovered`, `manual`) |
| participant | `identifier`, `name`, `address` (`host:port`), `latency` (ms, double, < 0 = not measured), `state` (`inviting`, `connected`) |
| local port | `identifier` (stable for the port's life, e.g. ALSA `client:port`), `name`, `canSend`, `canReceive` |
| route | `session`, optional `inputPort` (local port -> session), optional `outputPort` (session -> local port) |

A **snapshot** is a dictionary with five sections:

```
sessions     = ( session, ... )
directory    = ( host, ... )                 discovered and manual
participants = { <session identifier> = ( participant, ... ); ... }
routes       = ( route, ... )                at most one per session
localPorts   = ( local port, ... )
```

`+[MIDINetworkState stateWithPropertyList:]` must accept every snapshot the
daemon sends; the client rejects a malformed one as a whole.

## Messages (client -> daemon)

| Method | Effect |
|---|---|
| `-protocolVersion` | returns 1; the client refuses any other value |
| `-registerClient:` | adds a `MIDINetworkDaemonClient` proxy for change callbacks (synchronous) |
| `-unregisterClient:` | removes it |
| `-snapshot` | the whole state |
| `-addSession:` | session dictionary; the client creates the identifier |
| `-removeSession:` | session identifier; also drops its participants and route |
| `-updateSession:` | session dictionary; changes name, advertised name, port, policy, never `enabled` |
| `-setEnabled:forSession:` | opens or closes the session's sockets and mDNS announcement; closing drops its participants |
| `-addManualHost:` / `-removeHost:` | manual directory entries; discovered ones cannot be removed |
| `-connectSession:toHost:` | sends an invitation; answers at once, the participant appears as `inviting`, then `connected` or gone plus an error callback |
| `-disconnectParticipant:fromSession:` | ends that peer's connection |
| `-setRoute:` | route dictionary for one session; ports must be able to send (input) or receive (output) |

Order on connect: `protocolVersion`, `registerClient:`, then `snapshot`, so
no change can fall between registration and snapshot.

**Replies.** Every changing method returns a dictionary, never nil:

- success: `{}` or `{ changes = { <section> = ...; ... }; }`, the sections
  the change touched, in snapshot form. The client applies them at once.
- failure: `{ error = { code = <int>; message = <string>; }; }` with a code
  from `MIDINetworkErrorCode` (`MIDINetworkBackend.h`):
  1 unavailable, 2 daemonNotRunning, 3 portInUse, 4 peerRejected,
  5 timeout, 6 invalidArgument. Nothing has changed after a failure.

Use `MIDINetworkReplyWithChanges()` and `MIDINetworkReplyWithError()`.
Messages should be the fixed English sentences `MIDINetworkState` and
`MIDINetworkMakeStandardError()` produce (no inserted names or numbers):
the pane translates them by looking them up in its strings table.

## Callbacks (daemon -> every registered client)

- `-daemonDidChange:` with one or more snapshot sections. Each section
  present **replaces** that section completely (participants: the whole
  dictionary for all sessions). Send it after every change, whoever caused
  it (another client, a peer joining or leaving, discovery, a local MIDI
  port appearing), and for latency updates no more often than about once a
  second.
- `-daemonDidEncounterError:` with `{ code, message }` for failures nobody
  is waiting for: an invitation declined (peerRejected) or unanswered
  (timeout), a port taken by another program when a session is enabled
  (portInUse).

Both are `oneway`. A client whose connection dies
(`NSConnectionDidDieNotification`) or whose call raises is dropped
silently.

## Rules the daemon enforces

Link `libMIDINetworkBackend` and keep the configuration in a
`MIDINetworkState`: its mutators implement the rules below with the same
error codes and messages the simulation backend uses, so the pane behaves
the same against both.

- local names unique (case-insensitive) and non-empty; advertised name
  non-empty;
- ports 1024..65534, and no two sessions sharing a port or port + 1;
- participants only in enabled sessions; disabling drops them;
- routes only to existing ports with the right direction; a local port
  that disappears is removed from every route.

The connection policy is the daemon's to apply to *incoming* invitations:
`anyone` accepts all, `directory` accepts only hosts in the directory
(discovered or manual, matched by address), `nobody` declines all.
Outgoing invitations (`connectSession:toHost:`) are always allowed.

Persist sessions, manual hosts and routes (not participants or discovered
hosts) under the user's `~/Library` and restore them at start; the pane
stores nothing itself.

## Reference

`Tests/t_MIDINetworkDaemonBackend.m` contains `TestDaemon`, a complete
in-process implementation of this interface over a `MIDINetworkState`,
used to test the client.
