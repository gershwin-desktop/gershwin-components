/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Data model for the progress window's phases box (spec screens 4/5):
 * three run phases, each with pending/running/done status, and - for
 * whichever phase is running - a list of indented sub-items with their own
 * status (missing packages, or repositories being updated).
 */

#import <Foundation/Foundation.h>
#import "SWRepositoryUpdater.h"

typedef NS_ENUM(NSInteger, SWProgressItemStatus) {
  SWProgressItemStatusPending = 0,
  SWProgressItemStatusRunning,
  SWProgressItemStatusDone,
  SWProgressItemStatusFailed,
  SWProgressItemStatusSkipped,
};

// How a finished repository reads in the progress list.
//
// Only Updated is a plain tick. Everything else gets the warning mark,
// including a kept stash: the software really was built and installed there,
// but something is visibly not as it should be - the user's own edits are
// still in a stash - and a green tick next to it claims otherwise.
//
// This lives here, rather than in the window controller, so it can be checked
// without a display: SWProgressWindowController is an NSWindowController, and
// creating one needs a window server this has no business requiring.
static inline SWProgressItemStatus SWProgressItemStatusForOutcome(SWRepositoryUpdateOutcome outcome)
{
  return outcome == SWRepositoryUpdateOutcomeUpdated
    ? SWProgressItemStatusDone
    : SWProgressItemStatusFailed;
}

@interface SWProgressItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic) SWProgressItemStatus status;
@property (nonatomic, copy) NSString *trailingText; // e.g. the current step, shown at the right
@end

@interface SWProgressPhase : NSObject
@property (nonatomic, copy) NSString *identifier; // "developer" / "prereqs" / "repos"
@property (nonatomic, copy) NSString *title;       // "Update gershwin-developer" etc.
@property (nonatomic) SWProgressItemStatus status;
@property (nonatomic, strong) NSMutableArray<SWProgressItem *> *items;
@end
