/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SWStashAlertController - spec screen 6: shown after the last repository
 * finishes, before the completion window, when one or more stashes could
 * not be re-applied. A plain alert - icon, bold message, informative text,
 * buttons - no boxes or lists.
 */

#import <AppKit/AppKit.h>

// One repository whose local changes stayed in the stash.
@interface SWStashConflict : NSObject
@property (nonatomic, copy) NSString *repositoryName;
@property (nonatomic, copy) NSString *repositoryPath;
@property (nonatomic, copy) NSArray<NSString *> *conflictedFiles;
@end

@interface SWStashAlertController : NSObject

// Shows the alert modally if conflicts is non-empty (returns immediately,
// doing nothing, if it is empty - callers do not need to check first).
// "Show in Workspace" acts on the first repository named in the message and
// can be clicked repeatedly; "Continue" ends the modal session.
+ (void)presentIfNeededForConflicts:(NSArray<SWStashConflict *> *)conflicts;

@end
