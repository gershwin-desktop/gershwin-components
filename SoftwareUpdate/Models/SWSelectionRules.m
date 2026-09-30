/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWSelectionRules.h"

@implementation SWSelectionRules

+ (void)applyDefaultSelectionToRepositories:(NSArray<SWRepository *> *)repositories
{
  for (SWRepository *repo in repositories) {
    BOOL blocked = ([self blockedReasonForRepository:repo] != nil) || ![repo isReachable];
    [repo setSelected:!blocked];
  }
}

+ (NSString *)blockedReasonForRepository:(SWRepository *)repository
{
  if (![repository isReachable]) {
    // The checker's own words, not a flat "Couldn't check": it already knows
    // whether the fetch failed, what git said, or whether the user stopped the
    // run, and a row that only says "couldn't check" sends the reader looking
    // for a network problem that may have nothing to do with the network.
    NSString *reason = [repository unreachableReason];
    return [reason length] > 0 ? reason : @"Couldn't check";
  }
  switch ([repository buildStatus]) {
    case SWBuildStatusFailed:
      return @"Build failed on server, please retry later";
    case SWBuildStatusRunning:
      return @"Build still in progress on server, please retry later";
    case SWBuildStatusPassed:
    case SWBuildStatusUnknown:
    default:
      return nil;
  }
}

+ (BOOL)canToggleRepository:(SWRepository *)repository force:(BOOL)force
{
  if ([repository isPinned]) {
    return NO;
  }
  if (force) {
    return YES;
  }
  return [self blockedReasonForRepository:repository] == nil;
}

@end
