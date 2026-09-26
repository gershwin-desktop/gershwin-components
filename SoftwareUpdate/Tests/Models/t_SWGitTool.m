/* t_SWGitTool.m - ObjectTesting coverage for SWGitTool, against real
 * scratch git repositories (no mocks: git's own behavior is the contract).
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SWGitTool.h"
#include <stdlib.h>
#include <unistd.h>

static NSString *gBaseDir;

static void runShell(NSString *cmd)
{
  system([cmd UTF8String]);
}

// Sets up: <base>/origin (a repo with commits on main and a dev branch) and
// <base>/work (a clone of it, so it has an "origin" remote for real).
static void setUpFixture(NSString *base)
{
  runShell([NSString stringWithFormat:@"rm -rf %@ && mkdir -p %@", base, base]);
  NSString *origin = [base stringByAppendingPathComponent:@"origin"];
  NSString *work = [base stringByAppendingPathComponent:@"work"];

  runShell([NSString stringWithFormat:
    @"git init -q -b main %@ && cd %@ && "
     "git config user.email t@example.invalid && git config user.name Test && "
     "echo one > file.txt && git add file.txt && git commit -q -m 'first commit' && "
     "git branch dev", origin, origin]);

  runShell([NSString stringWithFormat:@"git clone -q %@ %@", origin, work]);

  // Advance origin's main by two commits after the clone was taken, so
  // "work" is behind by exactly two.
  runShell([NSString stringWithFormat:
    @"cd %@ && echo two >> file.txt && git commit -q -am 'second commit' && "
     "echo three >> file.txt && git commit -q -am 'third commit'", origin]);
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  gBaseDir = [NSString stringWithFormat:@"/tmp/sw-git-test-%d", getpid()];
  NSString *work = [gBaseDir stringByAppendingPathComponent:@"work"];

  setUpFixture(gBaseDir);
  SWGitTool *git = [[SWGitTool alloc] initWithRepositoryPath:work];

  /* --- current branch --- */
  {
    PASS_EQUAL([git currentBranch], @"main", "a freshly cloned repo reports its branch");
  }

  /* --- fetch and count/list commits behind origin --- */
  {
    PASS([git fetchPruneOrigin], "fetch --prune origin succeeds against a real remote");
    PASS([git commitCountBehindTarget:@"main"] == 2,
         "work is behind origin/main by exactly the two commits made after cloning");

    NSArray *commits = [git commitsBehindTarget:@"main"];
    PASS([commits count] == 2, "commitsBehindTarget returns both commits");
    PASS_EQUAL([[commits objectAtIndex:0] subject], @"third commit",
               "commits are newest first");
    PASS_EQUAL([[commits objectAtIndex:1] subject], @"second commit",
               "second commit is listed after the newest");
  }

  /* --- remote branch existence --- */
  {
    PASS([git remoteHasBranch:@"dev"], "origin's dev branch is detected");
    PASS(![git remoteHasBranch:@"no-such-branch"], "a nonexistent branch is not detected");
  }

  /* --- dirty tree / stash / pop round-trip, no conflict --- */
  {
    PASS([git modifiedFileCount] == 0, "a freshly cloned repo starts clean");

    runShell([NSString stringWithFormat:@"echo local-change >> %@/file.txt", work]);
    PASS([git modifiedFileCount] == 1, "an uncommitted edit to a tracked file is counted");

    PASS([git stashPushWithMessage:@"Software Update test"], "stash push succeeds on a dirty tree");
    PASS([git modifiedFileCount] == 0, "the tree is clean immediately after stashing");

    PASS([git stashPop], "stash pop succeeds when nothing else touched the file");
    PASS([git modifiedFileCount] == 1, "the local edit is back after popping the stash");
  }

  /* --- fast-forward switch to a branch that has no local counterpart yet --- */
  {
    // Discard the leftover local edit from the stash test so switching is clean.
    runShell([NSString stringWithFormat:@"cd %@ && git checkout -q -- file.txt", work]);
    PASS([git switchAndFastForwardTo:@"dev"], "switching to a newly-tracked remote branch succeeds");
    PASS_EQUAL([git currentBranch], @"dev", "the repo is now on the dev branch");
  }

  /* --- fast-forward-only merge that cannot fast-forward (diverged) --- */
  {
    runShell([NSString stringWithFormat:@"cd %@ && git switch -q main", work]);
    // Give "work" a local commit that origin/main does not have, so ff-only
    // must fail once origin/main has also moved.
    runShell([NSString stringWithFormat:
      @"cd %@ && echo local-only >> file.txt && git commit -q -am 'local divergent commit'", work]);
    runShell([NSString stringWithFormat:
      @"cd %@/origin && echo four >> file.txt && git commit -q -am 'fourth commit'", gBaseDir]);
    [git fetchPruneOrigin];

    PASS(![git switchAndFastForwardTo:@"main"],
         "a fast-forward-only merge fails once local and remote have diverged");
  }

  /* --- checkoutRef: rolling back to a known commit --- */
  {
    NSString *output = nil;
    NSTask *revParse = [[NSTask alloc] init];
    [revParse setLaunchPath:@"/usr/bin/env"];
    [revParse setArguments:@[@"git", @"-C", work, @"rev-parse", @"HEAD~1"]];
    NSPipe *pipe = [NSPipe pipe];
    [revParse setStandardOutput:pipe];
    [revParse launch];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [revParse waitUntilExit];
    output = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    PASS([git checkoutRef:output], "checking out a known prior commit succeeds");
  }

  /* --- discardTrackedChanges: undoes an uncommitted edit to a tracked file --- */
  {
    runShell([NSString stringWithFormat:@"echo uncommitted >> %@/file.txt", work]);
    PASS([git modifiedFileCount] == 1, "the edit is dirty before discarding");
    PASS([git discardTrackedChanges], "discardTrackedChanges succeeds");
    PASS([git modifiedFileCount] == 0, "the tree is clean after discarding");
  }

  /* --- elevation: only repositories this user may not use go through sudo --- */
  {
    PASS(![SWGitTool needsElevationForPath:work],
         "a repository this user owns and can write needs no elevation");

    PASS(![SWGitTool needsElevationForPath:
             [gBaseDir stringByAppendingPathComponent:@"no-such-repository"]],
         "a path git cannot find at all is left to git to report");

    PASS([SWGitTool prepareElevationForPaths:@[work]
                                  logHandler:NULL
                                      reason:NULL],
         "no permission is asked for when every repository is already ours");

    // Ownership cannot be forged without root, but a repository git may not
    // write is the other half of the same decision, and is testable here.
    NSString *locked = [gBaseDir stringByAppendingPathComponent:@"locked"];
    runShell([NSString stringWithFormat:@"mkdir -p %@/.git", locked]);
    if (geteuid() == 0) {
      PASS(![SWGitTool needsElevationForPath:locked],
           "root needs no elevation for any repository");
    } else {
      runShell([NSString stringWithFormat:@"chmod 0555 %@/.git", locked]);
      PASS([SWGitTool needsElevationForPath:locked],
           "a repository git may not write is run with sudo");
      runShell([NSString stringWithFormat:@"chmod 0755 %@/.git", locked]);
    }
  }

  runShell([NSString stringWithFormat:@"rm -rf %@", gBaseDir]);
  [arp release];
  return 0;
}
