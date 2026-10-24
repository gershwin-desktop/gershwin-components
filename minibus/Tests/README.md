# minibus conformance suite

Wire-protocol tests for the bus daemon. Every scenario is written against
`/usr/bin/dbus-daemon` first (`MINIBUS_TEST_DAEMON=real`, must be green) and then
run against minibus. The tests speak the raw wire protocol through their own
client library (`wire.c`), sharing no code with the daemon.

## Use

    ./run.sh                          # build, run everything against minibus
    MINIBUS_TEST_DAEMON=real ./run.sh # check the suite itself against dbus-daemon
    MINIBUS_BIN=/path/minibus ./run.sh
    ./run.sh t_Names t_Match          # selected tools (interop.sh only in a full run)
    ./obj/t_Fds                       # one tool directly (after gmake)

`run.sh` works from any directory, runs the tools in parallel (each on its own
daemon and private socket under `$MINIBUS_TEST_TMP`, `$TMPDIR` or `/tmp`) and
exits non-zero when anything failed. Without a built minibus it prints SKIP and
exits 0. Build only: `gmake` here (never `gnustep-tests`, it rewrites the
GNUmakefile). Output of a tool: `Passed test:` / `Failed test:` lines of
ObjectTesting; a hang or crash is caught by a watchdog (`MINIBUS_TEST_TIMEOUT`,
default 240 s) and reported as a failure.

Environment: `MINIBUS_TEST_DAEMON` (real|minibus, default minibus),
`MINIBUS_BIN` (default `../obj/minibus` relative to this directory),
`MINIBUS_TEST_NOBUILD=1`, `MINIBUS_TEST_SERIAL=1`, `MINIBUS_TEST_CLIENTS`
(t_Scale crowd; default 900 real, 1100 minibus), `MINIBUS_TEST_FLOOD_MB`
(default 96), `MINIBUS_TEST_TMP`. minibus is started as
`minibus --address=unix:path=<private>/s --nofork --print-address`; the real
daemon with `test-bus.conf` (permissive policy, ANONYMOUS allowed, no
activation, big limits).

## Files

| file | content |
|---|---|
| `wire.h/.c` | client: SASL, message builder/parser (both byte orders, all types, fds), raw injection, timed reads, helpers |
| `harness.h/.c` | starts and stops the daemon under test on a private socket, watchdog |
| `t.h` | ObjectTesting glue (`T()` = PASS) and call helpers |
| `t_Sasl` | every SASL command, malformed lines, limits, ordering |
| `t_Hello` | Hello, unique names, behaviour before registration |
| `t_Validation` | about 170 malformed or odd messages: the connection must drop and nobody else suffer |
| `t_Names` | RequestName/ReleaseName, queues, replacement, NameOwnerChanged/Acquired/Lost, ordering |
| `t_BusMethods` | every `org.freedesktop.DBus` method, Properties, Peer, Introspectable, error paths |
| `t_Match` | every match key, quoting, invalid rules, duplicates, RemoveMatch |
| `t_Monitor` | BecomeMonitor |
| `t_Routing` | unicast/broadcast, errors, NoReply, ordering, framing, sizes, endianness, all types |
| `t_Fds` | SCM_RIGHTS, negotiation, count mismatches, fd leaks of the daemon |
| `t_Scale` | 900-1100 clients (beyond FD_SETSIZE), fan-out, slow readers, churn |
| `t_Cli` | `--print-address`, `--print-pid`, signals, stale and live sockets |
| `t_System` | minibus only: system bus policy and socket modes, address forms, command line options, limits, reserved names (skips itself against the real daemon) |
| `interop.sh` | dbus-send, dbus-monitor, busctl, gdbus, python-dbus, GDBus; missing tools are skipped |
| `OBSERVED-BEHAVIOUR.md` | what the real daemon does, including its quirks |

## Deliberate minibus differences (asserted per mode in the tests)

| area | real dbus-daemon | minibus |
|---|---|---|
| `ListActivatableNames` | `["org.freedesktop.DBus"]` | `[]` |
| `StartServiceByName` | `ServiceUnknown` | `ServiceUnknown` (same) |
| `UpdateActivationEnvironment`, `ReloadConfig` | accepted | accepted (no-op) |
| second daemon on a live socket | steals it | must refuse and exit non-zero |
| SIGINT | killed by the signal, socket file stays | clean exit 0, socket removed |
| `--pid-file=`, bare path, `--session`, `--system`, `--syslog`, `--config-file=` | not (all) accepted | accepted (t_Cli, minibus only) |
| `eavesdrop='true'` match rules | work (policy allows) | not required (t_Monitor tests it for real only) |
| `Debug.Stats`, `Verbose` interfaces | exist | not required (not tested) |
| security policy, XML config, activation | yes | none: no AccessDenied for anything |

Everything else is asserted identically for both. Where the real daemon does
something the specification does not prescribe (see OBSERVED-BEHAVIOUR.md) the
test accepts either the real behaviour or the sensible alternative and says so
in its description, or does not test it.

## Notes for the daemon author

- `t_Validation` expects connection drops for malformed messages exactly as
  the real daemon does; a bystander is checked after each case.
- `t_Scale` needs `ulimit -n` above about 2400 for the minibus crowd (the
  harness raises the soft limit to the hard limit, up to 8192).
- Tests that count descriptors or memory of the daemon read `/proc/<pid>` and
  are skipped silently (tolerant) where that does not exist.
- Coverage: build minibus with `--coverage`, run `MINIBUS_BIN=... ./run.sh`;
  the tools terminate the daemon with SIGTERM so the gcov data is written.
