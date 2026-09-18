/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* The applications that own top-level windows, as announced by the window
 * manager.  Both the power actions and the Force Quit panel need the same
 * view of "what is running", so it is read in one place. */
@interface RunningApplicationList : NSObject

/* One dictionary per process, with "name" (the WM_CLASS class, which for a
 * GNUstep application is also its Distributed Objects service name) and
 * "pid" (NSNumber).  Menu itself is never included. */
+ (NSArray *)applicationsOwningWindows;

@end
