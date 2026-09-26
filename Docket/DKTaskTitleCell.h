/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class DKTask;

/*
 * Draws one task's title cell: the embossed title (struck through when
 * done), a small due-date tag on the right, and a dot marking that the
 * task carries a notes paragraph. -setObjectValue: takes the DKTask
 * itself, not a string - the cell reads everything else it needs
 * straight off the task.
 */
@interface DKTaskTitleCell : NSCell
@end
