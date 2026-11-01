# GNUstep CrashReporter Specification

**Title:** GNUstep CrashReporter
**Status:** Proposed
**Target platforms:** Linux, FreeBSD, OpenBSD, NetBSD
**GUI framework:** GNUstep GUI
**Primary purpose:** System-wide crash detection, collection, analysis, and user notification for GNUstep applications.

## 1. Overview

GNUstep CrashReporter shall provide a Mac-style crash reporting facility for GNUstep applications running on Unix-like systems.

When `CrashReporter` is launched, it shall:

1. Detect the host operating system and available crash-dump facilities.
2. Configure the system, where permitted, to generate core dumps and associated crash information.
3. Start or connect to a persistent crash-monitoring/collection service.
4. Monitor for crashes of GNUstep applications.
5. Collect the resulting core dump and diagnostic metadata.
6. Analyze the crash sufficiently to identify the signal/exception and produce a human-readable backtrace.
7. Present a GUI window to the logged-in user.
8. Tell the user:

   * which application crashed;
   * what kind of crash occurred;
   * when it occurred;
   * whether a core dump was successfully captured;
   * where the crash files were stored;
   * whether symbolication/debug information was available.
9. Preserve the raw crash artifacts for later debugging.

The implementation must support **Linux, FreeBSD, OpenBSD, and NetBSD**, while keeping OS-specific functionality behind a platform abstraction layer.

---

# 2. Architecture

The implementation shall consist of three logical components.

```text
                    ┌──────────────────────┐
                    │ CrashReporter.app     │
                    │ GNUstep GUI           │
                    └──────────┬───────────┘
                               │
                               │ IPC
                               ▼
                    ┌──────────────────────┐
                    │ CrashReporterDaemon   │
                    │ collection/analysis   │
                    └──────────┬───────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
              ▼                ▼                ▼
       OS crash facility   Core files       Metadata
              │                │                │
              └────────────────┼────────────────┘
                               ▼
                    ┌──────────────────────┐
                    │ Crash analysis       │
                    │ GDB/LLDB/DWARF       │
                    └──────────────────────┘
```

Although the user-facing application is called `CrashReporter`, the implementation should not rely on the GUI process remaining alive while another application crashes.

The preferred implementation is therefore:

```text
CrashReporter.app
        │
        │ starts/configures
        ▼
crashd
        │
        ├── watches crash locations
        ├── receives OS notifications
        ├── collects artifacts
        ├── invokes debugger
        └── generates crash report
```

`crashd` should run as a user-level service where possible.

---

# 3. Installation

The CrashReporter installation shall provide:

```text
CrashReporter.app
gs-crashd
gs-crashctl
gs-crash-analyzer
```

Optional platform-specific helpers may be provided:

```text
gs-crashd-linux
gs-crashd-freebsd
gs-crashd-openbsd
gs-crashd-netbsd
```

However, the preferred design is one common daemon with a platform abstraction layer.

---

# 4. CrashReporter startup

When the CrashReporter GUI is launched for the first time, it shall determine whether the crash service is configured.

Conceptually:

```text
CrashReporter.app
       │
       ▼
Is crash service configured?
       │
   ┌───┴───┐
   │       │
  yes      no
   │       │
   │       ▼
   │   Configure system
   │       │
   └───┬───┘
       ▼
Start/verify crashd
       │
       ▼
Show CrashReporter UI
```

The GUI must not assume that it has sufficient privileges to modify system-wide kernel configuration.

Configuration shall therefore have three levels:

### Level 1 — User configuration

No administrator privileges required.

Examples:

* user-owned crash directory;
* user-level core dump configuration;
* user service;
* application-level exception handler.

### Level 2 — Privileged system configuration

Used when necessary and permitted.

Examples:

* `/proc/sys/kernel/core_pattern` on Linux;
* service configuration;
* system-wide crash collection;
* privileged core-dump directory.

The application shall request privilege elevation rather than silently failing.

### Level 3 — Unsupported/restricted

If the OS or security policy prevents configuration, CrashReporter shall continue operating using whatever mechanisms remain available.

The GUI must explicitly tell the user:

> Crash dump collection is partially configured. Core dumps may not be available because the operating system or security policy prevents CrashReporter from configuring them.

---

# 5. Crash storage

CrashReporter shall use a dedicated crash directory.

Default:

```text
$XDG_STATE_HOME/gnustep/CrashReporter/
```

falling back to:

```text
~/.local/state/gnustep/CrashReporter/
```

on systems without `XDG_STATE_HOME`.

A crash shall receive a unique directory:

```text
CrashReporter/
    MyApplication/
        2026-08-27-13-52-41-18423/
            report.json
            report.txt
            core
            maps
            modules
            environment
            registers
            backtrace.txt
            metadata.json
```

The exact directory layout is implementation-defined but shall remain stable across releases.

---

# 6. Crash artifact requirements

For every detected crash, CrashReporter shall attempt to collect:

### Required

* application name;
* executable path;
* PID;
* UID;
* timestamp;
* hostname;
* operating-system name/version;
* CPU architecture;
* GNUstep Base version;
* GNUstep GUI version where applicable;
* crash signal;
* exception information when available;
* core dump path;
* core dump size;
* crash-report directory;
* thread list;
* stack trace of crashing thread.

### Strongly recommended

* complete thread backtraces;
* loaded shared libraries;
* executable memory mappings;
* registers;
* fault address;
* instruction pointer;
* stack pointer;
* signal information;
* GNUstep exception name/reason;
* application version;
* executable build ID;
* shared-library build IDs.

### Optional

* environment;
* command line;
* selected process metadata;
* debugger diagnostic output;
* source-level file/line information;
* application-provided diagnostic information.

Sensitive information shall not be collected unnecessarily.

---

# 7. Core dump configuration

CrashReporter shall contain an OS abstraction:

```objc
@protocol GSCrashPlatform <NSObject>

- (BOOL)configureCoreDumps:(NSError **)error;
- (BOOL)isCoreDumpingEnabled;
- (NSString *)coreDumpLocation;
- (BOOL)installCrashMonitor:(NSError **)error;
- (BOOL)startCrashService:(NSError **)error;

@end
```

The implementation shall have platform-specific subclasses/modules.

For example:

```text
GSCrashPlatformLinux
GSCrashPlatformFreeBSD
GSCrashPlatformOpenBSD
GSCrashPlatformNetBSD
```

The platform implementation shall discover the appropriate native mechanism instead of assuming that every Unix uses traditional `core` files.

---

# 8. Linux

Linux support shall account for:

* `RLIMIT_CORE`;
* `/proc/sys/kernel/core_pattern`;
* systemd-coredump where present;
* systemd service integration where present;
* traditional kernel core files;
* containers/namespaces where detectable.

CrashReporter shall first inspect:

```text
/proc/sys/kernel/core_pattern
```

and determine whether core files are:

```text
direct filesystem files
```

or are being piped to another crash collector.

If systemd-coredump is active, CrashReporter should preferably integrate with it rather than attempting to replace it.

If traditional kernel core files are being used, CrashReporter shall configure an appropriate pattern where permissions allow.

The implementation must **never blindly overwrite an existing administrator-controlled `core_pattern`**.

It shall save the previous configuration and provide a mechanism to restore it.

---

# 9. BSD support

The BSD implementation shall not assume Linux `/proc` semantics.

Each BSD shall have a dedicated capability detector.

At startup:

```text
detect OS
    ↓
detect kernel/core configuration
    ↓
detect existing crash collector
    ↓
select collection mechanism
```

The implementation shall investigate and support, where available:

* `RLIMIT_CORE`;
* `kern.corefile`;
* `sysctl`;
* native crash/core handlers;
* user/core dump directories;
* existing system crash collectors.

The exact implementation shall be isolated behind `GSCrashPlatform`.

If a particular BSD does not permit a requested configuration, CrashReporter shall degrade gracefully rather than refusing to start.

---

# 10. GNUstep application integration

CrashReporter should provide a small optional GNUstep library:

```text
libGSCrashReporter
```

Applications may link against it.

At application startup:

```objc
[GSCrashReporter install];
```

This installs:

* `NSSetUncaughtExceptionHandler`;
* signal handling where appropriate;
* application metadata;
* crash marker generation.

The library shall **not perform heavy analysis from a signal handler**.

Its responsibility is only to make crash information available to the external crash service.

---

# 11. Signal handling

The following signals shall be considered crash candidates where supported:

```text
SIGSEGV
SIGBUS
SIGILL
SIGFPE
SIGABRT
SIGTRAP
```

Additional signals may be supported.

Signal handlers must be minimal.

They shall not:

* create complex Objective-C objects;
* allocate memory unnecessarily;
* acquire arbitrary locks;
* invoke the GUI;
* launch GDB;
* perform symbolication;
* perform network operations.

The preferred sequence is:

```text
signal
  ↓
minimal crash marker
  ↓
normal kernel termination/core generation
  ↓
external crashd
  ↓
analysis
```

---

# 12. Objective-C exception handling

GNUstep applications using the CrashReporter library shall install an uncaught exception handler.

The handler shall capture, where available:

```text
NSException name
NSException reason
NSException userInfo
stack information
application metadata
```

It shall write a small crash marker and allow normal termination to proceed.

Example conceptual marker:

```text
application = MyApp
pid = 12345
exception = NSInvalidArgumentException
reason = "..."
timestamp = ...
```

The actual core dump shall remain the authoritative source for native process state.

---

# 13. Crash detection

`crashd` shall support multiple detection methods.

### Method A — Crash directory monitoring

Monitor the configured crash directory for new core files.

### Method B — OS-specific notification

Use the native operating-system crash facility when available.

### Method C — Application marker

Read markers created by `libGSCrashReporter`.

### Method D — Process/service integration

Where appropriate, integrate with:

* systemd;
* BSD service mechanisms;
* user session managers.

Multiple methods may be active simultaneously.

CrashReporter shall deduplicate events.

---

# 14. Correlating a core with an application

A crash event shall be correlated using as many of the following as possible:

```text
PID
timestamp
executable
UID
build ID
core filename
application marker
```

A crash must not be attributed to the wrong application merely because two processes have similar names.

---

# 15. Crash analysis

Once a crash has been collected:

```text
core
 executable
 libraries
 debug symbols
       │
       ▼
 crash analyzer
```

The analyzer shall determine:

1. terminating signal;
2. fault address;
3. instruction pointer;
4. crashing thread;
5. stack trace;
6. all thread states;
7. loaded modules;
8. symbol names;
9. source locations where debug information exists.

GDB and/or LLDB may be used as external analysis engines.

The analyzer must have a timeout so that a corrupt or pathological core cannot cause `crashd` to hang indefinitely.

---

# 16. Symbolication

If debug information is available:

```text
0x00007f1234567890
```

should become:

```text
-[DocumentController saveDocument:]
DocumentController.m:421
```

The analyzer shall use exact executable/library identity when resolving symbols.

Build IDs shall be recorded whenever available.

If symbols cannot be resolved, the report shall explicitly say:

> Debug symbols were not available; this stack trace contains addresses only.

---

# 17. Crash classification

CrashReporter shall classify crashes into human-readable categories.

Examples:

```text
Segmentation fault
Invalid memory access
Bus error
Illegal instruction
Floating-point exception
Aborted process
Uncaught Objective-C exception
Assertion failure
Unknown crash
```

Where confidence is high, it may provide a more specific diagnosis:

```text
Likely NULL-pointer dereference
```

However, the UI must distinguish **observed facts** from **heuristic diagnosis**.

For example:

```text
Crash:
    SIGSEGV

Fault address:
    0x18

Likely cause:
    NULL-pointer dereference

Confidence:
    Probable
```

It must not claim certainty where the evidence does not support it.

---

# 18. Crash report format

The canonical machine-readable format shall be JSON.

Example:

```json
{
    "format": 1,
    "application": {
        "name": "MyApplication",
        "version": "1.4.2",
        "pid": 18423,
        "executable": "/usr/local/bin/MyApplication"
    },
    "system": {
        "os": "Linux",
        "architecture": "x86_64"
    },
    "crash": {
        "signal": "SIGSEGV",
        "fault_address": "0x18",
        "thread": 3
    },
    "analysis": {
        "classification": "Invalid memory access",
        "diagnosis": "Probable NULL-pointer dereference"
    },
    "files": {
        "core": "core",
        "backtrace": "backtrace.txt"
    }
}
```

A human-readable `report.txt` shall also be generated.

---

# 19. GUI behavior

When a new crash is detected for the current logged-in user, CrashReporter shall display a window.

The window should resemble the traditional Mac crash-reporting model without attempting to reproduce Apple's proprietary UI exactly.

Example:

```text
┌────────────────────────────────────────────────────────┐
│                                                        │
│  MyApplication quit unexpectedly.                      │
│                                                        │
│  The application terminated because of a segmentation │
│  fault (SIGSEGV).                                     │
│                                                        │
│  Crash time: 27 August 2026, 13:52:41                 │
│                                                        │
│  Probable cause: NULL-pointer dereference              │
│                                                        │
│  A crash dump and diagnostic information were saved.   │
│                                                        │
│  Location:                                             │
│  ~/.local/state/gnustep/CrashReporter/                │
│      MyApplication/2026-08-27-13-52-41-18423/         │
│                                                        │
│       [ Show Details ]       [ Open Folder ]           │
│                                                        │
│                         [ Close ]                      │
└────────────────────────────────────────────────────────┘
```

---

# 20. Details window

"Show Details" shall display at least:

```text
Application
System
Crash
Exception
Crashing Thread
Backtrace
Other Threads
Loaded Libraries
Crash Files
```

Example:

```text
Crash

Signal:       SIGSEGV
Fault:        0x18
Thread:       3

Probable cause:
NULL-pointer dereference

Backtrace:

0   MyApplication
    -[DocumentController saveDocument:]
    DocumentController.m:421

1   MyApplication
    -[DocumentWindow save:]
    DocumentWindow.m:187

2   GNUstep
    ...
```

---

# 21. Crash-file location

The primary crash window **must explicitly tell the user where the files were saved**.

It shall display the path in a selectable/copyable field.

Buttons:

```text
[ Open Folder ]
[ Copy Path ]
```

`Open Folder` shall use the desktop environment's standard mechanism where available.

If no graphical file manager is available, the button may be disabled.

---

# 22. Missing core dump

If the application crashed but no core dump was produced, CrashReporter shall still show a report.

Example:

```text
MyApplication quit unexpectedly.

Cause:
    SIGSEGV — segmentation fault

Crash analysis:
    A crash was detected, but the operating system did not
    provide a core dump.

Diagnostic information was saved to:

    ~/.local/state/gnustep/CrashReporter/MyApplication/...
```

The UI should explain why the core is unavailable when that can be determined:

```text
Core dump unavailable because:
    the current system core-size limit is zero.
```

or:

```text
Core dump unavailable because:
    the system crash collector owns core-file processing.
```

---

# 23. Security and privacy

CrashReporter must treat crash dumps as **sensitive data**.

Core files can contain:

* passwords;
* authentication tokens;
* private documents;
* encryption keys;
* arbitrary application memory.

Therefore:

* crash directories shall be user-readable by default;
* permissions shall be restrictive;
* crash files shall not be world-readable;
* CrashReporter shall not upload anything automatically by default;
* the UI shall warn users before sharing a core dump;
* environment variables shall not be collected unless explicitly enabled.

Default directory permissions should be equivalent to:

```text
0700
```

and files:

```text
0600
```

where supported.

---

# 24. Existing crash infrastructure

CrashReporter must coexist with existing system facilities.

It shall detect:

```text
systemd-coredump
ABRT
core_pattern handlers
BSD crash facilities
```

and other known mechanisms.

It must not overwrite an existing crash handler without explicit user/administrator consent.

The configuration UI should say:

```text
Core dump handling

○ Use existing system crash handler
○ Use GNUstep CrashReporter
○ Disable CrashReporter core collection
```

The first option should be preferred when the existing handler can provide the necessary data.

---

# 25. Configuration utility

`gs-crashctl` shall provide command-line management.

Examples:

```text
gs-crashctl status
gs-crashctl enable
gs-crashctl disable
gs-crashctl test
gs-crashctl list
gs-crashctl show <crash-id>
gs-crashctl analyze <crash-directory>
gs-crashctl open <crash-id>
```

`status` should report something similar to:

```text
GNUstep CrashReporter

Service:             running
Core dumps:          enabled
Core location:       /home/user/.local/state/...
Platform:             Linux
Crash collector:      GNUstep
Symbolication:        available
Debug symbols:        partial
```

---

# 26. Test facility

The project shall provide a deliberate test crash mechanism.

For example:

```text
gs-crashctl test
```

This should launch a small test program that intentionally crashes.

The test must verify:

```text
application crash
       ↓
core generation
       ↓
crash detection
       ↓
artifact collection
       ↓
analysis
       ↓
GUI notification
```

The test program shall clearly identify itself as a test and must never be confused with a real application crash.

---

# 27. Service lifecycle

The service shall start automatically when the user's graphical session starts.

Preferred mechanisms:

### Linux

Use a user-level systemd service where systemd is available.

Otherwise use the appropriate desktop/session mechanism.

### BSD

Use the appropriate user-session mechanism where available.

CrashReporter must not require the user to manually start a daemon after every login.

---

# 28. Failure behavior

If `crashd` itself crashes, it must not prevent applications from running.

If the GUI crashes:

```text
core collection continues
```

If the analyzer crashes:

```text
raw crash data remains available
```

If symbolication fails:

```text
raw addresses remain available
```

If core generation fails:

```text
exception/signal metadata is still retained
```

The fundamental principle is:

> Failure of CrashReporter must never make the crashed application's diagnostic information less recoverable than it would otherwise have been.

---

# 29. Recommended process separation

The final implementation should preferably look like:

```text
             User Session
                  │
        ┌─────────┴──────────┐
        │                    │
        ▼                    ▼
 CrashReporter.app         gs-crashd
        │                    │
        │                    ├── OS integration
        │                    ├── crash detection
        │                    ├── artifact collection
        │                    └── analyzer
        │
        └────── IPC ─────────┘
```

`gs-crashd` should not run as root merely because core-dump configuration sometimes requires elevated privileges.

Privileged operations should be isolated into a small setup operation/helper.

---

# 30. Implementation phases

### Phase 1 — Core functionality

* Linux;
* FreeBSD;
* user crash directory;
* core-dump detection;
* GNUstep exception handler;
* signal metadata;
* `gs-crashd`;
* GDB backtrace;
* JSON/text reports;
* basic GUI.

### Phase 2 — Platform integration

* OpenBSD;
* NetBSD;
* systemd-coredump integration;
* BSD-specific core mechanisms;
* service management;
* privilege-aware configuration.

### Phase 3 — Advanced analysis

* DWARF symbolication;
* build IDs;
* complete thread analysis;
* register dumps;
* loaded-module analysis;
* crash classification.

### Phase 4 — Polish

* Finder-like crash directory browsing;
* preferences;
* retention policies;
* automatic cleanup;
* duplicate-crash detection;
* developer-oriented diagnostics;
* optional report submission.

---

# 31. Important design decision

The most important architectural requirement is that **CrashReporter must configure crash collection before a crash occurs, but must perform analysis after the crashed process has completely terminated.**

In particular:

```text
                    BEFORE CRASH

CrashReporter
     │
     ├── configure core dumps
     ├── configure crash directory
     ├── start gs-crashd
     └── install application exception integration


                    CRASH

MyApplication
     │
     ├── SIGSEGV / exception
     ├── kernel generates core
     └── process terminates


                    AFTER CRASH

gs-crashd
     │
     ├── detects crash
     ├── finds core
     ├── collects metadata
     ├── invokes debugger
     ├── symbolicates
     ├── writes report
     └── notifies CrashReporter.app
                              │
                              ▼
                       User sees window
```

This gives you a **real system crash reporter rather than merely an uncaught-exception dialog**. It also makes the design portable: the GNUstep-specific pieces remain common, while Linux/BSD differences are concentrated in the crash-collection backend.
