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
    return @"Couldn't check";
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

@end
