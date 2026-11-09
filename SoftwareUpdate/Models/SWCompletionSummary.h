/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SWCompletionSummary - one finished run, reduced to the three things the
 * completion window does with it: the headline, whether a restart is offered,
 * and whether anything went wrong.
 *
 * Split out of SWCompletionWindowController so it can be tested without a
 * display. Creating an NSWindow needs a connection to the window server, which
 * a plain test tool on a build machine does not have, and the wording is
 * exactly the sort of thing that has to be right: a run that failed must not
 * announce itself as complete.
 */

#import <Foundation/Foundation.h>
#import "SWRepositoryUpdater.h"

// One row of the completion window's table: a repository, what became of it,
// and whether installing it needs the session restarted.
@interface SWCompletionResultRow : NSObject
@property (nonatomic, copy) NSString *repositoryName;
@property (nonatomic) SWRepositoryUpdateOutcome outcome;
@property (nonatomic) BOOL restartRequired;
@end

@interface SWCompletionSummary : NSObject

// Any repository that was not updated at all. A repository whose local changes
// could not be re-applied does NOT count: its software was built and installed,
// and only the user's own edits are still in the stash.
@property (nonatomic, readonly) BOOL anyFailed;

// Whether the window should offer Restart (and Later) rather than just Quit.
@property (nonatomic, readonly) BOOL needsRestart;

@property (nonatomic, readonly) NSString *headline;

// rebuild: YES for the "Rebuild" action, which installs nothing new, so it
// says "Rebuild" where an update says "Installation".
+ (instancetype)summaryForResults:(NSArray<SWCompletionResultRow *> *)results
                          rebuild:(BOOL)rebuild;

@end
