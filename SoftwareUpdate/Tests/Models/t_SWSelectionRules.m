/* t_SWSelectionRules.m - ObjectTesting coverage for SWSelectionRules.
 * Headless, no I/O.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SWRepository.h"
#import "SWSelectionRules.h"

static SWRepository *makeRepo(SWBuildStatus status, BOOL reachable)
{
  SWRepository *repo = [[SWRepository alloc] initWithPlistEntry:@{@"Name": @"x", @"URL": @"u"}];
  [repo setBuildStatus:status];
  if (!reachable) [repo setUnreachableReason:@"Couldn't check"];
  return repo;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* --- individual blocked-reason rules --- */
  {
    PASS([SWSelectionRules blockedReasonForRepository:makeRepo(SWBuildStatusPassed, YES)] == nil,
         "a passed build is not blocked");
    PASS([SWSelectionRules blockedReasonForRepository:makeRepo(SWBuildStatusUnknown, YES)] == nil,
         "an unknown build status is treated like passed - not blocked");
    PASS_EQUAL([SWSelectionRules blockedReasonForRepository:makeRepo(SWBuildStatusFailed, YES)],
               @"Build failed on server, please retry later",
               "a failed build reports the exact spec wording");
    PASS_EQUAL([SWSelectionRules blockedReasonForRepository:makeRepo(SWBuildStatusRunning, YES)],
               @"Build still in progress on server, please retry later",
               "a running build reports the exact spec wording");
    PASS([SWSelectionRules blockedReasonForRepository:makeRepo(SWBuildStatusPassed, NO)] != nil,
         "an unreachable repository is blocked even with a passed build");
  }

  /* --- applying default selection across a list --- */
  {
    SWRepository *passed = makeRepo(SWBuildStatusPassed, YES);
    SWRepository *failed = makeRepo(SWBuildStatusFailed, YES);
    SWRepository *running = makeRepo(SWBuildStatusRunning, YES);
    SWRepository *unreachable = makeRepo(SWBuildStatusPassed, NO);
    NSArray *repos = @[passed, failed, running, unreachable];

    [SWSelectionRules applyDefaultSelectionToRepositories:repos];

    PASS([passed selected], "a passed-build repository is selected by default");
    PASS(![failed selected], "a failed-build repository is not selected by default");
    PASS(![running selected], "a running-build repository is not selected by default");
    PASS(![unreachable selected], "an unreachable repository is not selected by default");
  }

  [arp release];
  return 0;
}
