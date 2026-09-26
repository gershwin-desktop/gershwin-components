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

typedef NS_ENUM(NSInteger, SWProgressItemStatus) {
  SWProgressItemStatusPending = 0,
  SWProgressItemStatusRunning,
  SWProgressItemStatusDone,
  SWProgressItemStatusFailed,
  SWProgressItemStatusSkipped,
};

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
