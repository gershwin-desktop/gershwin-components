/* t_SWProgressPhase.m - ObjectTesting coverage for the progress list's
 * outcome-to-status mapping.
 *
 * The case that matters came from the test box: a rebuild in which libs-base
 * failed to build still showed that row with a green tick, because nothing
 * ever set the failed status and every later repository's event marked the
 * earlier rows done. A progress list that reports a failure as a success is
 * worse than one that shows nothing, because it is believed.
 *
 * The mapping is a static inline in the header precisely so this needs no
 * window server: SWProgressWindowController is an NSWindowController, and
 * standing one up requires a display this test has no reason to demand.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SWProgressPhase.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* --- the one outcome that is a plain tick --- */
  PASS_EQUAL(SWProgressItemStatusForOutcome(SWRepositoryUpdateOutcomeUpdated),
             SWProgressItemStatusDone,
             "a repository that was updated shows a tick");

  /* --- everything else must be visible as a problem --- */
  PASS_EQUAL(SWProgressItemStatusForOutcome(SWRepositoryUpdateOutcomeBuildFailed),
             SWProgressItemStatusFailed,
             "a failed build shows the warning, not a tick");
  PASS_EQUAL(SWProgressItemStatusForOutcome(SWRepositoryUpdateOutcomeInstallFailed),
             SWProgressItemStatusFailed,
             "a failed install shows the warning, not a tick");
  PASS_EQUAL(SWProgressItemStatusForOutcome(SWRepositoryUpdateOutcomeDiverged),
             SWProgressItemStatusFailed,
             "a repository that could not be fast-forwarded shows the warning");

  // A kept stash is not a failed build, but it is visibly not a clean run
  // either: the software was installed and the user's own edits are still in a
  // stash. A tick would claim otherwise.
  PASS_EQUAL(SWProgressItemStatusForOutcome(SWRepositoryUpdateOutcomeStashKept),
             SWProgressItemStatusFailed,
             "changes left in the stash show the warning, not a tick");

  /* --- no outcome may fall through to Pending or Running --- */
  {
    NSUInteger settled = 0;
    for (NSInteger outcome = SWRepositoryUpdateOutcomeUpdated;
         outcome <= SWRepositoryUpdateOutcomeInstallFailed; outcome++) {
      SWProgressItemStatus status =
        SWProgressItemStatusForOutcome((SWRepositoryUpdateOutcome)outcome);
      PASS(status == SWProgressItemStatusDone || status == SWProgressItemStatusFailed,
           "every outcome settles to a finished status, never pending or running");
      if (status == SWProgressItemStatusDone || status == SWProgressItemStatusFailed) {
        settled++;
      }
    }
    PASS_EQUAL(settled, (NSUInteger)5, "all five outcomes were covered");
  }

  [arp release];
  return 0;
}
