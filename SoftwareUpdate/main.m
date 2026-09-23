/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "Controllers/SWAppDelegate.h"
#import "Models/SWRepository.h"
#import "Models/SWRepositoryUpdater.h"
#import "Models/SWPrerequisitesInstaller.h"
#include <string.h>

// There is no main nib (NSMainNibFile is empty), so NSApplicationMain would
// never wire up a delegate; set it up by hand instead, matching OnDemand.
static SWAppDelegate *gDelegate = nil;

// Core repositories: if one of these (or gershwin-developer/-system) fails,
// everything after it is built against a tree that may not even compile, so
// the whole run stops rather than limping on. Matches the spec's "For
// gershwin-developer, gershwin-system or a core library, stop the whole run".
static BOOL isCoreRepository(NSString *name)
{
  static NSSet *coreNames = nil;
  if (!coreNames) {
    coreNames = [NSSet setWithArray:@[
      @"gershwin-developer", @"gershwin-system", @"tools-make", @"libobjc2",
      @"libs-base", @"libs-gui", @"libs-back",
    ]];
  }
  return [coreNames containsObject:name];
}

static void emitLog(NSString *line)
{
  printf("LOG:%s\n", [line UTF8String]);
  fflush(stdout);
}

// Runs one repository through the updater and emits its REPO/STEP/DONE
// events. Returns the outcome so the caller can decide whether a core
// failure must stop the whole run.
static SWRepositoryUpdateOutcome runOneRepository(SWRepositoryUpdater *updater,
                                                    NSDictionary *repoDict,
                                                    NSUInteger index,
                                                    NSUInteger total)
{
  SWRepository *repo = [[SWRepository alloc] initWithPlistEntry:repoDict];
  NSString *targetBranch = [repoDict objectForKey:@"TargetBranch"];

  printf("REPO:%s:%lu:%lu\n", [[repo name] UTF8String], (unsigned long)index, (unsigned long)total);
  fflush(stdout);

  SWRepositoryUpdateOutcome outcome = [updater updateRepository:repo
                                                     targetBranch:targetBranch
                                                      stepHandler:^(NSString *verb) {
    printf("STEP:%s\n", [verb UTF8String]);
    fflush(stdout);
  }];

  NSString *conflicts = @"";
  if (outcome == SWRepositoryUpdateOutcomeStashKept) {
    conflicts = [[updater conflictedPathsForRepositoryNamed:[repo name]] componentsJoinedByString:@";"];
  }
  printf("DONE:%s:%ld:%s\n", [[repo name] UTF8String], (long)outcome, [conflicts UTF8String]);
  fflush(stdout);

  return outcome;
}

// Runs as root (started by the GUI via SUDO_ASKPASS + sudo -A): reads the
// list of selected repositories and OS-support locations from a plist and
// performs the whole update run - gershwin-developer first, then
// prerequisites, then every other selected repository in order - printing
// one line per event to stdout for the GUI to read back over the pipe it
// launched this process with. Never talks to the display.
static int runPrivilegedUpdate(NSString *argsPath)
{
  NSDictionary *args = [NSDictionary dictionaryWithContentsOfFile:argsPath];
  NSMutableArray *repoDicts = [[args objectForKey:@"Repositories"] mutableCopy];
  NSString *sourcesDirectory = [args objectForKey:@"SourcesDirectory"];
  NSString *installScriptPath = [args objectForKey:@"InstallScriptPath"];
  NSString *osSupportDirectory = [args objectForKey:@"OSSupportDirectory"];

  if (![repoDicts count] || !sourcesDirectory || !installScriptPath) {
    printf("FATAL:Malformed update arguments\n");
    fflush(stdout);
    return 1;
  }

  SWRepositoryUpdater *updater = [[SWRepositoryUpdater alloc] initWithSourcesDirectory:sourcesDirectory
                                                                      installScriptPath:installScriptPath
                                                                             logHandler:^(NSString *line) {
    emitLog(line);
  }];

  // Phase 1: gershwin-developer, if it was selected (always first in list
  // order, per Repositories.csv - never re-sorted).
  if ([[[repoDicts firstObject] objectForKey:@"Name"] isEqualToString:@"gershwin-developer"]) {
    printf("PHASE:developer\n"); fflush(stdout);
    NSDictionary *developerDict = repoDicts[0];
    [repoDicts removeObjectAtIndex:0];

    SWRepositoryUpdateOutcome outcome = runOneRepository(updater, developerDict, 1, 1);
    if (outcome != SWRepositoryUpdateOutcomeUpdated && outcome != SWRepositoryUpdateOutcomeStashKept) {
      printf("FATAL:REPO:gershwin-developer failed to update\n"); fflush(stdout);
      return 1;
    }
    printf("PHASE_DONE:developer\n"); fflush(stdout);
  }

  // Phase 2: prerequisites, once per run, using gershwin-developer's
  // (possibly just-updated) package list.
  printf("PHASE:prereqs\n"); fflush(stdout);
  SWPrerequisitesInstaller *installer =
    [[SWPrerequisitesInstaller alloc] initWithOSSupportDirectory:osSupportDirectory
                                                    packageManager:nil
                                                     osIdentifier:nil];
  [installer setLogHandler:^(NSString *line) {
    emitLog(line);
  }];
  NSArray *missing = [installer missingPackages];
  printf("PREREQ_MISSING:%s\n", [[missing componentsJoinedByString:@";"] UTF8String]);
  fflush(stdout);

  NSError *prereqError = nil;
  BOOL prereqsOK = [installer installMissingPackagesWithProgress:
    ^(NSString *packageName, NSUInteger index, NSUInteger total) {
      printf("PREREQ_PROGRESS:%s:%lu:%lu\n", [packageName UTF8String],
             (unsigned long)index, (unsigned long)total);
      fflush(stdout);
    } error:&prereqError];
  if (!prereqsOK) {
    printf("FATAL:PREREQ:%s\n", [([prereqError localizedDescription] ?: @"prerequisite install failed") UTF8String]);
    fflush(stdout);
    return 1;
  }
  printf("PHASE_DONE:prereqs\n"); fflush(stdout);

  // Phase 3: every other selected repository (pinned upstream libraries,
  // then Gershwin repositories), in the order Repositories.csv lists them.
  printf("PHASE:repos\n"); fflush(stdout);
  NSUInteger total = [repoDicts count];
  NSUInteger index = 0;
  for (NSDictionary *repoDict in repoDicts) {
    index++;
    SWRepositoryUpdateOutcome outcome = runOneRepository(updater, repoDict, index, total);

    NSString *name = [repoDict objectForKey:@"Name"];
    BOOL fatalFailure = isCoreRepository(name) &&
      outcome != SWRepositoryUpdateOutcomeUpdated && outcome != SWRepositoryUpdateOutcomeStashKept;
    if (fatalFailure) {
      printf("FATAL:REPO:%s failed to update\n", [name UTF8String]); fflush(stdout);
      return 1;
    }
  }
  printf("PHASE_DONE:repos\n"); fflush(stdout);

  return 0;
}

int main(int argc, const char *argv[])
{
  if (argc >= 3 && strcmp(argv[1], "--run-update") == 0) {
    NSString *argsPath = [NSString stringWithUTF8String:argv[2]];
    int status = runPrivilegedUpdate(argsPath);
    return status;
  }

  [NSApplication sharedApplication];
  gDelegate = [[SWAppDelegate alloc] init];
  [[NSApplication sharedApplication] setDelegate:gDelegate];
  [[NSApplication sharedApplication] run];
  return 0;
}
