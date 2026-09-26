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

  runShell([NSString stringWithFormat:@"rm -rf %@", base]);
  [arp release];
  return 0;
}
