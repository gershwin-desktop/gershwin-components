/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWGitTool.h"

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
// in arrival order, and handed back so callers can parse them.
- (int)runGit:(NSArray<NSString *> *)args output:(NSString **)outOutput
{
  NSMutableArray *fullArgs = [NSMutableArray arrayWithObjects:@"-C", _path, nil];
  [fullArgs addObjectsFromArray:args];

  if (_logHandler) {
    _logHandler([NSString stringWithFormat:@"$ git %@", [fullArgs componentsJoinedByString:@" "]]);
  }

  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:@"/usr/bin/env"];
  [task setArguments:[@[@"git"] arrayByAddingObjectsFromArray:fullArgs]];

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
