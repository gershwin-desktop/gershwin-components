/* t_SWRepositoryUpdater.m - ObjectTesting coverage for SWRepositoryUpdater,
 * against real scratch git repos and a fake install-system-domain.sh that
 * reproduces the real script's one CWD-sensitive line (sourcing
 * "./Library/Scripts/functions.sh" relative to the current directory, not
 * to the script's own location) so a missing -setCurrentDirectoryPath:
 * fails this test the same way it would fail for real.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SWRepository.h"
#import "SWRepositoryUpdater.h"
#include <unistd.h>
#include <dispatch/dispatch.h>

static void runShell(NSString *cmd)
{
  system([cmd UTF8String]);
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSString *base = [NSString stringWithFormat:@"/tmp/sw-updater-test-%d", getpid()];
  NSString *developerRoot = [base stringByAppendingPathComponent:@"Developer"];
  NSString *sourcesDir = [developerRoot stringByAppendingPathComponent:@"Library/Sources"];
  NSString *scriptsDir = [developerRoot stringByAppendingPathComponent:@"Library/Scripts"];
  NSString *installScript = [scriptsDir stringByAppendingPathComponent:@"install-system-domain.sh"];
  NSString *markerDir = [base stringByAppendingPathComponent:@"markers"];

  runShell([NSString stringWithFormat:@"rm -rf %@ && mkdir -p %@ %@ %@",
    base, sourcesDir, scriptsDir, markerDir]);

  // A fake functions.sh + install-system-domain.sh that reproduces the real
  // script's exact CWD-relative source line. If SWRepositoryUpdater ever
  // stops setting the task's working directory to developerRoot, this
  // "." fails with "No such file or directory" and the test goes red for
  // the same reason a real run would.
  runShell([NSString stringWithFormat:
    @"echo 'FAKE_FUNCTIONS_LOADED=1' > %@/functions.sh", scriptsDir]);
  NSString *fakeScript = [NSString stringWithFormat:
    @"#!/bin/sh\n"
     "set -e\n"
     ". ./Library/Scripts/functions.sh\n"     // exact CWD-relative line from the real script
     "[ \"$FAKE_FUNCTIONS_LOADED\" = 1 ] || { echo missing functions.sh; exit 1; }\n"
     "case \"$1\" in\n"
     "  build-repo) touch '%@/build-'\"$2\" ;;\n"
     "  install-repo) touch '%@/install-'\"$2\" ;;\n"
     "  *) echo \"unknown target: $1\"; exit 1 ;;\n"
     "esac\n", markerDir, markerDir];
  [fakeScript writeToFile:installScript atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  runShell([NSString stringWithFormat:@"chmod +x %@", installScript]);

  // Several cases below swap in a different script and have to put this one
  // back, so a copy of it is kept rather than just its path.
  //
  // It has to be a real copy. Two separate mistakes hid in what used to be
  // here: naming the path is not saving the file, and on GNUstep
  // -copyItemAtPath:toPath: refuses a destination that already exists, saying
  // so only through an out-parameter that a call written as one line throws
  // away. Together they made every "put the real script back" a no-op that
  // silently left the previous case's script installed - so a case could
  // rebuild with the "build fails" script, or with no script at all, and pass
  // or fail on the previous case's wreckage.
  NSString *savedScript = [scriptsDir stringByAppendingPathComponent:
    @"install-system-domain.sh.saved"];
  [[NSFileManager defaultManager] copyItemAtPath:installScript
                                         toPath:savedScript error:NULL];
  runShell([NSString stringWithFormat:@"chmod +x %@", savedScript]);
  void (^restoreScript)(void) = ^{
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:installScript error:NULL];
    [fm copyItemAtPath:savedScript toPath:installScript error:NULL];
  };

  // A real scratch repo, one commit behind origin/main, matching t_SWGitTool's fixture shape.
  NSString *originDir = [base stringByAppendingPathComponent:@"origin"];
  NSString *work = [sourcesDir stringByAppendingPathComponent:@"gershwin-workspace"];
  runShell([NSString stringWithFormat:
    @"git init -q -b main %@ && cd %@ && git config user.email t@x.invalid && "
     "git config user.name T && echo a > f.txt && git add f.txt && git commit -q -m first",
    originDir, originDir]);
  runShell([NSString stringWithFormat:@"git clone -q %@ %@", originDir, work]);
  runShell([NSString stringWithFormat:@"cd %@ && echo b >> f.txt && git commit -q -am second", originDir]);
  runShell([NSString stringWithFormat:@"cd %@ && git fetch -q origin", work]);

  SWRepository *repo = [[SWRepository alloc] initWithPlistEntry:@{@"Name": @"gershwin-workspace", @"URL": @"u"}];

  SWRepositoryUpdater *updater = [[SWRepositoryUpdater alloc] initWithSourcesDirectory:sourcesDir
                                                                      installScriptPath:installScript
                                                                             logHandler:nil];

  __block NSMutableArray *steps = [NSMutableArray array];
  SWRepositoryUpdateOutcome outcome = [updater updateRepository:repo
                                                     targetBranch:@"main"
                                                      stepHandler:^(NSString *verb) {
    [steps addObject:verb];
  }];

  PASS(outcome == SWRepositoryUpdateOutcomeUpdated,
       "a clean fast-forward update with a successful build+install reports Updated");
  PASS([[NSFileManager defaultManager] fileExistsAtPath:
    [markerDir stringByAppendingPathComponent:@"build-gershwin-workspace"]],
       "the fake script's build-repo step ran to completion (functions.sh sourced correctly)");
  PASS([[NSFileManager defaultManager] fileExistsAtPath:
    [markerDir stringByAppendingPathComponent:@"install-gershwin-workspace"]],
       "the fake script's install-repo step ran to completion");
  PASS([steps containsObject:@"Checking out gershwin-workspace"], "the checkout step is reported");
  PASS([steps containsObject:@"Building gershwin-workspace"], "the build step is reported");
  PASS([steps containsObject:@"Installing gershwin-workspace"], "the install step is reported");

  NSTask *revParse = [[NSTask alloc] init];
  [revParse setLaunchPath:@"/usr/bin/env"];
  [revParse setArguments:@[@"git", @"-C", work, @"rev-parse", @"HEAD"]];
  NSPipe *pipe = [NSPipe pipe];
  [revParse setStandardOutput:pipe];
  [revParse launch];
  NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
  [revParse waitUntilExit];
  NSString *newHead = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSString *originHead = [[NSString stringWithContentsOfFile:
    [originDir stringByAppendingPathComponent:@".git/refs/heads/main"]
    encoding:NSUTF8StringEncoding error:NULL]
    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  PASS_EQUAL(newHead, originHead, "the working copy actually fast-forwarded to origin/main's tip");

  // A non-pinned repository with no resolvable target branch (e.g. the
  // checking phase could not determine origin's default branch) used to hand
  // nil straight into an Objective-C array literal (@[@"switch", nil]),
  // which raises NSInvalidArgumentException and takes down the whole
  // privileged helper process mid-run - confirmed live against a real
  // checkout that had hit exactly this path.
  SWRepositoryUpdateOutcome nilTargetOutcome = [updater updateRepository:repo
                                                             targetBranch:nil
                                                              stepHandler:nil];
  PASS(nilTargetOutcome == SWRepositoryUpdateOutcomeDiverged,
       "a non-pinned repository with no target branch fails cleanly instead of crashing");

  // --- build output must reach the log as it is produced, not in one lump ---
  //
  // The build step used to slurp the whole pipe with -readDataToEndOfFile and
  // log it only after the child exited, so a long build showed one command line
  // and then nothing at all - indistinguishable from a hang. Worse, stdout and
  // stderr share one pipe, so output beyond the pipe's buffer could wedge the
  // child in write() and the parent in read, with neither able to finish.
  //
  // A fake script that announces itself, pauses long enough for the log to be
  // inspected mid-run, then writes far more than any pipe buffer holds.
  {
    NSString *bigScript = [scriptsDir stringByAppendingPathComponent:@"slow.sh"];
    NSString *bigMarker = [markerDir stringByAppendingPathComponent:@"big.log"];
    // 4000 numbered lines is comfortably past a 64 KiB pipe buffer.
    NSString *bigSource = [NSString stringWithFormat:
      @"#!/bin/sh\n"
       "case \"$1\" in\n"
       "  build-repo) i=1; while [ $i -le 4000 ]; do echo \"line $i\"; i=$((i+1)); done > '%@';\n"
       "            cat '%@';\n"
       "            sleep 3 ;;\n"
       "  install-repo) : ;;\n"
       "  *) exit 1 ;;\n"
       "esac\n", bigMarker, bigMarker];
    [bigSource writeToFile:bigScript atomically:YES
                 encoding:NSUTF8StringEncoding error:NULL];
    runShell([NSString stringWithFormat:@"chmod +x %@", bigScript]);

    // Same script, so the run is identical apart from which one is used.
    [[NSFileManager defaultManager] removeItemAtPath:installScript error:NULL];
    [[NSFileManager defaultManager] copyItemAtPath:bigScript toPath:installScript error:NULL];

    __block NSMutableArray *live = [NSMutableArray array];
    __block BOOL firstLineSeen = NO;
    NSDate *started = [NSDate date];
    SWRepositoryUpdater *watcher = [[SWRepositoryUpdater alloc] initWithSourcesDirectory:sourcesDir
                                                                    installScriptPath:installScript
                                                                           logHandler:^(NSString *line) {
      @synchronized (live) {
        if (!firstLineSeen && [line hasPrefix:@"line 1"]) firstLineSeen = YES;
        [live addObject:line];
      }
    }];

    NSString *bigRepo = [sourcesDir stringByAppendingPathComponent:@"gershwin-workspace"];
    (void)bigRepo; // documents which checkout the big-output build is run against
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSDate *finish = [NSDate dateWithTimeIntervalSinceNow:60];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      [watcher updateRepository:repo targetBranch:@"main" stepHandler:nil];
      dispatch_semaphore_signal(done);
    });

    // While the fake script is still in its sleep, the first output line must
    // already be in the log: that is the whole point of the change.
    BOOL early = NO;
    while ([finish timeIntervalSinceNow] > 0) {
      @synchronized (live) { early = firstLineSeen; }
      if (early) break;
      [NSThread sleepForTimeInterval:0.05];
    }
    NSTimeInterval earlyAfter = -[started timeIntervalSinceNow];
    PASS(early, "build output reaches the log while the build is still running");
    PASS(earlyAfter < 2.5,
         "it arrives promptly, not after the build finishes");

    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    __block NSUInteger seen = 0;
    @synchronized (live) {
      for (NSString *line in live) if ([line hasPrefix:@"line "]) seen++;
    }
    // 4000 from cat plus 4000 echoed back by the "Compiling" pass is too
    // specific; what matters is that a volume far past the pipe buffer
    // survived, which a deadlocked reader could never do.
    PASS(seen >= 4000,
         "output far larger than the pipe buffer is delivered in full (no deadlock)");

    restoreScript();
  }

  // --- a build that dirties tracked files must not break the stash pop ---
  //
  // Reproduces the loop reported on the test box. gnustep-make runs
  // autoreconf/configure per subdirectory, so a real build rewrites tracked
  // files: `configure` comes back stamped with the local autoconf's version
  // and `config.h.in` gains entries for headers the checkout now uses. Those
  // were left in the tree before the stash was popped, so the pop merged
  // against them and reported a conflict; `reset --merge` does not touch
  // merely-modified files, so the tree stayed dirty and every subsequent run
  // stashed the same generated files and conflicted again - forever, with the
  // user's real work stranded in a stash.
  //
  // The fake script's build step here dirties a tracked file the same way, and
  // gershwin-workspace has no Patches directory, which is exactly the
  // repository shape in which the old `if (patchesApplied)` guard skipped the
  // cleanup.
  {
    NSString *dirtyScript = [scriptsDir stringByAppendingPathComponent:@"dirty.sh"];
    NSString *dirtySource = [NSString stringWithFormat:
      @"#!/bin/sh\n"
       "REPO='%@'\n"
       "case \"$1\" in\n"
       "  build-repo) echo '# Generated by a newer autoconf' >> \"$REPO/f.txt\" ;;\n"
       "  install-repo) : ;;\n"
       "  *) exit 1 ;;\n"
       "esac\n", work];
    [dirtySource writeToFile:dirtyScript atomically:YES
                   encoding:NSUTF8StringEncoding error:NULL];
    runShell([NSString stringWithFormat:@"chmod +x %@", dirtyScript]);

    // The user's own local edit, which must survive the whole run.
    runShell([NSString stringWithFormat:@"cd %@ && echo mine >> f.txt", work]);

    [[NSFileManager defaultManager] removeItemAtPath:installScript error:NULL];
    [[NSFileManager defaultManager] copyItemAtPath:dirtyScript toPath:installScript error:NULL];

    SWRepositoryUpdateOutcome dirtyOutcome = [updater updateRepository:repo
                                                          targetBranch:@"main"
                                                           stepHandler:nil];
    PASS(dirtyOutcome == SWRepositoryUpdateOutcomeUpdated,
         "a build that regenerates tracked files does not break the stash pop");

    // The user's edit must be back in the working tree...
    NSString *after = [NSString stringWithContentsOfFile:
      [work stringByAppendingPathComponent:@"f.txt"]
                                               encoding:NSUTF8StringEncoding error:NULL];
    PASS([after rangeOfString:@"mine"].location != NSNotFound,
         "the user's own local change is re-applied after the dirty build");

    // ...and the build's leftovers must be gone, or the next run would stash
    // them again and repeat the whole thing.
    NSTask *status = [[NSTask alloc] init];
    [status setLaunchPath:@"/usr/bin/env"];
    [status setArguments:@[@"git", @"-C", work, @"status", @"--porcelain"]];
    NSPipe *statusPipe = [NSPipe pipe];
    [status setStandardOutput:statusPipe];
    [status launch];
    NSData *statusData = [[statusPipe fileHandleForReading] readDataToEndOfFile];
    [status waitUntilExit];
    NSString *statusText = [[[NSString alloc] initWithData:statusData
                                                   encoding:NSUTF8StringEncoding]
      stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    PASS([statusText rangeOfString:@"autoconf"].location == NSNotFound,
         "the build's regenerated content is not left behind for the next run");

    restoreScript();
  }

  // --- Rebuild: build and install what is checked out, touching no git state ---
  //
  // This is what the "Rebuild" button on the "Your software is up to date."
  // alert runs. The whole point is that it changes nothing about the checkout,
  // so the assertions below are all about git state being untouched: the
  // working copy keeps its local modifications, HEAD does not move, and no
  // stash is created. A rebuild that quietly stashed the user's work or
  // checked out a branch would be a different and much worse operation.
  {
    runShell([NSString stringWithFormat:@"cd %@ && echo hand-edit >> f.txt", work]);
    NSTask *headBefore = [[NSTask alloc] init];
    [headBefore setLaunchPath:@"/usr/bin/env"];
    [headBefore setArguments:@[@"git", @"-C", work, @"rev-parse", @"HEAD"]];
    NSPipe *headBeforePipe = [NSPipe pipe];
    [headBefore setStandardOutput:headBeforePipe];
    [headBefore launch];
    NSString *headBeforeText = [[[[NSString alloc] initWithData:
      [[headBeforePipe fileHandleForReading] readDataToEndOfFile]
                                                  encoding:NSUTF8StringEncoding]
      stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    [headBefore waitUntilExit];

    __block NSMutableArray *rebuildSteps = [NSMutableArray array];
    SWRepositoryUpdateOutcome rebuildOutcome = [updater rebuildRepository:repo
                                                              stepHandler:^(NSString *verb) {
      @synchronized (rebuildSteps) { [rebuildSteps addObject:verb]; }
    }];
    PASS(rebuildOutcome == SWRepositoryUpdateOutcomeUpdated,
         "a rebuild of a checked-out repository reports Updated");

    BOOL sawBuild = NO, sawInstall = NO;
    @synchronized (rebuildSteps) {
      for (NSString *verb in rebuildSteps) {
        if ([verb hasPrefix:@"Building "]) sawBuild = YES;
        if ([verb hasPrefix:@"Installing "]) sawInstall = YES;
      }
    }
    PASS(sawBuild, "a rebuild builds the repository");
    PASS(sawInstall, "a rebuild installs the repository");
    PASS([rebuildSteps count] == 2,
         "a rebuild runs no git steps at all (no stash, no checkout)");

    // The local edit must be exactly where it was: still in the working tree.
    NSString *rebuildAfter = [NSString stringWithContentsOfFile:
      [work stringByAppendingPathComponent:@"f.txt"]
                                               encoding:NSUTF8StringEncoding error:NULL];
    PASS([rebuildAfter rangeOfString:@"hand-edit"].location != NSNotFound,
         "a rebuild leaves the working copy's local changes in place");

    NSTask *headAfter = [[NSTask alloc] init];
    [headAfter setLaunchPath:@"/usr/bin/env"];
    [headAfter setArguments:@[@"git", @"-C", work, @"rev-parse", @"HEAD"]];
    NSPipe *headAfterPipe = [NSPipe pipe];
    [headAfter setStandardOutput:headAfterPipe];
    [headAfter launch];
    NSString *headAfterText = [[[[NSString alloc] initWithData:
      [[headAfterPipe fileHandleForReading] readDataToEndOfFile]
                                                encoding:NSUTF8StringEncoding]
      stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    [headAfter waitUntilExit];
    PASS_EQUAL(headAfterText, headBeforeText, "a rebuild does not move HEAD");

    NSTask *stashCount = [[NSTask alloc] init];
    [stashCount setLaunchPath:@"/usr/bin/env"];
    [stashCount setArguments:@[@"git", @"-C", work, @"stash", @"list"]];
    NSPipe *stashPipe = [NSPipe pipe];
    [stashCount setStandardOutput:stashPipe];
    [stashCount launch];
    NSString *stashText = [[[[NSString alloc] initWithData:
      [[stashPipe fileHandleForReading] readDataToEndOfFile]
                                                encoding:NSUTF8StringEncoding]
      stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    [stashCount waitUntilExit];
    PASS([stashText length] == 0, "a rebuild creates no stash");

    // A rebuild must apply the repository's patch set before building, or it
    // compiles vanilla sources: libs-gui alone ships 20 patches and is visibly
    // wrong without them (fractional scale factors, submenu precedence, scroll
    // autohide subpixel). patch.sh is idempotent, so a rebuild of an
    // already-patched tree is a no-op rather than a double application.
    {
      NSString *patchDir = [developerRoot stringByAppendingPathComponent:
        @"Library/Patches/gershwin-workspace"];
      runShell([NSString stringWithFormat:@"mkdir -p %@", patchDir]);
      NSString *patchText = @"--- a/f.txt\n+++ b/f.txt\n@@ -1,1 +1,2 @@\n a\n+patched line\n";
      [patchText writeToFile:[patchDir stringByAppendingPathComponent:@"marker.patch"]
                  atomically:YES
                    encoding:NSUTF8StringEncoding error:NULL];

      // Stands in for the real patch.sh: applies unless already present, the
      // way the real one's reverse dry run decides.
      NSString *patchScript = [scriptsDir stringByAppendingPathComponent:@"patch.sh"];
      NSString *patchSource = [NSString stringWithFormat:
        @"#!/bin/sh\n"
         "cd '%@' || exit 1\n"
         "if grep -q 'patched line' f.txt 2>/dev/null; then "
         "echo '  marker.patch... already applied'; exit 0; fi\n"
         "echo 'patched line' >> f.txt\n"
         "echo '  marker.patch... applied'\n", work];
      [patchSource writeToFile:patchScript atomically:YES
                     encoding:NSUTF8StringEncoding error:NULL];
      runShell([NSString stringWithFormat:@"chmod +x %@", patchScript]);

      // Start from an unpatched tree so the run has something to do.
      runShell([NSString stringWithFormat:
        @"cd %@ && grep -v 'patched line' f.txt > f.tmp && mv f.tmp f.txt", work]);

      __block NSMutableArray *patchSteps = [NSMutableArray array];
      PASS([updater rebuildRepository:repo stepHandler:^(NSString *verb) {
        @synchronized (patchSteps) { [patchSteps addObject:verb]; }
      }] == SWRepositoryUpdateOutcomeUpdated,
        "a rebuild of a repository with patches reports Updated");

      BOOL sawPatchStep = NO;
      @synchronized (patchSteps) {
        for (NSString *verb in patchSteps) {
          if ([verb hasPrefix:@"Patching "]) sawPatchStep = YES;
        }
      }
      PASS(sawPatchStep, "a rebuild reports a patching step for a patched repository");

      NSString *afterPatch = [NSString stringWithContentsOfFile:
        [work stringByAppendingPathComponent:@"f.txt"]
                                                   encoding:NSUTF8StringEncoding error:NULL];
      PASS([afterPatch rangeOfString:@"patched line"].location != NSNotFound,
           "a rebuild applies the patch set before building");

      // A second rebuild must not apply it twice. patch.sh's idempotence is
      // what makes re-running it every time safe, and a rebuild re-runs it
      // every time by design - so this is the path most likely to trip it.
      [updater rebuildRepository:repo stepHandler:nil];
      NSString *afterTwice = [NSString stringWithContentsOfFile:
        [work stringByAppendingPathComponent:@"f.txt"]
                                                   encoding:NSUTF8StringEncoding error:NULL];
      NSUInteger appliedCount = 0;
      for (NSString *line in [afterTwice componentsSeparatedByString:@"\n"]) {
        if ([line isEqualToString:@"patched line"]) appliedCount++;
      }
      PASS(appliedCount == 1, "a second rebuild does not apply the same patch twice");

      // A repository with no patch directory must not gain a patching step.
      __block NSMutableArray *plainSteps = [NSMutableArray array];
      [updater rebuildRepository:[[SWRepository alloc] initWithPlistEntry:
        @{@"Name": @"gershwin-textedit", @"URL": @"u"}]
                       stepHandler:^(NSString *verb) {
        @synchronized (plainSteps) { [plainSteps addObject:verb]; }
      }];
      BOOL sawPatch = NO;
      @synchronized (plainSteps) {
        for (NSString *verb in plainSteps) {
          if ([verb hasPrefix:@"Patching "]) sawPatch = YES;
        }
      }
      PASS(!sawPatch, "a rebuild of an unpatched repository has no patching step");

      runShell([NSString stringWithFormat:@"rm -rf %@", patchDir]);
      [[NSFileManager defaultManager] removeItemAtPath:patchScript error:NULL];
    }

    // A build failure is reported, not swallowed, and not turned into a
    // rollback: there is no earlier commit to go back to.
    NSString *failScript = [scriptsDir stringByAppendingPathComponent:@"fail.sh"];
    NSString *failSource = [NSString stringWithFormat:
      @"#!/bin/sh\n"
       "case \"$1\" in\n"
       "  build-repo) echo 'compiler error' >&2; exit 2 ;;\n"
       "  *) exit 0 ;;\n"
       "esac\n"];
    [failSource writeToFile:failScript atomically:YES
                  encoding:NSUTF8StringEncoding error:NULL];
    runShell([NSString stringWithFormat:@"chmod +x %@", failScript]);
    [[NSFileManager defaultManager] removeItemAtPath:installScript error:NULL];
    [[NSFileManager defaultManager] copyItemAtPath:failScript toPath:installScript error:NULL];
    PASS([updater rebuildRepository:repo stepHandler:nil] ==
           SWRepositoryUpdateOutcomeBuildFailed,
         "a rebuild whose build fails reports BuildFailed");
    restoreScript();
  }

  // --- an untracked file in the way of the fast-forward ---
  //
  // Reproduces the reported failure. gershwin-components had six files under
  // DiskUtility/Tests/ that had reached the checkout without git knowing about
  // them, and a commit upstream added exactly those six paths. The repository
  // was sixteen commits behind and had never diverged - git said so itself -
  // but `git merge --ff-only` refuses to overwrite an untracked file, so the
  // run reported "diverged, not updated" and did so on every single attempt,
  // for ever. Untracked files are never stashed, which is why nothing else in
  // the run noticed them either.
  {
    NSString *origin2 = [base stringByAppendingPathComponent:@"origin2"];
    NSString *du = [sourcesDir stringByAppendingPathComponent:@"gershwin-diskutility"];
    runShell([NSString stringWithFormat:
      @"git init -q -b main %@ && cd %@ && git config user.email t@x.invalid && "
       "git config user.name T && echo a > f.txt && git add f.txt && "
       "git commit -q -m first", origin2, origin2]);
    runShell([NSString stringWithFormat:@"git clone -q %@ %@", origin2, du]);
    runShell([NSString stringWithFormat:
      @"cd %@ && mkdir -p Tests && echo 'upstream test' > Tests/TestLiveBackend.m && "
       "git add Tests && git commit -q -m 'adds a test'", origin2]);
    // The same file, byte for byte, sitting untracked in the working tree -
    // which is exactly what was found on the box.
    runShell([NSString stringWithFormat:
      @"cd %@ && mkdir -p Tests && echo 'upstream test' > Tests/TestLiveBackend.m", du]);
    runShell([NSString stringWithFormat:@"cd %@ && git fetch -q origin", du]);

    SWRepository *duRepo = [[SWRepository alloc] initWithPlistEntry:
      @{@"Name": @"gershwin-diskutility", @"URL": @"u"}];
    SWRepositoryUpdateOutcome duOutcome = [updater updateRepository:duRepo
                                                      targetBranch:@"main"
                                                       stepHandler:nil];

    // The assertion the reported failure turns on: this used to be Diverged.
    PASS(duOutcome == SWRepositoryUpdateOutcomeUpdated,
         "an untracked file the update would create no longer makes the run "
         "report a divergence");

    NSTask *duHead = [[NSTask alloc] init];
    [duHead setLaunchPath:@"/usr/bin/env"];
    [duHead setArguments:@[@"git", @"-C", du, @"rev-parse", @"HEAD"]];
    NSPipe *duHeadPipe = [NSPipe pipe];
    [duHead setStandardOutput:duHeadPipe];
    [duHead launch];
    NSData *duHeadData = [[duHeadPipe fileHandleForReading] readDataToEndOfFile];
    [duHead waitUntilExit];
    NSString *duHeadText = [[[NSString alloc] initWithData:duHeadData
                                                 encoding:NSUTF8StringEncoding]
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSTask *duOriginHead = [[NSTask alloc] init];
    [duOriginHead setLaunchPath:@"/usr/bin/env"];
    [duOriginHead setArguments:@[@"git", @"-C", origin2, @"rev-parse", @"main"]];
    NSPipe *duOriginPipe = [NSPipe pipe];
    [duOriginHead setStandardOutput:duOriginPipe];
    [duOriginHead launch];
    NSData *duOriginData = [[duOriginPipe fileHandleForReading] readDataToEndOfFile];
    [duOriginHead waitUntilExit];
    NSString *duOriginText = [[[NSString alloc] initWithData:duOriginData
                                                    encoding:NSUTF8StringEncoding]
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    PASS_EQUAL(duHeadText, duOriginText,
               "the working copy really did fast-forward to origin/main's tip");

    // The file the update produced must be a tracked file now, and the
    // identical copy that was set aside to make room for it must be gone -
    // otherwise every run leaves another one behind.
    NSTask *duTracked = [[NSTask alloc] init];
    [duTracked setLaunchPath:@"/usr/bin/env"];
    [duTracked setArguments:@[@"git", @"-C", du, @"ls-files", @"--error-unmatch",
                              @"Tests/TestLiveBackend.m"]];
    NSPipe *duTrackedPipe = [NSPipe pipe];
    [duTracked setStandardOutput:duTrackedPipe];
    [duTracked launch];
    [[duTrackedPipe fileHandleForReading] readDataToEndOfFile];
    [duTracked waitUntilExit];
    PASS([duTracked terminationStatus] == 0,
         "the path the update created is now tracked by git");

    NSTask *duStatus = [[NSTask alloc] init];
    [duStatus setLaunchPath:@"/usr/bin/env"];
    [duStatus setArguments:@[@"git", @"-C", du, @"status", @"--porcelain"]];
    NSPipe *duStatusPipe = [NSPipe pipe];
    [duStatus setStandardOutput:duStatusPipe];
    [duStatus launch];
    NSData *duStatusData = [[duStatusPipe fileHandleForReading] readDataToEndOfFile];
    [duStatus waitUntilExit];
    NSString *duStatusText = [[[NSString alloc] initWithData:duStatusData
                                                    encoding:NSUTF8StringEncoding]
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    PASS([duStatusText length] == 0,
         "the repository is left clean, with no untracked leftovers of its own");

    PASS(![[NSFileManager defaultManager] fileExistsAtPath:
             [du stringByAppendingPathComponent:
               @".git/software-update-aside/Tests/TestLiveBackend.m"]],
         "the identical copy that was set aside is not left behind to clutter "
         "the next run");

    // And when the file that was moved aside is NOT what the update brings,
    // the run has to say so and say where the user's version is - otherwise
    // the file is simply gone from where they left it, with no way to find it.
    __block NSMutableArray *logLines = [NSMutableArray array];
    NSString *origin3 = [base stringByAppendingPathComponent:@"origin3"];
    NSString *dw = [sourcesDir stringByAppendingPathComponent:@"gershwin-dw"];
    runShell([NSString stringWithFormat:
      @"git init -q -b main %@ && cd %@ && git config user.email t@x.invalid && "
       "git config user.name T && echo a > f.txt && git add f.txt && "
       "git commit -q -m first", origin3, origin3]);
    runShell([NSString stringWithFormat:@"git clone -q %@ %@", origin3, dw]);
    runShell([NSString stringWithFormat:
      @"cd %@ && echo upstream > Notes.txt && git add Notes.txt && "
       "git commit -q -m adds", origin3]);
    runShell([NSString stringWithFormat:@"cd %@ && echo 'my version' > Notes.txt", dw]);
    runShell([NSString stringWithFormat:@"cd %@ && git fetch -q origin", dw]);

    SWRepositoryUpdater *logged = [[SWRepositoryUpdater alloc]
      initWithSourcesDirectory:sourcesDir
             installScriptPath:installScript
                    logHandler:^(NSString *line) {
      @synchronized (logLines) { [logLines addObject:line]; }
    }];
    SWRepositoryUpdateOutcome dwOutcome = [logged updateRepository:
      [[SWRepository alloc] initWithPlistEntry:@{@"Name": @"gershwin-dw", @"URL": @"u"}]
                                      targetBranch:@"main"
                                       stepHandler:nil];
    PASS(dwOutcome == SWRepositoryUpdateOutcomeUpdated,
         "an untracked file that differs from the update still updates the repository");

    NSString *keptCopy = nil;
    @synchronized (logLines) {
      for (NSString *line in logLines) {
        if ([line rangeOfString:@"Notes.txt"].location != NSNotFound &&
            [line rangeOfString:@"software-update-aside"].location != NSNotFound) {
          keptCopy = line;
        }
      }
    }
    PASS(keptCopy != nil,
         "the log names the file that was set aside and where its content went");

    // The user's own version must actually be at the place the log named.
    NSString *saved = [NSString stringWithContentsOfFile:
      [dw stringByAppendingPathComponent:
        @".git/software-update-aside/Notes.txt"]
                                             encoding:NSUTF8StringEncoding error:NULL];
    PASS_EQUAL(saved, @"my version\n",
               "the file the log points at really holds what the user wrote");
  }

  // --- a blocking file that cannot be moved out of the way ---
  //
  // The remaining half of the reported failure: the file is in the way and it
  // cannot be put anywhere, because a copy of it is already being kept from an
  // earlier run and overwriting that copy would throw away the only version of
  // the file there is. The repository then genuinely cannot be updated - and it
  // must say THAT. Diverged was what this used to report, which sends the user
  // hunting for local commits that do not exist: git had said, in as many
  // words, that the branch could be fast-forwarded.
  {
    NSString *origin4 = [base stringByAppendingPathComponent:@"origin4"];
    NSString *dn = [sourcesDir stringByAppendingPathComponent:@"gershwin-netutils"];
    runShell([NSString stringWithFormat:
      @"git init -q -b main %@ && cd %@ && git config user.email t@x.invalid && "
       "git config user.name T && echo a > f.txt && git add f.txt && "
       "git commit -q -m first", origin4, origin4]);
    runShell([NSString stringWithFormat:@"git clone -q %@ %@", origin4, dn]);
    runShell([NSString stringWithFormat:
      @"cd %@ && echo upstream > Helper.c && git add Helper.c && "
       "git commit -q -m adds", origin4]);
    runShell([NSString stringWithFormat:@"cd %@ && echo 'in the tree' > Helper.c", dn]);
    runShell([NSString stringWithFormat:@"cd %@ && git fetch -q origin", dn]);

    // A copy is already being kept here - from a run that could not finish.
    NSString *alreadyKept = [dn stringByAppendingPathComponent:
      @".git/software-update-aside/Helper.c"];
    runShell([NSString stringWithFormat:@"mkdir -p %@ && echo 'kept from before' > %@",
      [alreadyKept stringByDeletingLastPathComponent], alreadyKept]);

    __block NSMutableArray *blockedLog = [NSMutableArray array];
    SWRepositoryUpdater *blocking = [[SWRepositoryUpdater alloc]
      initWithSourcesDirectory:sourcesDir
             installScriptPath:installScript
                    logHandler:^(NSString *line) {
      @synchronized (blockedLog) { [blockedLog addObject:line]; }
    }];
    SWRepositoryUpdateOutcome blockedOutcome = [blocking updateRepository:
      [[SWRepository alloc] initWithPlistEntry:
        @{@"Name": @"gershwin-netutils", @"URL": @"u"}]
                                         targetBranch:@"main"
                                          stepHandler:nil];

    PASS(blockedOutcome == SWRepositoryUpdateOutcomeBlocked,
         "a file that cannot be moved out of the way is reported as blocking, "
         "not as a divergence");

    // Nothing may be touched when the answer is "no": the working tree keeps
    // its file, and the copy already being kept is not replaced by it.
    NSString *inTree = [NSString stringWithContentsOfFile:
      [dn stringByAppendingPathComponent:@"Helper.c"]
                                               encoding:NSUTF8StringEncoding error:NULL];
    PASS_EQUAL(inTree, @"in the tree\n",
               "the file in the working tree is left exactly as it was");
    NSString *keptBefore = [NSString stringWithContentsOfFile:alreadyKept
                                                    encoding:NSUTF8StringEncoding error:NULL];
    PASS_EQUAL(keptBefore, @"kept from before\n",
               "the copy already being kept is not overwritten");

    NSTask *dnHead = [[NSTask alloc] init];
    [dnHead setLaunchPath:@"/usr/bin/env"];
    [dnHead setArguments:@[@"git", @"-C", dn, @"rev-parse", @"HEAD"]];
    NSPipe *dnHeadPipe = [NSPipe pipe];
    [dnHead setStandardOutput:dnHeadPipe];
    [dnHead launch];
    NSData *dnHeadData = [[dnHeadPipe fileHandleForReading] readDataToEndOfFile];
    [dnHead waitUntilExit];
    NSString *dnHeadText = [[[NSString alloc] initWithData:dnHeadData
                                                 encoding:NSUTF8StringEncoding]
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSTask *dnOriginHead = [[NSTask alloc] init];
    [dnOriginHead setLaunchPath:@"/usr/bin/env"];
    [dnOriginHead setArguments:@[@"git", @"-C", origin4, @"rev-parse", @"main"]];
    NSPipe *dnOriginPipe = [NSPipe pipe];
    [dnOriginHead setStandardOutput:dnOriginPipe];
    [dnOriginHead launch];
    NSData *dnOriginData = [[dnOriginPipe fileHandleForReading] readDataToEndOfFile];
    [dnOriginHead waitUntilExit];
    NSString *dnOriginText = [[[NSString alloc] initWithData:dnOriginData
                                                    encoding:NSUTF8StringEncoding]
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    PASS(![dnHeadText isEqualToString:dnOriginText],
         "a repository that was not updated is not moved part way there");

    // The log has to say what to do about it, since the note in the table only
    // says the file is in the way.
    BOOL saidWhatToDo = NO;
    @synchronized (blockedLog) {
      for (NSString *line in blockedLog) {
        if ([line rangeOfString:@"Helper.c"].location != NSNotFound &&
            [line rangeOfString:@"try again"].location != NSNotFound) {
          saidWhatToDo = YES;
        }
      }
    }
    PASS(saidWhatToDo,
         "the log names the file that is in the way and what to do about it");
  }

  runShell([NSString stringWithFormat:@"rm -rf %@", base]);
  [arp release];
  return 0;
}
