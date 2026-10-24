/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#include <sys/types.h>

// Canonical path of the program a process runs, or nil when it cannot be read
// (process gone, other user, no procfs).
NSString *MenuExecutablePathForProcess(pid_t pid);

// The process a newly started Menu may terminate, or 0.
// ownerPID is the _NET_WM_PID of the previous owner of this display's
// _MENU_S<n> selection (0 when there was none), so a Menu serving
// another display is never a candidate even when it runs the same program as
// the same user.
pid_t MenuPreviousInstanceToTerminate(pid_t ownerPID,
                                      pid_t ownPID,
                                      NSString *ownExecutable,
                                      NSString *(^executableForPID)(pid_t pid));

// SIGTERM, then SIGKILL if the process is still there after two seconds.
void MenuTerminateProcess(pid_t pid);

// Terminates the Menu that already serves the display named by $DISPLAY and
// registers this process as the Menu of that display. Returns NO (after
// logging) when the display cannot be opened. The connection used for the
// registration stays open for the life of the process: the selection is
// released when it closes.
BOOL MenuTakeOverDisplay(void);
