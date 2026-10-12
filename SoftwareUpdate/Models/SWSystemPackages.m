/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWSystemPackages.h"
#include <stdlib.h>
#include <string.h>

NSString *const SWNextBSDRepositoryName = @"NextBSD";
NSString *const SWSystemPackagesPhaseIdentifier = @"nextbsd";

static NSString *const kPkgPath = @"/usr/sbin/pkg";
// Base-system tools rather than curl or a Foundation download: this only runs
// on NextBSD, where both are always there, and bsdtar reads the zstd
// compressed packagesite.pkg without anything else installed.
static NSString *const kFetchPath = @"/usr/bin/fetch";
static NSString *const kTarPath = @"/usr/bin/tar";

@implementation SWSystemPackageUpgrade

- (BOOL)isKernel
{
  return [_name rangeOfString:@"kernel" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

- (NSString *)displayLine
{
  return [NSString stringWithFormat:@"%@ %@ -> %@", _name, _installedVersion, _availableVersion];
}

@end

@implementation SWSystemPackages

+ (NSString *)repositoryURLFromPkgConfiguration:(NSString *)pkgVerboseOutput
                                 repositoryName:(NSString *)name
{
  if (!pkgVerboseOutput || [name length] == 0) return nil;
  NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
  NSString *blockStart = [name stringByAppendingString:@":"];
  BOOL inRepositories = NO, inBlock = NO;

  for (NSString *rawLine in [pkgVerboseOutput componentsSeparatedByString:@"\n"]) {
    NSString *line = [rawLine stringByTrimmingCharactersInSet:ws];
    if (!inRepositories) {
      inRepositories = [line isEqualToString:@"Repositories:"];
      continue;
    }
    if (!inBlock) {
      // "NextBSD: {" - the name must be the whole key, so "Next" does not
      // pick up the NextBSD block.
      if ([line hasPrefix:blockStart] &&
          [[[line substringFromIndex:[blockStart length]] stringByTrimmingCharactersInSet:ws]
            hasPrefix:@"{"]) {
        inBlock = YES;
      }
      continue;
    }
    if ([line hasPrefix:@"}"]) return nil; // the block had no url
    if (![line hasPrefix:@"url"]) continue;

    NSRange open = [line rangeOfString:@"\""];
    if (open.location == NSNotFound) return nil;
    NSString *rest = [line substringFromIndex:NSMaxRange(open)];
    NSRange close = [rest rangeOfString:@"\""];
    if (close.location == NSNotFound) return nil;
    NSString *url = [rest substringToIndex:close.location];
    // pkg+ asks pkg to look the mirror up through SRV records; the host
    // behind it serves the same files over plain https.
    if ([url hasPrefix:@"pkg+"]) url = [url substringFromIndex:4];
    return [url length] > 0 ? url : nil;
  }
  return nil;
}

+ (NSDictionary<NSString *, NSString *> *)packageVersionsFromManifest:(NSString *)manifest
{
  NSMutableDictionary *versions = [NSMutableDictionary dictionary];
  for (NSString *line in [manifest componentsSeparatedByString:@"\n"]) {
    if (![line hasPrefix:@"{"]) continue;
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![object isKindOfClass:[NSDictionary class]]) continue;
    id name = [object objectForKey:@"name"];
    id version = [object objectForKey:@"version"];
    if ([name isKindOfClass:[NSString class]] && [version isKindOfClass:[NSString class]]) {
      [versions setObject:version forKey:name];
    }
  }
  return versions;
}

+ (NSDictionary<NSString *, NSString *> *)installedPackagesFromQueryOutput:(NSString *)output
                                                            repositoryName:(NSString *)name
{
  NSMutableDictionary *installed = [NSMutableDictionary dictionary];
  NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
  for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *field in [line componentsSeparatedByCharactersInSet:ws]) {
      if ([field length] > 0) [fields addObject:field];
    }
    if ([fields count] != 3 || ![fields[0] isEqualToString:name]) continue;
    [installed setObject:fields[2] forKey:fields[1]];
  }
  return installed;
}

+ (NSArray<SWSystemPackageUpgrade *> *)pendingUpgradesForInstalled:(NSDictionary<NSString *, NSString *> *)installed
                                                          available:(NSDictionary<NSString *, NSString *> *)available
                                                         comparator:(SWVersionComparator)comparator
{
  NSMutableArray *pending = [NSMutableArray array];
  for (NSString *name in [[installed allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
    NSString *remote = [available objectForKey:name];
    if (!remote) continue; // no longer in the repository: nothing to upgrade to
    NSString *local = [installed objectForKey:name];
    if (comparator(local, remote) != NSOrderedAscending) continue;

    SWSystemPackageUpgrade *upgrade = [[SWSystemPackageUpgrade alloc] init];
    [upgrade setName:name];
    [upgrade setInstalledVersion:local];
    [upgrade setAvailableVersion:remote];
    [pending addObject:upgrade];
  }
  return pending;
}

+ (BOOL)upgradesRequireRestart:(NSArray<SWSystemPackageUpgrade *> *)upgrades
{
  for (SWSystemPackageUpgrade *upgrade in upgrades) {
    if ([upgrade isKernel]) return YES;
  }
  return NO;
}

@end

static NSString *SWRunCommandForOutput(NSString *launchPath, NSArray<NSString *> *arguments, int *outStatus)
{
  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:launchPath];
  [task setArguments:arguments];
  NSPipe *pipe = [NSPipe pipe];
  [task setStandardOutput:pipe];
  [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
  @try {
    [task launch];
  } @catch (NSException *exception) {
    *outStatus = -1;
    return nil;
  }
  NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
  [task waitUntilExit];
  *outStatus = [task terminationStatus];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

SWCommandOutputRunner SWDefaultCommandOutputRunner(void)
{
  return ^NSString *(NSString *path, NSArray<NSString *> *args, int *status) {
    return SWRunCommandForOutput(path, args, status);
  };
}

@interface SWSystemPackageChecker ()
{
  NSString *_repositoryName;
  SWCommandOutputRunner _runner;
  void (^_logHandler)(NSString *line);
}
@end

@implementation SWSystemPackageChecker

- (instancetype)initWithRepositoryName:(NSString *)repositoryName
                         commandRunner:(SWCommandOutputRunner)runner
                            logHandler:(void (^)(NSString *line))logHandler
{
  self = [super init];
  if (self) {
    _repositoryName = [repositoryName copy];
    _runner = [(runner ?: SWDefaultCommandOutputRunner()) copy];
    _logHandler = logHandler ? (void (^)(NSString *))[logHandler copy] : ^(NSString *line) {};
  }
  return self;
}

- (NSString *)run:(NSString *)launchPath arguments:(NSArray<NSString *> *)arguments
{
  int status = -1;
  NSString *output = _runner(launchPath, arguments, &status);
  if (status == 0 && output) return output;
  _logHandler([NSString stringWithFormat:@"%@ packages not checked: %@ %@ failed (exit %d)",
    _repositoryName, launchPath, [arguments componentsJoinedByString:@" "], status]);
  return nil;
}

- (NSArray<SWSystemPackageUpgrade *> *)pendingUpgrades
{
  NSString *configuration = [self run:kPkgPath arguments:@[@"-vv"]];
  if (!configuration) return nil;
  NSString *url = [SWSystemPackages repositoryURLFromPkgConfiguration:configuration
                                                       repositoryName:_repositoryName];
  if (!url) {
    _logHandler([NSString stringWithFormat:@"%@ packages not checked: pkg -vv names no repository %@",
      _repositoryName, _repositoryName]);
    return nil;
  }
  while ([url hasSuffix:@"/"]) url = [url substringToIndex:[url length] - 1];

  // A directory only this user can read, so nobody can swap the catalogue
  // between download and extraction.
  NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"SoftwareUpdate-pkg-XXXXXX"];
  char *buffer = strdup([template fileSystemRepresentation]);
  if (!buffer || !mkdtemp(buffer)) {
    free(buffer);
    _logHandler([NSString stringWithFormat:@"%@ packages not checked: no temporary directory", _repositoryName]);
    return nil;
  }
  NSString *directory = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:buffer
                                                                                     length:strlen(buffer)];
  free(buffer);

  NSArray *pending = [self pendingUpgradesFromRepositoryURL:url downloadDirectory:directory];
  [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
  return pending;
}

- (NSArray<SWSystemPackageUpgrade *> *)pendingUpgradesFromRepositoryURL:(NSString *)url
                                                       downloadDirectory:(NSString *)directory
{
  NSString *catalogue = [directory stringByAppendingPathComponent:@"packagesite.pkg"];
  NSString *catalogueURL = [url stringByAppendingString:@"/packagesite.pkg"];
  _logHandler([NSString stringWithFormat:@"Checking %@ packages at %@", _repositoryName, catalogueURL]);
  if (![self run:kFetchPath arguments:@[@"-q", @"-o", catalogue, catalogueURL]]) return nil;

  NSString *manifest = [self run:kTarPath arguments:@[@"-xOf", catalogue, @"packagesite.yaml"]];
  if (!manifest) return nil;
  NSDictionary *available = [SWSystemPackages packageVersionsFromManifest:manifest];
  if ([available count] == 0) {
    _logHandler([NSString stringWithFormat:@"%@ packages not checked: the catalogue lists no packages",
      _repositoryName]);
    return nil;
  }

  NSString *query = [self run:kPkgPath arguments:@[@"query", @"%R %n %v"]];
  if (!query) return nil;
  NSDictionary *installed = [SWSystemPackages installedPackagesFromQueryOutput:query
                                                                repositoryName:_repositoryName];

  // pkg's own ordering, not a string comparison: its versions carry
  // portrevisions, epochs and letters that only pkg knows how to order.
  __block BOOL comparisonFailed = NO;
  NSArray *pending = [SWSystemPackages pendingUpgradesForInstalled:installed
                                                          available:available
                                                         comparator:^NSComparisonResult(NSString *a, NSString *b) {
    NSString *answer = [[self run:kPkgPath arguments:@[@"version", @"-t", a, b]]
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([answer isEqualToString:@"<"]) return NSOrderedAscending;
    if ([answer isEqualToString:@">"]) return NSOrderedDescending;
    if (![answer isEqualToString:@"="]) comparisonFailed = YES;
    return NSOrderedSame;
  }];
  if (comparisonFailed) {
    _logHandler([NSString stringWithFormat:@"%@ packages not checked: pkg version -t gave no answer",
      _repositoryName]);
    return nil;
  }

  _logHandler([NSString stringWithFormat:@"%@: %lu of %lu installed packages can be upgraded",
    _repositoryName, (unsigned long)[pending count], (unsigned long)[installed count]]);
  return pending;
}

@end

@interface SWSystemPackageUpgrader ()
{
  SWStreamingCommandRunner _runner;
  void (^_logHandler)(NSString *line);
}
@end

@implementation SWSystemPackageUpgrader

@synthesize maxLockAttempts = _maxLockAttempts;
@synthesize lockRetryDelay = _lockRetryDelay;

- (instancetype)initWithCommandRunner:(SWStreamingCommandRunner)runner
                           logHandler:(void (^)(NSString *line))logHandler
{
  self = [super init];
  if (self) {
    _runner = [runner copy];
    _logHandler = logHandler ? (void (^)(NSString *))[logHandler copy] : ^(NSString *line) {};
    // Another pkg (a pref pane installing something, a periodic job) can hold
    // the database for a while; give it about half a minute, as
    // GWFreeBSDBackend does for installs.
    _maxLockAttempts = 10;
    _lockRetryDelay = 3.0;
  }
  return self;
}

- (BOOL)runPkg:(NSArray<NSString *> *)arguments error:(NSString **)outError
{
  // pkg asks before it replaces anything; nobody is there to answer.
  NSDictionary *environment = @{@"ASSUME_ALWAYS_YES": @"yes"};
  int status = 0;
  for (NSUInteger attempt = 1; attempt <= _maxLockAttempts; attempt++) {
    __block BOOL lockSeen = NO;
    status = _runner(kPkgPath, arguments, environment, ^(NSString *line) {
      if ([line rangeOfString:@"database is locked" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        lockSeen = YES;
      }
    });
    if (status == 0) return YES;
    if (!lockSeen || attempt == _maxLockAttempts) break;
    _logHandler([NSString stringWithFormat:@"The package database is in use, retrying (%lu of %lu)",
      (unsigned long)attempt + 1, (unsigned long)_maxLockAttempts]);
    if (_lockRetryDelay > 0) [NSThread sleepForTimeInterval:_lockRetryDelay];
  }
  if (outError) {
    *outError = [NSString stringWithFormat:@"pkg %@ failed (exit %d).",
      [arguments componentsJoinedByString:@" "], status];
  }
  return NO;
}

- (BOOL)upgradeWithStepHandler:(void (^)(NSString *stepVerb))stepHandler
                         error:(NSString **)outError
{
  if (stepHandler) stepHandler(@"Updating the package catalogue");
  if (![self runPkg:@[@"update"] error:outError]) return NO;
  if (stepHandler) stepHandler(@"Upgrading packages");
  return [self runPkg:@[@"upgrade", @"-y"] error:outError];
}

@end

@implementation SWRepository (SWSystemPackages)

+ (instancetype)systemPackagesItemNamed:(NSString *)name
                               upgrades:(NSArray<SWSystemPackageUpgrade *> *)upgrades
{
  SWRepository *item = [[self alloc] initWithPlistEntry:@{@"Name": name}];
  [item setIsSystemPackages:YES];
  [item setSystemPackageUpgrades:upgrades];
  [item setRestartRequired:[SWSystemPackages upgradesRequireRestart:upgrades]];
  [item setSelected:YES];
  return item;
}

@end
