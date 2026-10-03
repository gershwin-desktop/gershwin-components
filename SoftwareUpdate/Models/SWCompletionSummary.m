/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWCompletionSummary.h"

@implementation SWCompletionResultRow
@end

@interface SWCompletionSummary ()
{
  NSArray<SWCompletionResultRow *> *_results;
  NSString *_headline;
  BOOL _needsRestart;
  BOOL _anyFailed;
}
@end

@implementation SWCompletionSummary

@synthesize headline = _headline;
@synthesize needsRestart = _needsRestart;
@synthesize anyFailed = _anyFailed;

+ (instancetype)summaryForResults:(NSArray<SWCompletionResultRow *> *)results
                          rebuild:(BOOL)rebuild
{
  SWCompletionSummary *summary = [[self alloc] init];
  if (!summary) return nil;

  BOOL needsRestart = NO;
  BOOL anyFailed = NO;
  for (SWCompletionResultRow *row in results) {
    if ([row restartRequired] && [row outcome] == SWRepositoryUpdateOutcomeUpdated) {
      needsRestart = YES;
    }
    // StashKept is deliberately not a failure. The software was built and
    // installed; only the user's own local edits could not be put back, which
    // the row says and the stash alert has already explained. The other four
    // outcomes mean the repository was not updated at all.
    switch ([row outcome]) {
      case SWRepositoryUpdateOutcomeBuildFailed:
      case SWRepositoryUpdateOutcomeInstallFailed:
      case SWRepositoryUpdateOutcomeDiverged:
      case SWRepositoryUpdateOutcomeBlocked:
        anyFailed = YES;
        break;
      default:
        break;
    }
  }

  NSString *complete = rebuild ? @"Rebuild complete." : @"Installation complete.";
  NSString *failed = rebuild ? @"Rebuild failed." : @"Installation failed.";
  NSString *restartClause = rebuild
    ? @" You must restart your computer to finish installing."
    : @" You must restart your computer to finish updating.";

  if (anyFailed) {
    // "Rebuild complete." above a table with "build failed" against libs-base
    // is the kind of confident summary that sends someone off believing the
    // desktop is current when half of it is not. A failed run also drops the
    // Restart button: a restart "finishes updating" a run that did not
    // finish, and the repositories that did succeed are not half-applied
    // pending a reboot.
    summary->_headline = failed;
    summary->_needsRestart = NO;
  } else if (needsRestart) {
    summary->_headline = [complete stringByAppendingString:restartClause];
    summary->_needsRestart = YES;
  } else {
    summary->_headline = complete;
    summary->_needsRestart = NO;
  }
  summary->_anyFailed = anyFailed;
  summary->_results = [results copy];

  return summary;
}

@end
