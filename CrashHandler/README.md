# CrashHandler

A GNUstep bundle that gives every GUI app a crash report. It is loaded into the app by the GUI library through the
`GSAppKitUserBundles` user default (like DriveUI and OnDemand), so apps need no code and no linking.

## What it does

- Fatal signals (SIGSEGV, SIGBUS, SIGABRT, SIGFPE, SIGILL) and uncaught Objective-C exceptions write a report to
  `~/Library/Logs/<App>-crash-<yyyymmdd-hhmmss>-<pid>.txt` and to stderr.
- The report file is created inside the handler with `O_CREAT|O_EXCL` and never earlier, so a report file never exists
  empty (the old in-app reporter opened it at launch and left empty files after SIGKILL, SIGTERM or a forced exit).
- The handler runs on a sigaltstack (main thread) and uses only async-signal-safe calls and preallocated buffers.
- Contents: app version, GNU build id, executable, thread, context lines, native backtrace (`execinfo`), the memory
  map (Linux), the last 64 user actions, the last exception the run loop caught and logged.
- The uncaught exception handler chains to the one that was there: the report is written first, then the GUI
  library's "Critical Error" alert (with Abort) appears as before. Signal handlers chain to earlier handlers too.
- Local only: nothing is uploaded.
- Symbolize offline: `sh /System/Library/Bundles/CrashHandler.bundle/Resources/symbolize.sh <report.txt>` (addr2line;
  the report prints the exact command).

## Enabling

The bundle is installed to `/System/Library/Bundles` (SYSTEM domain) but only loaded where it is listed:

    defaults read NSGlobalDomain GSAppKitUserBundles
    defaults write NSGlobalDomain GSAppKitUserBundles '("/System/Library/Bundles/DriveUI.bundle", "/System/Library/Bundles/OnDemand.bundle", "/System/Library/Bundles/CrashHandler.bundle")'

Apps started afterwards load it. Opt out with the default `GSCrashHandlerDisabled` (YES) globally or per app.
`GSCrashHandlerEnableCoreDumps` (YES) additionally raises the core size limit.

## Adding app context (no linking needed)

Post notifications; without the bundle they are simply not observed.

- `GSCrashHandlerBreadcrumbNotification`, object an NSString: one line for the ring of recent actions.
- `GSCrashHandlerContextNotification`, userInfo `@"key"` and `@"value"` (NSStrings): a "key: value" header line
  that is replaced on each post (16 keys at most).

Collected automatically: every `-sendAction:to:from:` (menu items and controls), key window changes (title, class,
document name) and the end of launching.

## Known limits

- An alternate signal stack exists only for the main thread; a stack overflow on another thread cannot be reported.
- Only GUI apps (the ones that initialize NSApplication) load the bundle; command line tools do not.
- On the BSDs the report has no memory map; the backtrace needs libexecinfo (the report says so where it is missing).

## Testing

`Tests/test-crash-reporter.sh DISPLAY` builds nothing itself: run `gmake` in this directory and in `Tests/`, start a
private Xvfb, and it crashes `CrashTestApp` in five ways with the bundle loaded from the build directory (no install),
and checks that exactly one non-empty report appears each time and that a merely terminated run leaves no file.
The environment variable `GSCrashHandlerTest` (segv, abort, stackoverflow, thread-segv, nsexception) makes any app
crash on purpose half a second after launch; `GSCrashHandlerDir` redirects the reports.
