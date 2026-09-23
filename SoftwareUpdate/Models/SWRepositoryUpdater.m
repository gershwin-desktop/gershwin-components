/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWRepositoryUpdater.h"
#import "SWGitTool.h"

@interface SWRepositoryUpdater ()
{
  NSString *_sourcesDirectory;
  NSString *_installScriptPath;
  NSString *_developerRoot; // gershwin-developer's own checkout root (e.g. /Developer)
  void (^_logHandler)(NSString *);
  NSMutableDictionary<NSString *, NSArray<NSString *> *> *_conflictedPathsByRepo;
}
@end

@implementation SWRepositoryUpdater

- (instancetype)initWithSourcesDirectory:(NSString *)sourcesDirectory
                       installScriptPath:(NSString *)installScriptPath
                              logHandler:(void (^)(NSString *))logHandler
{
  self = [super init];
  if (self) {
    _sourcesDirectory = [sourcesDirectory copy];
    _installScriptPath = [installScriptPath copy];
    // installScriptPath is .../Library/Scripts/install-system-domain.sh;
    // strip the filename, "Scripts" and "Library" to land on the checkout root.
    _developerRoot = [[[installScriptPath stringByDeletingLastPathComponent]
      stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    _logHandler = logHandler ? (void (^)(NSString *))[logHandler copy] : ^(NSString *line) {};
    _conflictedPathsByRepo = [NSMutableDictionary dictionary];
  }
  return self;
}

- (NSArray<NSString *> *)conflictedPathsForRepositoryNamed:(NSString *)name
{
  return _conflictedPathsByRepo[name] ?: @[];
}

// Runs a shell command, logging it and its output the same way SWGitTool
// does for git, so both appear in the Log window in arrival order.
- (int)runCommand:(NSString *)launchPath
         arguments:(NSArray<NSString *> *)args
       environment:(NSDictionary *)extraEnv
{
  _logHandler([NSString stringWithFormat:@"# %@ %@", launchPath, [args componentsJoinedByString:@" "]]);

  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:launchPath];
  [task setArguments:args];
  // install-system-domain.sh sources "./Library/Scripts/functions.sh" -
  // relative to the CURRENT DIRECTORY, not to the script's own location - so
  // it only works when launched from gershwin-developer's checkout root,
  // exactly as "make" has always run it. NSTask otherwise inherits whatever
  // cwd the privileged helper process happened to start with, which is not
  // guaranteed to be this at all.
  [task setCurrentDirectoryPath:_developerRoot];
  if (extraEnv) {
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env addEntriesFromDictionary:extraEnv];
    [task setEnvironment:env];
  }

  NSPipe *pipe = [NSPipe pipe];
  [task setStandardOutput:pipe];
  [task setStandardError:pipe];

  @try {
    [task launch];
  } @catch (NSException *exception) {
    _logHandler([NSString stringWithFormat:@"could not start %@: %@", launchPath, [exception reason]]);
    return -1;
  }

  NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
  [task waitUntilExit];
  NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
  for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
    if ([line length] > 0) _logHandler(line);
  }
  return [task terminationStatus];
}

- (SWRepositoryUpdateOutcome)updateRepository:(SWRepository *)repository
                                  targetBranch:(NSString *)targetBranch
                                    stepHandler:(void (^)(NSString *))stepHandler
{
  NSString *name = [repository name];
  NSString *path = [_sourcesDirectory stringByAppendingPathComponent:name];
  SWGitTool *git = [[SWGitTool alloc] initWithRepositoryPath:path];
  [git setLogHandler:^(NSString *line) { self->_logHandler(line); }];

  NSString *oldHead = [git headCommit];
  BOOL stashed = NO;

  // 1. Stash
  if ([git modifiedFileCount] > 0) {
    if (stepHandler) stepHandler([NSString stringWithFormat:@"Stashing changes in %@", name]);
    NSString *message = [NSString stringWithFormat:@"Software Update %@", [NSDate date]];
    stashed = [git stashPushWithMessage:message];
  }

  // 2. Check out
  if (stepHandler) stepHandler([NSString stringWithFormat:@"Checking out %@", name]);
  BOOL checkedOut;
  if ([repository isPinned]) {
    checkedOut = [git checkoutRef:[repository pin]];
  } else if (targetBranch) {
    checkedOut = [git switchAndFastForwardTo:targetBranch];
  } else {
    // No target branch could be determined for a non-pinned repository (e.g.
    // the checking phase could not resolve origin's default branch) - treat
    // it the same as an unreachable checkout rather than handing nil into
    // an Objective-C array literal, which raises instead of failing cleanly.
    _logHandler([NSString stringWithFormat:@"No target branch known for %@; skipping", name]);
    checkedOut = NO;
  }
  if (!checkedOut) {
    if (stashed) [git stashPop];
    return SWRepositoryUpdateOutcomeDiverged;
  }

  // 3. Patches (only if a patch set exists for this repository)
  BOOL patchesApplied = NO;
  NSString *patchesDir = [[[_sourcesDirectory stringByDeletingLastPathComponent]
    stringByAppendingPathComponent:@"Patches"] stringByAppendingPathComponent:name];
  if ([[NSFileManager defaultManager] fileExistsAtPath:patchesDir]) {
    patchesApplied = YES;
    if (stepHandler) stepHandler([NSString stringWithFormat:@"Patching %@", name]);
    NSString *patchScript = [[_installScriptPath stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:@"patch.sh"];
    int status = [self runCommand:@"/bin/sh" arguments:@[patchScript, name] environment:nil];
    if (status != 0) {
      [git checkoutRef:oldHead];
      if (stashed) [git stashPop];
      return SWRepositoryUpdateOutcomeBuildFailed;
    }
  }

  // 4. Build
  if (stepHandler) stepHandler([NSString stringWithFormat:@"Building %@", name]);
  int buildStatus = [self runCommand:@"/bin/sh"
                            arguments:@[_installScriptPath, @"build-repo", name]
                          environment:@{@"FROM_MAKEFILE": @"1"}];
  if (buildStatus != 0) {
    [git checkoutRef:oldHead];
    if (stashed) [git stashPop];
    return SWRepositoryUpdateOutcomeBuildFailed;
  }

  // 5. Install
  if (stepHandler) stepHandler([NSString stringWithFormat:@"Installing %@", name]);
  int installStatus = [self runCommand:@"/bin/sh"
                              arguments:@[_installScriptPath, @"install-repo", name]
                            environment:@{@"FROM_MAKEFILE": @"1"}];
  if (installStatus != 0) {
    [git checkoutRef:oldHead];
    if (stashed) [git stashPop];
    return SWRepositoryUpdateOutcomeInstallFailed;
  }

  // 6. Re-apply the user's own local changes. The patch step above left its
  // own uncommitted edits in the working tree; those must come out first, or
  // popping the stash sees them as a conflicting local change and merges
  // against them instead of against a clean checkout.
  if (patchesApplied) {
    [git discardTrackedChanges];
  }
  if (stashed) {
    if (stepHandler) stepHandler([NSString stringWithFormat:@"Re-applying changes in %@", name]);
    if (![git stashPop]) {
      // Conflict: leave a clean tree and report it. The stash is never
      // dropped, so nothing the user had is lost.
      _conflictedPathsByRepo[name] = [git conflictedPaths];
      [git resetMerge];
      return SWRepositoryUpdateOutcomeStashKept;
    }
  }

  return SWRepositoryUpdateOutcomeUpdated;
}

@end
