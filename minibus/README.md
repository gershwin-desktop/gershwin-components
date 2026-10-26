# minibus

A small D-Bus message bus daemon for the session bus and the system bus. It
passes messages and keeps track of names and match rules; it has no policy
language, no XML configuration and no service activation. It is plain C
(about 3700 lines), single threaded around `poll(2)`, and needs nothing but
libc. It is written for Linux, FreeBSD and OpenBSD and so far built and
tested on Linux only.

## Use

    minibus --session                     # $XDG_RUNTIME_DIR/bus, else a socket in /tmp
    minibus --system                      # /run/dbus/system_bus_socket (or /var/run/...)
    minibus --address=unix:path=/x/sock   # any unix: address, several separated by ';'
    minibus /tmp/minibus-1000.socket      # the older form: a bare socket path

Other options: `--print-address[=FD]`, `--print-pid[=FD]`, `--pid-file=FILE`,
`--fork`/`--nofork`, `--syslog`, `--verbose`, `--version`,
`--system-uid-max=UID`, `--owner-group=GROUP`. `--config-file` and
`--nopidfile` are accepted and ignored, so init scripts written for
dbus-daemon keep working. Addresses: `unix:path=`, `unix:abstract=` (Linux),
`unix:tmpdir=`, `unix:dir=`, `unix:runtime=yes`. SIGTERM and SIGINT stop the
bus and remove its socket; a socket file nobody listens on is replaced, a live
one is never taken over.

Gershwin starts the session bus in `Gershwin.sh`:

```
MINIBUS_SOCKET="/tmp/minibus-$(id -u).socket"
minibus "$MINIBUS_SOCKET" &
export DBUS_SESSION_BUS_ADDRESS="unix:path=$MINIBUS_SOCKET"
```

## Who may do what

Identity comes from the kernel (`SO_PEERCRED`, `getpeereid`), never from the
client. The only authentication mechanism is SASL `EXTERNAL`; `ANONYMOUS` and
`DBUS_COOKIE_SHA1` are refused.

| | session bus | system bus |
|---|---|---|
| connect | the owner of the bus and root | everyone |
| socket file | mode 0600 | mode 0666 |
| call methods, send signals | everyone connected | everyone connected |
| own a well-known name | everyone connected | root, uids up to `--system-uid-max` (999), members of `--owner-group` |
| `BecomeMonitor` | the owner of the bus and root | root (the owner of the bus) |

On the system bus every connected user may call every service. A service
that must refuse some callers asks the bus who is calling
(`GetConnectionUnixUser`, `GetConnectionCredentials`) and decides with plain
uid and group checks. There is deliberately no policy language, no polkit and
no per-method rule; the name rule only keeps ordinary users from posing as a
system service.

Replies are passed on only from the connection that was called, and only
once: a reply nobody asked for is dropped.

## What is implemented

Everything below is covered by the conformance suite in `Tests/`, which runs
every scenario against the reference dbus-daemon first and then against
minibus (`Tests/README.md`; `gmake check` runs it).

- Wire protocol: both byte orders, all types, alignment and padding checked,
  signatures, UTF-8, object paths, names, nesting depth, 128 MiB messages and
  64 MiB arrays. A malformed message closes that one connection.
- Partial reads and writes, coalesced and fragmented messages, per-connection
  write queues. A reader that falls 32 MiB behind loses messages (a caller
  gets `LimitsExceeded`), not the bus its memory.
- Unix file descriptor passing (`NEGOTIATE_UNIX_FD`, up to 16 per message).
- `org.freedesktop.DBus`: Hello, RequestName (all flags, queueing,
  replacement), ReleaseName, ListQueuedOwners, ListNames,
  ListActivatableNames, NameHasOwner, StartServiceByName,
  UpdateActivationEnvironment, GetNameOwner, GetConnectionUnixUser,
  GetConnectionUnixProcessID, GetConnectionCredentials,
  GetAdtAuditSessionData, GetConnectionSELinuxSecurityContext, AddMatch,
  RemoveMatch, GetId, ReloadConfig; signals NameOwnerChanged, NameAcquired,
  NameLost.
- Match rules with every key of the specification (type, sender, interface,
  member, path, path_namespace, destination, argN, argNpath, arg0namespace,
  eavesdrop).
- `org.freedesktop.DBus.Monitoring.BecomeMonitor`, Introspectable,
  Properties (`Features`, `Interfaces`), Peer (`Ping`, `GetMachineId`).
- `NoReply` to callers whose callee disconnects without answering.

## Deliberate differences from dbus-daemon

- No service activation: `StartServiceByName` answers `ServiceUnknown`,
  `ListActivatableNames` lists only the bus itself (as dbus-daemon does when
  it has no service files), `UpdateActivationEnvironment` is accepted and
  does nothing.
- No configuration file and no policy (see above). `ReloadConfig` does nothing.
- No `org.freedesktop.DBus.Debug.Stats` interface; `Features` is empty.
- The bus id from `GetId` is the GUID of the SASL `OK` line.
- No TCP transport, no `DBUS_COOKIE_SHA1`, no `ANONYMOUS`.
- Unsolicited replies are dropped (dbus-daemon forwards them unless its
  policy forbids it).
- Logging: auth refusals, invalid messages, denied names and monitors are
  logged to stderr (or syslog with `--syslog`); `--verbose` adds connections
  and name changes. Message contents are never logged.

## Performance

`bench/bench.c` measures call/reply round trips and signal fan-out and reads
the daemon's CPU time and peak RSS from /proc (`gmake bench`, then
`obj/bench SOCKET DAEMON-PID [calls] [signals] [listeners]`). On the
development machine (Linux, x86-64), against dbus-daemon 1.16.2 with a
permissive test configuration:

| | minibus | dbus-daemon |
|---|---|---|
| daemon CPU per routed call or reply | 1.8 us | 15 us |
| daemon CPU per signal delivery (50 listeners, 4 rules each) | 0.5 us | 5.7 us |
| RSS at start | 1.8 MiB | 3.0 MiB |
| RSS with 500 idle clients | 2.1 MiB | 7.5 MiB |
| system calls while idle | none | none |

What keeps it there: a message is validated where it was read and copied
once, into the copy that carries the sender; every recipient shares that
copy; idle connections hold no read buffer; the first arguments of a
message are looked up once for all match rules; and the loop sleeps in
`poll(2)` with no timer unless a connection is still authenticating.

## Real system services

`Tests/system-sandbox.sh` starts avahi-daemon, upowerd and NetworkManager
against a system bus inside private mount and network namespaces and queries
them (busctl, nmcli, avahi-browse/publish, dbus-monitor, a service restart).
With minibus every answer is the same as with dbus-daemon. What differs is
activation: dbus-daemon starts `nm-dispatcher`, `polkitd`, `wpa_supplicant`
and `login1` on demand, minibus does not, so a system using minibus as its
system bus has to start the services it needs from its init system
(for example `nm-dispatcher --persist` for NetworkManager's dispatcher
scripts, `wpa_supplicant -u`, elogind).

On a Gershwin Live system (Devuan 6 in QEMU, with a persistence disk so the
change survives a reboot) the init script `/etc/init.d/dbus` was changed to
start `minibus --system --fork --pid-file=/run/dbus/pid --syslog` and a small
init script starts `nm-dispatcher --persist`. The system booted with it:
elogind, avahi-daemon, NetworkManager and nm-dispatcher ran on it, LoginWindow started the desktop
session, `nmcli` worked for the desktop user, and new logins were
registered by elogind through `pam_elogind` (`CreateSessionWithPIDFD`,
which passes a descriptor). The conformance suite also passes inside that
system. How to set up such a VM again: `Tests/LIVE-VM.md`.

## Not tested here

- FreeBSD and OpenBSD: the code has their branches (`getpeereid`,
  `LOCAL_PEERCRED`, `SO_PEERCRED` with `struct sockpeercred`) but has only
  been built and run on Linux.

## Build

    gmake             # obj/minibus
    gmake check       # build and run the conformance suite
    sudo gmake install  # /System/Library/Tools/minibus
