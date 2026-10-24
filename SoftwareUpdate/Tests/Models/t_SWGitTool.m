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

// Sets up: <base>/origin2 and <base>/work2 (one commit behind it), where the
// two incoming commits add two files that already exist in the clone's working
// tree as untracked files - one with different content, one with exactly the
// content the update brings - plus a third untracked file the update does not
// touch at all. That is the condition found on the test box, where six files
// under DiskUtility/Tests/ had reached the checkout by some route other than
// git and were then reported as "diverged" on every single run.
static void setUpUntrackedFixture(NSString *base, NSString *work)
{
  NSString *origin = [base stringByAppendingPathComponent:@"origin2"];
  runShell([NSString stringWithFormat:@"rm -rf %@ && mkdir -p %@", origin, origin]);
  runShell([NSString stringWithFormat:
    @"git init -q -b main %@ && cd %@ && "
     "git config user.email t@example.invalid && git config user.name Test && "
     "echo one > file.txt && git add file.txt && git commit -q -m 'first commit'",
    origin, origin]);
  runShell([NSString stringWithFormat:@"git clone -q %@ %@", origin, work]);
  runShell([NSString stringWithFormat:
    @"cd %@ && git config user.email t@example.invalid && git config user.name Test", work]);

  // The two commits origin is about to make, each adding one file.
  runShell([NSString stringWithFormat:
    @"cd %@ && mkdir -p added && echo 'from upstream' > added/different.txt && "
     "echo 'from upstream' > added/same.txt && git add added && "
     "git commit -q -m 'adds two files'", origin]);

  // ...both of which are already sitting in the clone, untracked. git counts
  // this working tree as clean (-modifiedFileCount is 0, because
  // --untracked-files=no) and then refuses to fast-forward over them.
  runShell([NSString stringWithFormat:
    @"cd %@ && mkdir -p added mine && "
     "echo 'my own work' > added/different.txt && "
     "echo 'from upstream' > added/same.txt && "
     "echo 'unrelated' > mine/notes.txt", work]);
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

  /* --- untracked files that a fast-forward would have to overwrite --- */
  //
  // Reproduces the reported failure. The repository is not behind by a
  // divergence, it simply has files in the working tree that the incoming
  // commits add, so `git merge --ff-only` aborts with "the following untracked
  // working tree files would be overwritten by merge" - and a caller that maps
  // a refused fast-forward onto "diverged" reports that on every run, for ever,
  // for a repository that git itself says can be fast-forwarded.
  {
    NSString *work2 = [gBaseDir stringByAppendingPathComponent:@"work2"];
    setUpUntrackedFixture(gBaseDir, work2);
    SWGitTool *git2 = [[SWGitTool alloc] initWithRepositoryPath:work2];
    [git2 fetchPruneOrigin:NULL];

    // The tree looks clean to the check that decides whether to stash, which is
    // exactly why nothing was done about it and why -modifiedFileCount cannot
    // be the thing that notices.
    PASS([git2 modifiedFileCount] == 0,
         "untracked files do not make a tree dirty as far as the stash check knows");

    // Documentation of the bug, not proof of the fix: this is what a run did
    // with the repository 16 commits behind and no divergence anywhere.
    PASS(![git2 switchAndFastForwardTo:@"main"],
         "a fast-forward is refused while untracked files are in the way");

    NSArray *wantBlockers = @[@"added/different.txt", @"added/same.txt"];
    PASS_EQUAL([git2 untrackedPathsBlockingFastForwardTo:@"main"], wantBlockers,
               "both incoming files that already exist in the working tree are "
               "named, and an unrelated untracked file is not");

    NSString *failure = nil;
    NSArray *blockers = [git2 untrackedPathsBlockingFastForwardTo:@"main"];
    PASS([git2 setAsideUntrackedPaths:blockers failure:&failure],
         "the blocking files are moved aside rather than deleted");
    PASS(failure == nil, "no path failed to move");
    PASS(![NSFileManager.defaultManager fileExistsAtPath:
            [work2 stringByAppendingPathComponent:@"added/different.txt"]],
         "the working tree path is free for the update to write");
    PASS([NSFileManager.defaultManager fileExistsAtPath:
            [git2 setAsidePathForRelativePath:@"added/different.txt"]],
         "the user's copy is kept, inside .git, under its original path");

    PASS([git2 switchAndFastForwardTo:@"main"],
         "the fast-forward succeeds once the blocking file is out of the way");

    // The unrelated untracked file must have been left exactly where it was.
    PASS([NSFileManager.defaultManager fileExistsAtPath:
            [work2 stringByAppendingPathComponent:@"mine/notes.txt"]],
         "an untracked file the update does not touch is never moved");

    // added/same.txt was identical to what the update brought, added/different.txt
    // was the user's own work and is not: the first copy is redundant and goes,
    // the second is kept and named so it can be found and merged back.
    NSArray *wantKept = @[@"added/different.txt"];
    PASS_EQUAL([git2 reconcileSetAsidePaths:blockers], wantKept,
               "reconciling keeps the copy that differs from the update and "
               "discards the one it is identical to");
    PASS(![NSFileManager.defaultManager fileExistsAtPath:
            [git2 setAsidePathForRelativePath:@"added/same.txt"]],
         "the redundant copy of an identical file is removed");
    NSString *keptBytes = [NSString stringWithContentsOfFile:
      [git2 setAsidePathForRelativePath:@"added/different.txt"]
                                                encoding:NSUTF8StringEncoding error:NULL];
    PASS_EQUAL(keptBytes, @"my own work\n", "the kept copy still holds what the user wrote");

    // Reconciling again finds the kept copy still there and reports it again -
    // it is still the user's file and still has to be named - while the copy
    // that was removed is not resurrected and not reported a second time.
    NSArray *wantStillKept = @[@"added/different.txt"];
    PASS_EQUAL([git2 reconcileSetAsidePaths:blockers], wantStillKept,
               "reconciling again reports only what is still kept");
  }

  /* --- moving files aside and putting them straight back --- */
  //
  // The update can still fail after the files are moved (a real divergence, a
  // build error), and then the working tree has to be exactly as it was. The
  // copy that was displaced is the user's only copy of it.
  {
    NSString *work2 = [gBaseDir stringByAppendingPathComponent:@"work2"];
    SWGitTool *git2 = [[SWGitTool alloc] initWithRepositoryPath:work2];
    // The block above deliberately leaves one copy behind - a user's own file
    // that the update is not allowed to throw away. This block is about files
    // that go straight back out again, so it starts from an empty directory.
    runShell([NSString stringWithFormat:@"rm -rf %@", [git2 setAsideDirectoryPath]]);
    NSString *notes = [work2 stringByAppendingPathComponent:@"mine/notes.txt"];
    runShell([NSString stringWithFormat:@"echo 'mine again' > %@", notes]);

    NSArray *onePath = @[@"mine/notes.txt"];
    PASS([git2 setAsideUntrackedPaths:onePath failure:NULL],
         "a displaced file moves aside");
    PASS(![NSFileManager.defaultManager fileExistsAtPath:notes],
         "and the working tree path it came from is empty");

    PASS_EQUAL([git2 restoreSetAsidePaths:onePath], @[],
               "putting the files back leaves nothing set aside");
    NSString *restored = [NSString stringWithContentsOfFile:notes
                                                   encoding:NSUTF8StringEncoding error:NULL];
    PASS_EQUAL(restored, @"mine again\n", "the file is back in the working tree unchanged");

    // The case where putting a file back would destroy something: the update
    // already checked that path out, so the working tree owns it now.
    // Overwriting it with the set-aside copy would throw away the version the
    // update chose and hand back a stale one instead, so the copy stays put and
    // is reported as left behind rather than forced back over it.
    PASS([git2 setAsideUntrackedPaths:onePath failure:NULL],
         "the file can be set aside a second time");
    runShell([NSString stringWithFormat:@"echo 'checked out' > %@", notes]);
    NSArray *wantLeft = @[@"mine/notes.txt"];
    PASS_EQUAL([git2 restoreSetAsidePaths:onePath], wantLeft,
               "a path the working tree now has is not overwritten on the way back");
    NSString *stillSetAside = [NSString stringWithContentsOfFile:
      [git2 setAsidePathForRelativePath:@"mine/notes.txt"]
                                                  encoding:NSUTF8StringEncoding error:NULL];
    PASS_EQUAL(stillSetAside, @"mine again\n",
               "and the copy that could not go back is still intact");
  }

  runShell([NSString stringWithFormat:@"rm -rf %@", gBaseDir]);
  [arp release];
  return 0;
}
