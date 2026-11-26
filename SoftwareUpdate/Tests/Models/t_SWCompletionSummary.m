/* t_SWCompletionSummary.m - ObjectTesting coverage for the completion
 * window's wording, with no window server involved (which is why the decision
 * lives in SWCompletionSummary rather than in the controller).
 *
 * The case that matters is the one from the test box: a rebuild in which
 * libs-base failed to build reported "Rebuild complete." above a table saying
 * "build failed", and offered a Restart button for a run that had not
 * finished. A headline that contradicts its own table is worse than no
 * headline.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SWCompletionSummary.h"

static SWCompletionResultRow *row(SWRepositoryUpdateOutcome outcome, BOOL restartRequired)
{
  SWCompletionResultRow *result = [[SWCompletionResultRow alloc] init];
  [result setRepositoryName:@"repo"];
  [result setOutcome:outcome];
  [result setRestartRequired:restartRequired];
  return result;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* --- an update --- */
  {
    SWCompletionSummary *allGood =
      [SWCompletionSummary summaryForResults:
        @[row(SWRepositoryUpdateOutcomeUpdated, NO),
          row(SWRepositoryUpdateOutcomeUpdated, NO)]
                                     rebuild:NO];
    PASS_EQUAL([allGood headline], @"Installation complete.",
               "an update where every repository succeeded says it completed");
    PASS(![allGood needsRestart], "no restart is offered when nothing needed one");
    PASS(![allGood anyFailed], "and it does not report a failure");
  }

  {
    SWCompletionSummary *needsRestart =
      [SWCompletionSummary summaryForResults:
        @[row(SWRepositoryUpdateOutcomeUpdated, YES)]
                                     rebuild:NO];
    PASS_EQUAL([needsRestart headline],
               @"Installation complete. You must restart your computer to finish updating.",
               "an update that installed a restart-requiring repository says so");
    PASS([needsRestart needsRestart], "and offers the restart");
  }

  {
    SWCompletionSummary *failed =
      [SWCompletionSummary summaryForResults:
        @[row(SWRepositoryUpdateOutcomeUpdated, NO),
          row(SWRepositoryUpdateOutcomeBuildFailed, NO)]
                                     rebuild:NO];
    PASS_EQUAL([failed headline], @"Installation failed.",
               "an update where a repository failed must not say it completed");
    PASS([failed anyFailed], "and it reports the failure");
  }

  {
    SWCompletionSummary *failedButRestartable =
      [SWCompletionSummary summaryForResults:
        @[row(SWRepositoryUpdateOutcomeUpdated, YES),
          row(SWRepositoryUpdateOutcomeBuildFailed, NO)]
                                     rebuild:NO];
    PASS_EQUAL([failedButRestartable headline], @"Installation failed.",
               "a failed update does not fall back to the restart wording");
    PASS(![failedButRestartable needsRestart],
         "a failed run offers no restart: there is nothing to finish");
  }

  /* --- a rebuild --- */
  {
    SWCompletionSummary *rebuilt =
      [SWCompletionSummary summaryForResults:
        @[row(SWRepositoryUpdateOutcomeUpdated, NO)]
                                     rebuild:YES];
    PASS_EQUAL([rebuilt headline], @"Rebuild complete.",
               "a successful rebuild says it completed, not \"installed\"");
  }

  {
    SWCompletionSummary *rebuildFailed =
      [SWCompletionSummary summaryForResults:
        @[row(SWRepositoryUpdateOutcomeUpdated, NO),
          row(SWRepositoryUpdateOutcomeBuildFailed, NO)]
                                     rebuild:YES];
    PASS_EQUAL([rebuildFailed headline], @"Rebuild failed.",
               "a rebuild where a repository failed must not say it completed");
    PASS(![rebuildFailed needsRestart], "a failed rebuild offers no restart either");
  }

  {
    SWCompletionSummary *rebuildFailedInstall =
      [SWCompletionSummary summaryForResults:
        @[row(SWRepositoryUpdateOutcomeInstallFailed, NO)]
                                     rebuild:YES];
    PASS_EQUAL([rebuildFailedInstall headline], @"Rebuild failed.",
               "a failed install is a failed rebuild too");
  }

  {
    SWCompletionSummary *diverged =
      [SWCompletionSummary summaryForResults:
        @[row(SWRepositoryUpdateOutcomeDiverged, NO)]
                                     rebuild:YES];
    PASS_EQUAL([diverged headline], @"Rebuild failed.",
               "a repository that could not be fast-forwarded is a failure");
  }

  /* --- the one outcome that is not a failure --- */
  {
    // StashKept means the software was built and installed and only the user's
    // own edits are still in the stash. Calling that a failed rebuild would be
    // as wrong as the old "complete" was in the other direction.
    SWCompletionSummary *stashKept =
      [SWCompletionSummary summaryForResults:
        @[row(SWRepositoryUpdateOutcomeStashKept, NO)]
                                     rebuild:YES];
    PASS_EQUAL([stashKept headline], @"Rebuild complete.",
               "changes kept in the stash do not make a run a failure");
    PASS(![stashKept anyFailed], "and are not counted as one");
  }

  {
    SWCompletionSummary *stashKeptAfterFailure =
      [SWCompletionSummary summaryForResults:
        @[row(SWRepositoryUpdateOutcomeStashKept, NO),
          row(SWRepositoryUpdateOutcomeBuildFailed, NO)]
                                     rebuild:YES];
    PASS_EQUAL([stashKeptAfterFailure headline], @"Rebuild failed.",
               "but a real failure in the same run still decides the headline");
  }

  [arp release];
  return 0;
}
