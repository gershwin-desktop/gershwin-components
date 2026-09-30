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

  // A clone does not inherit the origin repository's local user.name/
  // user.email, so without this the "work" clone has no committer identity and
  // every commit it is asked to make fails with "Author identity unknown" -
  // which then leaves it one commit deep and fails the HEAD~1 cases further
  // down, on a machine that simply has no global git identity configured.
  runShell([NSString stringWithFormat:
    @"cd %@ && git config user.email t@example.invalid && git config user.name Test", work]);

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
    NSString *fetchError = nil;
    PASS([git fetchPruneOrigin:&fetchError] && fetchError == nil,
         "fetch --prune origin succeeds against a real remote");
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
    [git fetchPruneOrigin:NULL];

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

    // The case that made a check report "no updates" on a repository that was
    // plainly behind: the worktree and .git are ours, so the old two-path test
    // said no elevation was needed, but one .git/objects/<xx> directory was
    // left behind by a git that ran as root. git then aborts the fetch with
    // "insufficient permission for adding an object to repository database",
    // origin/<branch> never moves, and every HEAD..origin/<branch> is empty.
    // A single unwritable two-hex-digit object directory has to be enough to
    // send this through sudo - so the whole object database is inspected, not
    // just the two paths at the top.
    NSString *objLocked = [gBaseDir stringByAppendingPathComponent:@"objects-locked"];
    NSString *objDir = [objLocked stringByAppendingPathComponent:@".git/objects"];
    NSString *oneXX = [objDir stringByAppendingPathComponent:@"1f"];
    NSString *packedRefs = [objLocked stringByAppendingPathComponent:@".git/packed-refs"];
    runShell([NSString stringWithFormat:@"mkdir -p %@/pack %@/refs", objDir,
      [objLocked stringByAppendingPathComponent:@".git"]]);
    runShell([NSString stringWithFormat:@"mkdir -p %@", oneXX]);
    if (geteuid() == 0) {
      PASS(![SWGitTool needsElevationForPath:objLocked],
           "root needs no elevation for a repository with a full object database");
    } else {
      PASS(![SWGitTool needsElevationForPath:objLocked],
           "a complete object database this user owns needs no elevation");

      // packed-refs is an ordinary 0644 regular file, not a directory. Asking
      // for search permission as well as write permission would read this -
      // present in almost every clone - as unusable, escalate every git call
      // to root, and leave a root-owned object database behind for the next
      // run to trip over, which is the very condition being routed around.
      runShell([NSString stringWithFormat:@"printf '# pack-refs with: peeled\\n' > %@", packedRefs]);
      runShell([NSString stringWithFormat:@"chmod 0644 %@", packedRefs]);
      PASS(![SWGitTool needsElevationForPath:objLocked],
           "a plain 0644 packed-refs file needs no elevation");
      runShell([NSString stringWithFormat:@"chmod 0444 %@", packedRefs]);
      PASS([SWGitTool needsElevationForPath:objLocked],
           "a read-only packed-refs does need elevation, since git rewrites it");
      runShell([NSString stringWithFormat:@"chmod 0644 %@", packedRefs]);

      runShell([NSString stringWithFormat:@"chmod 0555 %@", oneXX]);
      PASS([SWGitTool needsElevationForPath:objLocked],
           "one unwritable .git/objects/<xx> directory forces the fetch through sudo");
      runShell([NSString stringWithFormat:@"chmod 0755 %@", oneXX]);

      runShell([NSString stringWithFormat:@"chmod 0555 %@/pack", objDir]);
      PASS([SWGitTool needsElevationForPath:objLocked],
           "an unwritable .git/objects/pack forces the fetch through sudo");
      runShell([NSString stringWithFormat:@"chmod 0755 %@/pack", objDir]);

      // Locking all 256 is what makes the difference measurable. git picks an
      // object's directory from its own sha, so with only some of them locked
      // a fetch can still land every object in an unlocked one - and a check
      // that would have caught the box's condition looks like it has nothing
      // to do. On the box, 50 of 135 directories were left behind this way.
      runShell([NSString stringWithFormat:
        @"for i in $(seq 0 255); do d=$(printf '%%02x' $i); mkdir -p %@/$d; chmod 0555 %@/$d; done",
        objDir, objDir]);
      PASS([SWGitTool needsElevationForPath:objLocked],
           "an object database root wrote into is sent through sudo, not just one bad directory");
      runShell([NSString stringWithFormat:
        @"for i in $(seq 0 255); do d=$(printf '%%02x' $i); chmod 0755 %@/$d; done", objDir]);
    }

    // A .git with no objects directory at all is left to git to report, the
    // same as a path that does not exist: there is nothing here yet to write,
    // and treating "cannot open it" as a permission problem would make every
    // path that is not a repository ask for a password.
    NSString *noObjects = [gBaseDir stringByAppendingPathComponent:@"no-objects"];
    runShell([NSString stringWithFormat:@"mkdir -p %@/.git", noObjects]);
    PASS(![SWGitTool needsElevationForPath:noObjects],
         "a .git with no object database is not treated as a permission problem");
    PASS(![SWGitTool needsElevationForPath:
             [gBaseDir stringByAppendingPathComponent:@"no-such-repository"]],
         "a path that does not exist at all needs no elevation");
  }

  runShell([NSString stringWithFormat:@"rm -rf %@", gBaseDir]);
  [arp release];
  return 0;
}
