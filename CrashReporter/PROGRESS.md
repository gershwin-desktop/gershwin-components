# CrashReporter - Implementation Progress

Implementing `SPEC.md`: a GNUstep/Objective-C crash reporting system
(libGSCrashReporter + gs-crashd + gs-crash-analyzer + gs-crashctl + CrashReporter.app)
for Linux/FreeBSD/OpenBSD/NetBSD.

Last updated: 2026-08-27

## Status

| # | Item | State | Notes |
|---|------|-------|-------|
| 1 | Repo layout + GNUmakefile aggregate | DONE | Top `GNUmakefile` builds `Library` then the 4 consumers. |
| 2 | Shared foundation (constants/report model/platform API/marker) | DONE | `Library/`: `GSCrashConstants`, `GSCrashReport`, `GSCrashPlatform` (Linux + generic BSD factory), `GSCrashReporter` (+install/marker), `gscrash_marker.c`. |
| 3 | `libGSCrashReporter` (deliverable .so) | DONE | Builds clean. Ships as a shared lib for external apps to link. |
| 4 | `gs-crashd` (daemon) | DONE | `Daemon/`: detector (inbox cores + markers) + collector (move core, write metadata.json, run analyzer, post `GSCrashNotificationName` via `NSDistributedNotificationCenter`). Built clean; verified detecting a real core end-to-end. |
| 5 | `gs-crash-analyzer` | DONE | `Analyzer/`: GDB/LLDB-backed backtrace + loaded-module + register capture, heuristic classification, writes `report.json` (SPEC format) + `report.txt` + `report.plist`. Verified on a live SIGSEGV core. |
| 6 | `gs-crashctl` (+ `gs-crash-test`) | DONE | `ctl/`: status/enable/disable/test/list/show/analyze/open. All subcommands return 0; `test` triggers a self-identified crash, `list`/`show` render populated reports. |
| 7 | `CrashReporter.app` (GUI) | DONE (build) | `CrashReporterApp/`: NSTableView of reports + detail view. Builds clean. NOT visually tested (no display in this environment). |
| 8 | End-to-end verification | DONE | `gs-crashctl test` -> daemon detects core -> gs-crash-analyzer produces report -> `list`/`show` render it. No segfaults. |
| 9 | Install to SYSTEM | DONE | `gmake install GNUSTEP_INSTALLATION_DOMAIN=SYSTEM`: lib + headers in `/System/Library/{Libraries,Headers/libGSCrashReporter}`, tools in `/System/Library/Tools` (gs-crashd, gs-crash-analyzer, gs-crashctl, gs-crash-test), app in `/System/Applications/CrashReporter.app`. Verified nothing of our software landed in `/Local` (only runtime crash data there). |
| 10 | Supervised launch in Gershwin.sh | DONE | Added `gs-crashd` to the `gershwin-session` args in both `/Developer/Library/Sources/gershwin-system/Library/Scripts/Gershwin.sh` and the installed `/System/Library/Scripts/Gershwin.sh`. The session supervisor now keeps the daemon alive for the whole user session and auto-restarts it on unexpected exit. |
| 11 | fswatcher instead of timer polling | DONE | `gs-crashd` no longer polls the crash inbox/markers on a 1s `NSTimer`. It subscribes to the system `fswatcher` DO service (`registerClient:` + `addWatcherForPath:` for inbox and markers dirs) and runs a debounced scan on `watchedPathDidChange:`. Falls back to a 5s poll and retries fswatcher every 15s if the service is unavailable, adopting it transparently when it appears. Client code mirrors `gershwin-workspace/Tools/fswatcher/fswatcher-test-client.m`. |
| 12 | "quit unexpectedly" dialog restyled as NSAlert | DONE | `GSCrashReportWindowController` (the window opened from `crashDetected:`, SPEC 19) is now built on `NSAlert` instead of a hand-rolled `NSWindow`: it shows the standard NSAlert icon (`NSCriticalAlertStyle`), bold message ("`<App> quit unexpectedly.`"), informative text (signal, crash time, probable cause, core-unavailable note, saved line, location), and the `Show Details` / `Open Folder` / `Copy Path` / `Close` buttons. Buttons drive the same actions as before. GNUstep `NSAlert` has no `accessoryView:`, so the crash location is folded into the informative text (path still copyable via `Copy Path`). |
| 13 | fswatcher detection regression fixed | DONE | While testing, `gs-crashd` connected to `fswatcher` and switched OFF the poll, but `fswatcher` events were not being delivered (no "crash reported" logged), so crashes went undetected - a regression versus the old 1s poll. Fixed by ALWAYS running the 5s poll as a safety net (`start`, `retryFSWatcher:`, `fswatcherConnectionDidDie:` keep `_pollTimer` active) while `fswatcher` provides immediate notification on top. Verified in isolation: the freshly installed `gs-crashd` detected a triggered crash (`crash reported` logged) even though `fswatcher` connected. |
| 14 | Double-click opens the "what to do" dialog | DONE | `doubleClicked:` on the main crash list now opens the `GSCrashReportWindowController` (the NSAlert-style "what to do with this crash report" panel with Show Details / Open Folder / Copy Path / Close) for the clicked row, instead of jumping straight to the raw `GSCrashDetailsWindowController` text view. The panel's "Show Details" still reveals the full report, so double-click -> decision dialog -> details is the natural flow. |

## Key design decisions / fixes made during the build

- **Consumers compile the library sources directly** (not linked as a dylib).
  `GSCrashReport` (and friends) is compiled into `gs-crashd`, `gs-crash-analyzer`,
  `gs-crashctl`, `gs-crash-test`, `CrashReporter.app` via each tool's `OBJC_FILES`.
  Rationale: a separately-unloaded dylib made GNUstep's atexit class-walk
  dereference dangling class pointers at process exit. Compiling the class into
  the main image avoids that entirely. The shared `.so` is still built as the
  spec-facing deliverable for external consumers.
- **ABI correctness**: every consumer uses `$(shell gnustep-config --objc-flags)`
  (resolves to `-fobjc-runtime=gnustep-2.2` on this system) instead of a
  hard-coded `-fobjc-runtime=gnustep-2.0`. Mixing 2.0/2.2 causes crashes.
- **Over-release bug fixed in `GSCrashReport populateFromDictionary`**: scalar
  `NSString*` properties were assigned directly to their ivars from the
  autoreleased plist dictionary, so the report *shared* the plist's string
  objects. The report dealloc'd before the plist (drained at main-exit), freeing
  the shared strings; the plist then released freed pointers -> SIGSEGV in
  `GSDictionary dealloc` at pool drain. Fix: route scalar assignments through the
  `copy` setters (`self.property = ...`) so the report owns independent copies.
  Container properties already deep-copy via `copyArray:`/`copyDictionary:`/
  `copyObject:`.
- **Report reload sidecar**: `writeToDirectory:` writes both `report.json` (SPEC
  format, canonical) and `report.plist` (robust GNUstep reload).
  `reportFromDirectory:` loads `report.plist` first, falls back to JSON.

## Environment notes (this box)

- GNUstep in `/System`; objc runtime `gnustep-2.2`; `/bin/gdb`, `/bin/lldb` present.
- Non-root (uid 5000). `core_pattern` is `"core"` (kernel writes to cwd),
  `ulimit -c` is 0, so real cores need `RLIMIT_CORE=INFINITY` + chdir to the
  inbox; `gs-crash-test` raises that rlimit itself. Setting `core_pattern` needs
  root (daemon logs "degraded: relies on markers"). Marker-based crashes work
  without root.
- Crash base dir: `~/.local/state/gnustep/CrashReporter` (SPEC fallback honored).

## Remaining / not yet done

- Visual GUI test of `CrashReporter.app` (needs a running GNUstep session / display).
- Root-level `core_pattern` configuration path (the `enable` subcommand sets it
  when run as root; under a normal user session the daemon degrades to marker mode).
- No automated test suite wired in (built ad-hoc `/tmp` probe programs instead).
- `gershwin-session` itself was not live-tested in this environment (it launches
  Workspace/Menu/WindowManager which need a display); the `gs-crashd` name resolves
  on the session `PATH` and the daemon pipeline was verified separately.
- The live fswatcher path was NOT exercised here (the `fswatcher` daemon only runs
  inside a Workspace session); the fallback polling path was regression-tested and
  the client code matches the known-good `fswatcher-test-client`.

## Known bugs found during UI test

- `CrashReporter.app` looped the "Crash collection partially configured" alert at
  launch: `checkConfiguration` (called from `applicationDidFinishLaunching:`) showed
  an `NSAlert` via `runModal`, and the Eau theme re-presented it repeatedly. FIXED:
  `checkConfiguration` now shows the alert at most once (guarded by `_configAlertShown`)
  and presents it as a non-blocking sheet on the main window
  (`beginSheetModalForWindow:modalDelegate:didEndSelector:`) instead of a nested
  `runModal`, so it no longer blocks the run loop or re-presents. Main window is now
  built before `checkConfiguration` so the sheet has a window to attach to.
