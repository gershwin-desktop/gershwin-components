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
  // Several cases below swap in a different script and put this one back, so
  // it is kept here rather than scoped to the block that writes it.
  NSString *savedScript = [installScript copy];

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

    [[NSFileManager defaultManager] removeItemAtPath:installScript error:NULL];
    [[NSFileManager defaultManager] copyItemAtPath:savedScript toPath:installScript error:NULL];
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

    [[NSFileManager defaultManager] copyItemAtPath:savedScript toPath:installScript error:NULL];
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
    [[NSFileManager defaultManager] copyItemAtPath:savedScript toPath:installScript error:NULL];
  }

  runShell([NSString stringWithFormat:@"rm -rf %@", base]);
  [arp release];
  return 0;
}
