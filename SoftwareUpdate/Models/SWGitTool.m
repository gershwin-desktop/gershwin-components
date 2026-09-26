/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWGitTool.h"
#import <PackageManager/GWSudoHelper.h>
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

// YES when path exists and belongs to somebody other than runAs - the exact
// condition git's ownership check fails on, judged with lstat like git does.
static BOOL SWOwnedByOtherUser(NSString *path, uid_t runAs)
{
  if ([path length] == 0) return NO;
  struct stat st;
  return lstat([path fileSystemRepresentation], &st) == 0 &&
         (uid_t)st.st_uid != runAs;
}

// YES when git's own checks would refuse this path: it belongs to another
// user, or this user may not write to it. Judged with lstat and access on
// the worktree and its .git directory, which is what git itself inspects -
// and it has to write both to record a fetch, a checkout or a stash.
// Absent paths are not escalated for: git states the real problem itself.
static BOOL SWPathNeedsElevation(NSString *path)
{
  if ([path length] == 0) return NO;
  for (NSString *candidate in @[path, [path stringByAppendingPathComponent:@".git"]]) {
    const char *fsPath = [candidate fileSystemRepresentation];
    struct stat st;
    if (lstat(fsPath, &st) != 0) continue;
    if ((uid_t)st.st_uid != geteuid()) return YES;
    if (access(fsPath, W_OK) != 0) return YES;
  }
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
    _logHandler([NSString stringWithFormat:@"$ %@", [display componentsJoinedByString:@" "]]);
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
      _logHandler([NSString stringWithFormat:@"git could not be started: %@", [exception reason]]);
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
      if ([line length] > 0) _logHandler(line);
    }
  }

  if (outOutput) *outOutput = [collected copy];
  return [task terminationStatus];
}

- (BOOL)fetchPruneOrigin
{
  return [self runGit:@[@"fetch", @"--prune", @"origin"] output:NULL] == 0;
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
