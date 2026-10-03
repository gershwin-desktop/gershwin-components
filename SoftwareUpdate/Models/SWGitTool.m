/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWGitTool.h"
#import <PackageManager/GWSudoHelper.h>
#include <ctype.h>
#include <dirent.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// The same askpass the privileged update run uses (SWAppDelegate): every
// elevated git call runs without a terminal of its own, so sudo's password
// has to come from a helper that can show a window.
static NSString *const kSudoAskPassPath = @"/System/Library/Tools/SudoAskPass";
static NSString *const kAskpassRequester = @"Software Update";

// Gives a task the environment sudo needs to ask for a password without a
// terminal. Only elevated runs get it; plain git keeps the environment it
// has today.
static void SWUseSudoEnvironment(NSTask *task)
{
  NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
  [env setObject:kSudoAskPassPath forKey:@"SUDO_ASKPASS"];
  [env setObject:kAskpassRequester forKey:@"ASKPASS_REQUESTER"];
  [task setEnvironment:env];
}

// Runs `sudo` with exactly these arguments (the caller assembles the flags
// it needs - sudo does not accept every flag next to every action),
// stdout+stderr combined. Returns the exit status, or -1 when sudo itself
// could not be started.
static int SWRunSudo(NSArray<NSString *> *args, NSString **outOutput)
{
  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:GWSudoPath()];
  [task setArguments:args];
  SWUseSudoEnvironment(task);

  NSPipe *pipe = [NSPipe pipe];
  [task setStandardOutput:pipe];
  [task setStandardError:pipe];

  @try {
    [task launch];
  } @catch (NSException *exception) {
    if (outOutput) {
      *outOutput = [NSString stringWithFormat:@"sudo could not be started: %@",
        [exception reason] ?: @"unknown error"];
    }
    return -1;
  }

  NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
  [task waitUntilExit];
  if (outOutput) {
    *outOutput = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
  }
  return [task terminationStatus];
}

// The directory displaced files are moved into, relative to the repository
// root. Inside .git, not beside the file: nothing in the working tree can
// mistake it for a checkout, no build sees it, and none of the git commands
// this class runs to clean up after itself - `checkout -- .`, `reset --merge` -
// can reach it.
static NSString *const kSetAsideDirectoryName = @"software-update-aside";

// Removes <path>, then any directories above it that this left empty, up to
// but not including <root> - which is removed too if that empties it. A
// set-aside directory with nothing left in it is what a clean run should leave
// behind, not one that grows a subdirectory per displaced file and stays for
// ever. Nothing above <root> is ever touched.
static void SWPruneEmptyDirectories(NSString *root, NSString *path)
{
  NSString *prefix = [root stringByAppendingString:@"/"];
  NSString *dir = [path stringByDeletingLastPathComponent];
  while (![dir isEqualToString:root] && [dir hasPrefix:prefix]) {
    // rmdir(2), not -removeItemAtPath:. A GNUstep -removeItemAtPath: on a
    // directory deletes its contents recursively - it is rm -rf - so pruning
    // what are meant to be empty directories with it destroys exactly the
    // copies still being kept for the user, the first time a redundant copy
    // and a kept one happen to share a subdirectory. rmdir fails on a
    // directory that still holds anything, which is the stop condition wanted.
    if (rmdir([dir fileSystemRepresentation]) != 0) return;
    dir = [dir stringByDeletingLastPathComponent];
  }
  rmdir([root fileSystemRepresentation]);
}

// YES when path exists and belongs to somebody other than runAs - the exact
// condition git's ownership check fails on, judged with lstat like git does.
static BOOL SWOwnedByOtherUser(NSString *path, uid_t runAs)
{
  if ([path length] == 0) return NO;
  struct stat st;
  return lstat([path fileSystemRepresentation], &st) == 0 &&
         (uid_t)st.st_uid != runAs;
}

// YES when this path exists and this user may not write it as themselves -
// either somebody else owns it, or the mode forbids it. lstat and access(),
// which is what git itself uses. An absent path is NO: git states the real
// problem itself, in its own words.
//
// Search permission is only asked of directories. Asking it of a file asks
// whether the file is executable, and .git/packed-refs is an ordinary 0644
// file - so demanding X_OK there reports every healthy repository as
// unusable, sends every git call through sudo, and the object database that
// root then writes comes back root-owned. That is the very condition this
// function exists to route around, manufactured by the check itself.
static BOOL SWNeedsWriteAccess(NSString *path)
{
  if ([path length] == 0) return NO;
  struct stat st;
  const char *fsPath = [path fileSystemRepresentation];
  if (lstat(fsPath, &st) != 0) return NO;
  if ((uid_t)st.st_uid != geteuid()) return YES;
  if (access(fsPath, W_OK) != 0) return YES;
  return S_ISDIR(st.st_mode) && access(fsPath, X_OK) != 0;
}

// git stores a loose object in .git/objects/<xx>, where <xx> is the first two
// hex digits of its sha - and it reuses that directory when one already
// exists rather than creating a new one. So a single directory left behind by
// a git that ran as root is enough to break every later unprivileged fetch:
//
//   error: insufficient permission for adding an object to repository
//   database .git/objects
//   fatal: failed to write object
//   fatal: unpack-objects failed
//
// and because the objects never land, the remote-tracking ref is never
// advanced either - which is what made a check read "HEAD..origin/dev is
// empty", i.e. no updates, on a repository that was plainly behind. Every
// existing two-hex-digit directory is therefore inspected, not just .git.
static BOOL SWObjectsDirNeedsWriteAccess(NSString *objectsDir)
{
  // An absent object database is nothing to escalate for: there is no
  // database to write into, and git states the real problem itself. Checked
  // first, because the "cannot read it" case below would otherwise turn every
  // path that is not a repository at all into one that needs sudo.
  struct stat st;
  if (lstat([objectsDir fileSystemRepresentation], &st) != 0) return NO;
  if (SWNeedsWriteAccess(objectsDir)) return YES;
  if (SWNeedsWriteAccess([objectsDir stringByAppendingPathComponent:@"pack"])) return YES;

  DIR *dir = opendir([objectsDir fileSystemRepresentation]);
  if (!dir) return YES;   // exists but unreadable: certainly not writable
  BOOL needsElevation = NO;
  struct dirent *entry = NULL;
  while (!needsElevation && (entry = readdir(dir)) != NULL) {
    const char *name = entry->d_name;
    if (strlen(name) != 2) continue;
    if (!isxdigit((unsigned char)name[0]) || !isxdigit((unsigned char)name[1])) continue;
    if (SWNeedsWriteAccess([objectsDir stringByAppendingPathComponent:
                             [NSString stringWithUTF8String:name]])) {
      needsElevation = YES;
    }
  }
  closedir(dir);
  return needsElevation;
}

// YES when git's own checks would refuse this path: it belongs to another
// user, or this user may not write to it. Judged with lstat and access on
// everything a fetch, a checkout or a stash has to write - the worktree, its
// .git directory, the objects database and the refs - and not merely the two
// paths at the top, because "the repository is mine" says nothing about
// whether the object database inside it is.
// Absent paths are not escalated for: git states the real problem itself.
static BOOL SWPathNeedsElevation(NSString *path)
{
  if ([path length] == 0) return NO;
  NSString *gitDir = [path stringByAppendingPathComponent:@".git"];
  if (SWNeedsWriteAccess(path) || SWNeedsWriteAccess(gitDir)) return YES;
  if (SWObjectsDirNeedsWriteAccess([gitDir stringByAppendingPathComponent:@"objects"])) return YES;
  if (SWNeedsWriteAccess([gitDir stringByAppendingPathComponent:@"refs"])) return YES;
  if (SWNeedsWriteAccess([gitDir stringByAppendingPathComponent:@"packed-refs"])) return YES;
  return NO;
}

@implementation SWGitCommit
@synthesize sha = _sha, subject = _subject, date = _date;
@end

@interface SWGitTool ()
{
  NSString *_path;
  NSArray<NSString *> *_lastConflictedPaths;
}
@end

@implementation SWGitTool

@synthesize logHandler = _logHandler;

+ (BOOL)needsElevationForPath:(NSString *)path
{
  if (geteuid() == 0) return NO; // already privileged: the update run
  return SWPathNeedsElevation(path);
}

+ (BOOL)prepareElevationForPaths:(NSArray<NSString *> *)paths
                      logHandler:(SWGitLogLine)logHandler
                          reason:(NSString **)outReason
{
  // The ordinary case (this user owns /Developer): nothing to ask for, so a
  // normal launch never shows a password prompt just for checking.
  NSString *blocked = nil;
  for (NSString *path in paths) {
    if ([self needsElevationForPath:path]) { blocked = path; break; }
  }
  if (!blocked) return YES;

  // One `sudo -v` for the whole process: it both asks for the password once
  // and leaves a validated timestamp every later sudo'd git call reuses, so
  // the six parallel fetches cannot race each other into six prompts. -v
  // takes no command, and sudo rejects -E ("preserve the environment")
  // without one, so only the askpass flag travels with it.
  NSMutableArray<NSString *> *validate = [NSMutableArray array];
  for (NSString *flag in GWSudoArgPrefix()) {
    if (![flag isEqualToString:@"-E"]) [validate addObject:flag];
  }
  [validate addObject:@"-v"];

  if (logHandler) {
    logHandler([NSString stringWithFormat:@"$ %@ %@", GWSudoPath(),
      [validate componentsJoinedByString:@" "]]);
  }
  NSString *output = nil;
  int status = SWRunSudo(validate, &output);
  if (logHandler) {
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
      if ([line length] > 0) logHandler(line);
    }
  }
  if (status == 0) return YES;

  if (outReason) {
    // Only the first line: sudo's own diagnostics (no askpass program, no
    // password provided, not in sudoers) land there, in whatever language
    // the system speaks - never parsed, only quoted back to the user.
    NSString *detail = nil;
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
      NSString *trimmed = [line stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if ([trimmed length] > 0) { detail = trimmed; break; }
    }
    NSMutableString *reason = [NSMutableString stringWithFormat:
      @"Software Update can't update %@ with your own permissions, so it has to run git "
       "there as administrator. That permission was not granted.", blocked];
    if ([detail length] > 0) [reason appendFormat:@" (%@)", detail];
    [reason appendString:@" Try again and enter your administrator password when asked."];
    *outReason = [reason copy];
  }
  return NO;
}

- (instancetype)initWithRepositoryPath:(NSString *)path
{
  self = [super init];
  if (self) {
    _path = [path copy];
    _lastConflictedPaths = @[];
  }
  return self;
}

// Runs `git <args>` synchronously, feeding the command line and every output
// line to -logHandler. Returns the exit status; stdout/stderr are combined,
// in arrival order, and handed back so callers can parse them. Repositories
// this user may not use are run through sudo, and git's ownership check is
// answered for that one path (root does not own it either).
- (int)runGit:(NSArray<NSString *> *)args output:(NSString **)outOutput
{
  BOOL escalate = [[self class] needsElevationForPath:_path];

  // git refuses a repository owned by somebody else - and once the command
  // runs as root, that somebody is still not us, so the exemption has to be
  // stated rather than assumed. Command-line config counts as protected
  // configuration, which is exactly what git insists on for safe.directory,
  // so the exemption is honoured even from root.
  uid_t runAs = escalate ? 0 : geteuid();
  BOOL ownershipRefused = SWOwnedByOtherUser(_path, runAs);

  NSMutableArray *fullArgs = [NSMutableArray array];
  if (ownershipRefused) {
    [fullArgs addObjectsFromArray:@[@"-c",
      [NSString stringWithFormat:@"safe.directory=%@", _path]]];
  }
  [fullArgs addObject:@"-C"];
  [fullArgs addObject:_path];
  [fullArgs addObjectsFromArray:args];

  // argv as it actually runs: through sudo when the repository is not ours,
  // otherwise straight through env so "git" is still found on PATH (the same
  // shape as before, on Linux and on the BSDs alike).
  NSArray<NSString *> *sudoPrefix = escalate ? GWSudoArgPrefix() : @[];
  NSMutableArray *argv = [NSMutableArray array];
  NSString *launchPath;
  if ([sudoPrefix count] > 0) {
    launchPath = GWSudoPath();
    [argv addObjectsFromArray:sudoPrefix];
  } else {
    launchPath = @"/usr/bin/env"; // NSTask resolves "git" through PATH
  }
  [argv addObject:@"git"];
  [argv addObjectsFromArray:fullArgs];

  // The Log window gets that command line too, sudo flags included, so a
  // run that needed permission says so ("$" for a user-level invocation).
  if (_logHandler) {
    NSMutableArray *display = [NSMutableArray array];
    if ([sudoPrefix count] > 0) [display addObject:launchPath];
    [display addObjectsFromArray:argv];
    _logHandler([NSString stringWithFormat:@"$ %@%@", [self logTag],
      [display componentsJoinedByString:@" "]]);
  }

  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:launchPath];
  [task setArguments:argv];
  if ([sudoPrefix count] > 0) SWUseSudoEnvironment(task);

  NSPipe *pipe = [NSPipe pipe];
  [task setStandardOutput:pipe];
  [task setStandardError:pipe];

  NSMutableString *collected = [NSMutableString string];
  NSFileHandle *readHandle = [pipe fileHandleForReading];

  @try {
    [task launch];
  } @catch (NSException *exception) {
    if (_logHandler) {
      _logHandler([NSString stringWithFormat:@"%@git could not be started: %@",
        [self logTag], [exception reason]]);
    }
    if (outOutput) *outOutput = @"";
    return -1;
  }

  NSData *data = [readHandle readDataToEndOfFile];
  [task waitUntilExit];

  NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
  [collected appendString:text];

  if (_logHandler) {
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
      if ([line length] > 0) _logHandler([self logTagForOutputLine:line]);
    }
  }

  if (outOutput) *outOutput = [collected copy];
  return [task terminationStatus];
}

// Every logged line carries the repository it came from, in the same order the
// fetches fan out. Without it a failure is unattributable: the check runs up
// to six repositories at once through one log, so a bare "fatal: unpack-objects
// failed" could have come from any of them, and reading the log to find out
// which meant guessing from the surrounding lines.
- (NSString *)logTag
{
  NSString *name = [[_path lastPathComponent] copy];
  return [NSString stringWithFormat:@"[%@] ", [name length] > 0 ? name : @"?"];
}

- (NSString *)logTagForOutputLine:(NSString *)line
{
  return [NSString stringWithFormat:@"%@%@", [self logTag], line];
}

// git's own first line of complaint, with its severity prefix and trailing
// punctuation left alone: it names the actual problem ("insufficient
// permission for adding an object to repository database .git/objects",
// "Could not resolve host: github.com") in a form no paraphrase of ours
// would be as precise as. Capped, because this ends up in a table row.
static NSString *SWFirstErrorLine(NSString *output)
{
  for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed length] == 0) continue;
    if ([trimmed length] > 140) {
      return [[trimmed substringToIndex:139] stringByAppendingString:@"…"];
    }
    return trimmed;
  }
  return nil;
}

- (BOOL)fetchPruneOrigin:(NSString **)outError
{
  NSString *output = nil;
  if ([self runGit:@[@"fetch", @"--prune", @"origin"] output:&output] == 0) return YES;
  if (outError) *outError = SWFirstErrorLine(output);
  return NO;
}

- (NSString *)currentBranch
{
  NSString *output = nil;
  int status = [self runGit:@[@"rev-parse", @"--abbrev-ref", @"HEAD"] output:&output];
  if (status != 0) return nil;
  NSString *branch = [output stringByTrimmingCharactersInSet:
    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return [branch isEqualToString:@"HEAD"] ? nil : branch; // "HEAD" = detached
}

- (BOOL)remoteHasBranch:(NSString *)branch
{
  return [self runGit:@[@"ls-remote", @"--exit-code", @"--heads", @"origin", branch] output:NULL] == 0;
}

- (NSUInteger)commitCountBehindTarget:(NSString *)target
{
  NSString *output = nil;
  NSString *range = [NSString stringWithFormat:@"HEAD..origin/%@", target];
  int status = [self runGit:@[@"rev-list", @"--count", range] output:&output];
  if (status != 0) return 0;
  return (NSUInteger)[[output stringByTrimmingCharactersInSet:
    [NSCharacterSet whitespaceAndNewlineCharacterSet]] integerValue];
}

- (NSArray<SWGitCommit *> *)commitsBehindTarget:(NSString *)target
{
  NSString *output = nil;
  NSString *range = [NSString stringWithFormat:@"HEAD..origin/%@", target];
  int status = [self runGit:@[@"log", @"--format=%h%x09%s%x09%as", range] output:&output];
  if (status != 0 || [output length] == 0) return @[];

  NSMutableArray *commits = [NSMutableArray array];
  for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
    if ([line length] == 0) continue;
    NSArray *fields = [line componentsSeparatedByString:@"\t"];
    if ([fields count] < 3) continue;
    SWGitCommit *commit = [[SWGitCommit alloc] init];
    [commit setSha:fields[0]];
    [commit setSubject:fields[1]];
    [commit setDate:fields[2]];
    [commits addObject:commit];
  }
  return [commits copy];
}

- (NSUInteger)modifiedFileCount
{
  NSString *output = nil;
  int status = [self runGit:@[@"status", @"--porcelain", @"--untracked-files=no"] output:&output];
  if (status != 0 || [output length] == 0) return 0;

  NSUInteger count = 0;
  for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
    if ([line length] > 0) count++;
  }
  return count;
}

- (BOOL)stashPushWithMessage:(NSString *)message
{
  return [self runGit:@[@"stash", @"push", @"-m", message] output:NULL] == 0;
}

- (BOOL)stashPop
{
  NSString *output = nil;
  int status = [self runGit:@[@"stash", @"pop"] output:&output];
  if (status == 0) {
    _lastConflictedPaths = @[];
    return YES;
  }

  NSString *conflictOutput = nil;
  [self runGit:@[@"diff", @"--name-only", @"--diff-filter=U"] output:&conflictOutput];
  NSMutableArray *paths = [NSMutableArray array];
  for (NSString *line in [conflictOutput componentsSeparatedByString:@"\n"]) {
    if ([line length] > 0) [paths addObject:line];
  }
  _lastConflictedPaths = [paths copy];
  return NO;
}

- (NSArray<NSString *> *)conflictedPaths
{
  return _lastConflictedPaths;
}

- (BOOL)resetMerge
{
  return [self runGit:@[@"reset", @"--merge"] output:NULL] == 0;
}

- (BOOL)discardTrackedChanges
{
  return [self runGit:@[@"checkout", @"--", @"."] output:NULL] == 0;
}

- (BOOL)switchAndFastForwardTo:(NSString *)branch
{
  int switchStatus = [self runGit:@[@"switch", branch] output:NULL];
  if (switchStatus != 0) {
    // No local branch yet: create one tracking origin/<branch>.
    switchStatus = [self runGit:@[@"switch", @"-c", branch, @"--track",
                                   [NSString stringWithFormat:@"origin/%@", branch]]
                          output:NULL];
    if (switchStatus == 0) return YES; // freshly created tracking branch is already at the tip
  }
  if (switchStatus != 0) return NO;

  NSString *target = [NSString stringWithFormat:@"origin/%@", branch];
  return [self runGit:@[@"merge", @"--ff-only", target] output:NULL] == 0;
}

- (NSArray<NSString *> *)untrackedPathsBlockingFastForwardTo:(NSString *)target
{
  // The paths the incoming commits create, not the paths they change: a path
  // HEAD already holds is tracked in the working tree, so only a path HEAD does
  // not have can be something untracked sitting in the way. --no-renames makes
  // a rename report as a delete plus an add, so the file's new name is included
  // - with rename detection on it would be reported as a rename and filtered
  // out, and that move would go on blocking the update. -z, because a path may
  // contain a newline and git's own porcelain output says to ask for it that
  // way; the list is then split on NUL instead of on lines.
  NSString *output = nil;
  if ([self runGit:@[@"diff", @"--name-only", @"--no-renames", @"--diff-filter=A",
                     @"-z", @"HEAD", [NSString stringWithFormat:@"origin/%@", target]]
               output:&output] != 0) {
    return @[];
  }

  NSFileManager *fm = [NSFileManager defaultManager];
  NSMutableArray *paths = [NSMutableArray array];
  for (NSString *path in [output componentsSeparatedByString:@"\0"]) {
    if ([path length] == 0) continue;
    // Present on disk but absent from HEAD's tree: exactly the state git
    // refuses to overwrite. A directory counts, and counts as one path, which
    // is how git itself reports it.
    if ([fm fileExistsAtPath:[_path stringByAppendingPathComponent:path]]) {
      [paths addObject:path];
    }
  }
  return [paths copy];
}

- (NSString *)setAsideDirectoryPath
{
  return [[_path stringByAppendingPathComponent:@".git"]
    stringByAppendingPathComponent:kSetAsideDirectoryName];
}

- (NSString *)setAsidePathForRelativePath:(NSString *)relativePath
{
  return [[self setAsideDirectoryPath] stringByAppendingPathComponent:relativePath];
}

- (BOOL)setAsideUntrackedPaths:(NSArray<NSString *> *)paths
                      failure:(NSString **)outFailure
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *aside = [self setAsideDirectoryPath];

  for (NSString *path in paths) {
    NSString *from = [_path stringByAppendingPathComponent:path];
    NSString *to = [aside stringByAppendingPathComponent:path];

    // Refuse rather than replace: the copy already sitting here may be the
    // only remaining copy of a file that was moved aside on an earlier run and
    // never put back, and there is no version of overwriting it that is safe.
    if ([fm fileExistsAtPath:to]) {
      if (_logHandler) {
        _logHandler([self logTagForOutputLine:
          [NSString stringWithFormat:@"not moving %@ aside: a copy is already "
            @"kept at %@ - move it out of the way yourself", path, to]]);
      }
      if (outFailure) *outFailure = path;
      return NO;
    }

    NSError *error = nil;
    if (![fm createDirectoryAtPath:[to stringByDeletingLastPathComponent]
        withIntermediateDirectories:YES attributes:nil error:&error]) {
      if (_logHandler) {
        _logHandler([self logTagForOutputLine:
          [NSString stringWithFormat:@"not moving %@ aside: %@", path,
            [error localizedDescription] ?: @"could not create the directory for it"]]);
      }
      if (outFailure) *outFailure = path;
      return NO;
    }

    if (![fm moveItemAtPath:from toPath:to error:&error]) {
      if (_logHandler) {
        _logHandler([self logTagForOutputLine:
          [NSString stringWithFormat:@"not moving %@ aside: %@", path,
            [error localizedDescription] ?: @"the move failed"]]);
      }
      if (outFailure) *outFailure = path;
      return NO;
    }

    if (_logHandler) {
      _logHandler([self logTagForOutputLine:
        [NSString stringWithFormat:@"moved %@ out of the way of the update, to %@ "
          @"(not deleted: the update wants to create that path itself)", path, to]]);
    }
  }
  return YES;
}

- (NSArray<NSString *> *)reconcileSetAsidePaths:(NSArray<NSString *> *)paths
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *aside = [self setAsideDirectoryPath];
  NSMutableArray *kept = [NSMutableArray array];

  for (NSString *path in paths) {
    NSString *copy = [aside stringByAppendingPathComponent:path];
    NSString *checkedOut = [_path stringByAppendingPathComponent:path];

    // Already dealt with on an earlier call: a copy that is not there has
    // nothing to compare and nothing to report, and saying so again would name
    // a file that does not exist.
    if (![fm fileExistsAtPath:copy]) continue;

    NSData *mine = [NSData dataWithContentsOfFile:copy];
    NSData *theirs = [NSData dataWithContentsOfFile:checkedOut];
    BOOL plainFiles = mine != nil && theirs != nil;
    if (plainFiles && [mine isEqualToData:theirs]) {
      // Exactly what the checkout produced: the file had reached the
      // repository by some route other than git, and the update has now
      // brought the same bytes in properly. Keeping the copy would only be
      // clutter for a later run to trip over again.
      [fm removeItemAtPath:copy error:NULL];
      SWPruneEmptyDirectories(aside, copy);
      if (_logHandler) {
        _logHandler([self logTagForOutputLine:
          [NSString stringWithFormat:@"%@ was identical to the file the update "
            @"checked out, so the copy that was moved aside is gone", path]]);
      }
      continue;
    }

    // Either the user's own version of the file, or something that is not a
    // plain file at all - a directory the update would create, a link. Either
    // way it stays where it is and is named, so it can be found and merged
    // back by hand; nothing is ever thrown away.
    [kept addObject:path];
    if (_logHandler) {
      NSString *why = plainFiles
        ? @"your version is not what the update checked out"
        : @"the update did not produce a plain file at that path";
      _logHandler([self logTagForOutputLine:
        [NSString stringWithFormat:@"%@ is kept at %@ - %@", path,
          [self setAsidePathForRelativePath:path], why]]);
    }
  }
  return [kept copy];
}

- (NSArray<NSString *> *)restoreSetAsidePaths:(NSArray<NSString *> *)paths
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *aside = [self setAsideDirectoryPath];
  NSMutableArray *leftBehind = [NSMutableArray array];

  for (NSString *path in paths) {
    NSString *from = [aside stringByAppendingPathComponent:path];
    NSString *to = [_path stringByAppendingPathComponent:path];

    NSError *error = nil;
    // The working tree keeps the path if it already has it. Overwriting a
    // checked-out file with the copy taken from before the update would throw
    // away the version the update chose and hand back a stale one instead.
    if (![fm fileExistsAtPath:to] &&
        [fm createDirectoryAtPath:[to stringByDeletingLastPathComponent]
            withIntermediateDirectories:YES attributes:nil error:&error] &&
        [fm moveItemAtPath:from toPath:to error:&error]) {
      SWPruneEmptyDirectories(aside, from);
      if (_logHandler) {
        _logHandler([self logTagForOutputLine:
          [NSString stringWithFormat:@"put %@ back where it was", path]]);
      }
      continue;
    }

    [leftBehind addObject:path];
    if (_logHandler) {
      _logHandler([self logTagForOutputLine:
        [NSString stringWithFormat:@"%@ could not be put back - the working tree "
          @"has that path now. Your copy is kept at %@", path,
          [self setAsidePathForRelativePath:path]]]);
    }
  }
  return [leftBehind copy];
}

- (BOOL)checkoutRef:(NSString *)ref
{
  return [self runGit:@[@"checkout", ref] output:NULL] == 0;
}

- (NSString *)headCommit
{
  NSString *output = nil;
  int status = [self runGit:@[@"rev-parse", @"HEAD"] output:&output];
  if (status != 0) return nil;
  return [output stringByTrimmingCharactersInSet:
    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSString *)defaultBranch
{
  NSString *output = nil;
  int status = [self runGit:@[@"symbolic-ref", @"--short", @"refs/remotes/origin/HEAD"] output:&output];
  if (status != 0) {
    // Not recorded yet (e.g. an older clone) - ask origin once and retry.
    [self runGit:@[@"remote", @"set-head", @"origin", @"-a"] output:NULL];
    status = [self runGit:@[@"symbolic-ref", @"--short", @"refs/remotes/origin/HEAD"] output:&output];
    if (status != 0) return nil;
  }
  NSString *ref = [output stringByTrimmingCharactersInSet:
    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSString *prefix = @"origin/";
  return [ref hasPrefix:prefix] ? [ref substringFromIndex:[prefix length]] : ref;
}

- (NSData *)showFileAtRef:(NSString *)ref path:(NSString *)path
{
  NSString *spec = [NSString stringWithFormat:@"%@:%@", ref, path];
  NSString *output = nil;
  int status = [self runGit:@[@"show", spec] output:&output];
  if (status != 0) return nil;
  return [output dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSString *)fullShaForRef:(NSString *)ref
{
  NSString *output = nil;
  NSString *commitRef = [ref stringByAppendingString:@"^{commit}"];
  int status = [self runGit:@[@"rev-parse", commitRef] output:&output];
  if (status != 0) return nil;
  return [output stringByTrimmingCharactersInSet:
    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

@end
