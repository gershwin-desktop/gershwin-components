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

// Reads a pipe to EOF, handing out one line at a time as each newline
// arrives, and returns once the write end is closed. Deliberately not
// -readDataToEndOfFile: that buffers the whole stream before a single line
// is logged, which for a build means the Log window shows one command line and
// then nothing until the very end - the run looks hung while gmake is happily
// working. It also risks a deadlock: stdout and stderr share one pipe, so once
// its buffer (64 KiB on Linux) fills, a child blocked in write() cannot exit
// and the parent blocked reading can never see the EOF it is waiting for.
// Neither side ever moves again.
//
// A line with no newline in it yet is held back until one arrives (or until
// the stream ends), so a partial line is never logged as if it were complete.
static void SWDrainPipe(NSFileHandle *handle, void (^emit)(NSString *line))
{
  NSMutableString *pending = [NSMutableString string];
  while (YES) {
    NSData *chunk = nil;
    @try {
      chunk = [handle availableData];
    } @catch (NSException *exception) {
      break; // the handle was closed underneath us; treat as end of stream
    }
    if ([chunk length] == 0) break; // EOF

    NSString *text = [[NSString alloc] initWithData:chunk encoding:NSUTF8StringEncoding];
    if (!text) {
      // Not valid UTF-8 (a compiler diagnostic can contain raw bytes). Keep
      // the bytes rather than dropping the output.
      text = [[NSString alloc] initWithData:chunk encoding:NSISOLatin1StringEncoding];
    }
    if (!text) break;
    [pending appendString:text];

    NSRange newline;
    while ((newline = [pending rangeOfString:@"\n"]).location != NSNotFound) {
      NSString *line = [pending substringToIndex:newline.location];
      [pending deleteCharactersInRange:NSMakeRange(0, newline.location + 1)];
      line = [line stringByTrimmingCharactersInSet:
               [NSCharacterSet characterSetWithCharactersInString:@"\r"]];
      if ([line length] > 0) emit(line);
    }
  }

  // Whatever was left had no trailing newline: still worth showing.
  NSString *tail = [pending stringByTrimmingCharactersInSet:
                     [NSCharacterSet characterSetWithCharactersInString:@"\r"]];
  if ([tail length] > 0) emit(tail);
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

  // Read on a background thread and wait for it here. The child is free to
  // fill the pipe while this thread drains it, so neither side can wedge, and
  // every line is logged as it appears rather than at the end. The drain is
  // joined before returning, so the caller still sees this command's output
  // complete before it starts the next one.
  NSFileHandle *handle = [pipe fileHandleForReading];
  __block BOOL drained = NO;
  NSThread *reader = [[NSThread alloc] initWithBlock:^{
    SWDrainPipe(handle, ^(NSString *line) {
      self->_logHandler(line);
    });
    drained = YES;
  }];
  [reader setName:@"SWRepositoryUpdater.output"];
  [reader start];
  [task waitUntilExit];

  // The reader normally finishes as soon as the child closes the pipe, which
  // is just before waitUntilExit returns. Give it a bounded grace period in
  // case the last read is still in flight, so a slow final line is not lost.
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
  while (!drained && [deadline timeIntervalSinceNow] > 0) {
    [NSThread sleepForTimeInterval:0.01];
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
  if (![self applyPatchesForRepositoryNamed:name stepHandler:stepHandler]) {
    [git checkoutRef:oldHead];
    if (stashed) [git stashPop];
    return SWRepositoryUpdateOutcomeBuildFailed;
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

  // 6. Re-apply the user's own local changes.
  //
  // The working tree has to be back to exactly what was checked out before
  // the stash is popped, and two earlier steps leave tracked modifications
  // behind. The patch step edits files in place. The build step regenerates
  // tracked files of its own: gnustep-make runs autoreconf/configure per
  // subdirectory, so `configure` and `config.h.in` come back rewritten (a
  // newer autoconf stamps a new version line into `configure`, and autoheader
  // adds entries for headers the checkout now uses).
  //
  // Popping a stash on top of either of those makes git merge against the
  // leftovers rather than against a clean checkout, and it reports that as a
  // conflict. That is not a real conflict and it recurs forever: the failed
  // pop is followed by `reset --merge`, which only unwinds unmerged paths and
  // leaves the regenerated files dirty, so the next run stashes them again,
  // builds, and conflicts again - while the user's real work is left sitting
  // in a stash that never gets applied.
  //
  // So this is unconditional, not just after a patch: whatever the tree holds
  // at this point is a by-product of the checkout we just did, and the user's
  // own edits are safe in the stash, which is only dropped once the pop has
  // actually succeeded. Only tracked files are reverted, so untracked and
  // ignored files (build products, downloaded fixtures) are left alone.
  [git discardTrackedChanges];
  if (stashed) {
    if (stepHandler) stepHandler([NSString stringWithFormat:@"Re-applying changes in %@", name]);
    if (![git stashPop]) {
      // Conflict: leave a clean tree and report it. The stash is never
      // dropped, so nothing the user had is lost.
      _conflictedPathsByRepo[name] = [git conflictedPaths];
      [git resetMerge];
      // reset --merge only unwinds unmerged paths. The build's regenerated
      // files are merely modified, so they would survive it and leave the tree
      // dirty - which is what made this repeat on every run. Clear them, so
      // the next run starts from a clean checkout and the loop ends.
      [git discardTrackedChanges];
      return SWRepositoryUpdateOutcomeStashKept;
    }
  }

  return SWRepositoryUpdateOutcomeUpdated;
}

// Path to the patch set for a repository: <developer>/Library/Patches/<name>,
// or nil when that repository ships none. A directory that exists but is empty
// still counts - patch.sh's "already applied" check is what keeps re-running it
// harmless, so the presence of the directory is the right test, and it is the
// same test the update path has always used.
- (NSString *)patchesDirectoryForRepositoryNamed:(NSString *)name
{
  NSString *patchesDir = [[[_sourcesDirectory stringByDeletingLastPathComponent]
    stringByAppendingPathComponent:@"Patches"] stringByAppendingPathComponent:name];
  if ([[NSFileManager defaultManager] fileExistsAtPath:patchesDir]) return patchesDir;
  return nil;
}

// Runs Library/Scripts/patch.sh for one repository, unless it has no patch set.
// patch.sh is idempotent by design: it reverse-dry-runs each patch first and
// counts it as already applied when every hunk is present, so calling it on an
// already-patched tree changes nothing and still exits 0. That is what makes it
// safe to run unconditionally before every build, which is what a rebuild has
// to do - see -rebuildRepository:stepHandler:.
- (BOOL)applyPatchesForRepositoryNamed:(NSString *)name
                            stepHandler:(void (^)(NSString *stepVerb))stepHandler
{
  if (![self patchesDirectoryForRepositoryNamed:name]) return YES; // nothing to do

  if (stepHandler) stepHandler([NSString stringWithFormat:@"Patching %@", name]);
  NSString *patchScript = [[_installScriptPath stringByDeletingLastPathComponent]
    stringByAppendingPathComponent:@"patch.sh"];
  return [self runCommand:@"/bin/sh" arguments:@[patchScript, name] environment:nil] == 0;
}

// Compile and install what is already checked out. See the header for why this
// is a separate method rather than a flag on -updateRepository:.
- (SWRepositoryUpdateOutcome)rebuildRepository:(SWRepository *)repository
                                   stepHandler:(void (^)(NSString *stepVerb))stepHandler
{
  NSString *name = [repository name];

  // Patches first, exactly as the update path does. This is not an optional
  // extra: the Gershwin tree does not build vanilla. libs-gui alone carries 20
  // patches (view-redraw-scale-factor, submenu-precedence, scrollview autohide
  // subpixel, and so on), and building without them produces a libs-gui that
  // compiles but misbehaves at a fractional scale factor and in the menu bar.
  // Rebuilding from a tree whose patches had been dropped would silently
  // install a broken system - worse than not rebuilding at all.
  //
  // The patches are applied to the working tree, so the build below compiles
  // the patched sources; the tree is then left patched, which is also the
  // state checkout.sh and a normal update leave it in. patch.sh skipping the
  // ones already present means a second rebuild does not double-apply them.
  if (![self applyPatchesForRepositoryNamed:name stepHandler:stepHandler]) {
    return SWRepositoryUpdateOutcomeBuildFailed;
  }

  // No rollback target and nothing to restore: unlike the update path there is
  // no old commit to go back to and no stash to pop, so a failure is simply
  // reported. The working copy is left exactly as the build left it.
  if (stepHandler) stepHandler([NSString stringWithFormat:@"Building %@", name]);
  int buildStatus = [self runCommand:@"/bin/sh"
                            arguments:@[_installScriptPath, @"build-repo", name]
                          environment:@{@"FROM_MAKEFILE": @"1"}];
  if (buildStatus != 0) return SWRepositoryUpdateOutcomeBuildFailed;

  if (stepHandler) stepHandler([NSString stringWithFormat:@"Installing %@", name]);
  int installStatus = [self runCommand:@"/bin/sh"
                              arguments:@[_installScriptPath, @"install-repo", name]
                            environment:@{@"FROM_MAKEFILE": @"1"}];
  if (installStatus != 0) return SWRepositoryUpdateOutcomeInstallFailed;

  return SWRepositoryUpdateOutcomeUpdated;
}

@end
