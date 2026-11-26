/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWDebBackend - Debian/APT package manager backend implementation.
 */

#import "GWDebBackend.h"
#import "GWPackageManager.h"
#import "GWSudoHelper.h"

#pragma mark - Constants

static NSString *const kAPTGetPath = @"/usr/bin/apt-get";
static NSString *const kDpkgPath = @"/usr/bin/dpkg";
static NSString *const kDpkgQueryPath = @"/usr/bin/dpkg-query";
static NSString *const kAptConfigPath = @"/usr/bin/apt-config";

#pragma mark - GWDebBackend

@implementation GWDebBackend
{
  NSString *_resolvedAdminDirectory;
}

@synthesize backendName = _backendName;

#pragma mark - Initialization

- (instancetype)initWithExecutor:(id<GWSystemCommandExecutor>)executor
{
  self = [super init];
  if (self) {
    if (executor) {
      _executor = executor;
    } else {
      _executor = (id<GWSystemCommandExecutor>)[GWSystemCommandExecutor sharedExecutor];
    }
    _backendName = @"Debian (APT)";
  }
  return self;
}

- (instancetype)init
{
  return [self initWithExecutor:nil];
}

#pragma mark - GWPackageManagerBackend - Query

- (BOOL)isPackageInstalled:(NSString *)packageName
{
  // "-W" (list with a custom --showformat) is a dpkg-query option, not a
  // plain dpkg one; dpkg itself rejects it with "unbekannte Option -W" /
  // "unknown option -W" and a non-zero exit, which isPackageInstalled: was
  // silently reading as "not installed" - so every declared package looked
  // missing regardless of its real state.
  // The database apt installs into, which a system may keep elsewhere than
  // /var/lib/dpkg: a package apt has just installed must not read as missing.
  NSMutableArray *queryArgs = [NSMutableArray array];
  NSString *adminDirectory = [self resolvedDpkgAdminDirectory];
  if (adminDirectory != nil)
    [queryArgs addObjectsFromArray:@[@"--admindir", adminDirectory]];
  [queryArgs addObjectsFromArray:@[@"-W", @"-f=${Status}", packageName]];
  NSString *output = nil;
  int status = [_executor execute:kDpkgQueryPath
                        arguments:queryArgs
                           output:&output];
  if (status != 0) {
    return NO;
  }
  return [output rangeOfString:@"install ok installed"].location != NSNotFound;
}

#pragma mark - Interrupted installs

/* Where apt keeps dpkg's state, asked of apt itself: a system may point
   Dir::State::status elsewhere, and the journal that blocks apt is then there.
   nil when apt cannot say, in which case nothing is repaired. */
- (NSString *)resolvedDpkgAdminDirectory
{
  if (_dpkgAdminDirectory != nil)
    return _dpkgAdminDirectory;
  if (_resolvedAdminDirectory != nil)
    return _resolvedAdminDirectory;
  NSString *output = nil;
  int status = [_executor execute:kAptConfigPath
                        arguments:@[@"shell", @"STATUS", @"Dir::State::status"]
                           output:&output];
  if (status != 0)
    return nil;
  NSRange open = [output rangeOfString:@"'"];
  NSRange close = [output rangeOfString:@"'" options:NSBackwardsSearch];
  if (open.location == NSNotFound || close.location <= open.location)
    return nil;
  NSString *statusFile = [output substringWithRange:
    NSMakeRange(open.location + 1, close.location - open.location - 1)];
  _resolvedAdminDirectory = [statusFile stringByDeletingLastPathComponent];
  return _resolvedAdminDirectory;
}

/* An install that was killed (power loss, a stuck run that was stopped) leaves
   journal files in dpkg's updates directory, and apt then fails with "dpkg was
   interrupted" until `dpkg --configure -a` finishes the job.  The directory is
   looked at, not apt's message, which is translated. */
- (void)repairInterruptedDpkgWithProgress:(nullable id<GWInstallProgressHandler>)progressHandler
{
  NSString *adminDirectory = [self resolvedDpkgAdminDirectory];
  if (adminDirectory == nil)
    return;
  NSArray *journal = [[NSFileManager defaultManager]
    contentsOfDirectoryAtPath:[adminDirectory stringByAppendingPathComponent:@"updates"]
                        error:NULL];
  if ([journal count] == 0)
    return;
  NSLog(@"GWDebBackend -> dpkg was interrupted, running dpkg --configure -a in %@", adminDirectory);
  [progressHandler installDidProgress:0.02f message:@"Finishing an interrupted installation..."];
  NSArray *args = nil;
  NSString *launchPath = GWSudoCommand(kDpkgPath,
    @[@"--admindir", adminDirectory, @"--configure", @"-a"], &args);
  int status = [_executor execute:launchPath arguments:args];
  NSLog(@"GWDebBackend <- dpkg --configure -a exit code: %d", status);
}

#pragma mark - GWPackageManagerBackend - Install

- (BOOL)installPackages:(NSArray<NSString *> *)packageNames
         localFilePaths:(NSArray<NSString *> *)filePaths
               progress:(nullable id<GWInstallProgressHandler>)progressHandler
                  error:(NSError **)error
{
  NSLog(@"GWDebBackend -> installPackages: %@ (local: %@)", packageNames, filePaths);
  [progressHandler installDidProgress:0.0f message:@"Preparing..."];
  _capturedErrorOutput = @"";

  // Install local .deb files first
  if ([filePaths count] > 0) {
    NSMutableArray *toolArgs = [NSMutableArray arrayWithObject:@"-i"];
    [toolArgs addObjectsFromArray:filePaths];
    NSArray *args = nil;
    NSString *launchPath = GWSudoCommand(kDpkgPath, toolArgs, &args);

    NSLog(@"GWDebBackend -> dpkg -i local packages: %@", filePaths);
    NSString *dpkgStderr = nil;
    int status = [_executor execute:launchPath
                          arguments:args
                     stdoutCallback:^(NSString *line) {
                       if ([progressHandler respondsToSelector:@selector(installDidOutputLine:)])
                         [progressHandler installDidOutputLine:line];
                     }
                     stderrCallback:^(NSString *line) {
                       if ([progressHandler respondsToSelector:@selector(installDidOutputLine:)])
                         [progressHandler installDidOutputLine:line];
                     }
               capturedErrorOutput:&dpkgStderr];
    _capturedErrorOutput = dpkgStderr ?: @"";
    NSLog(@"GWDebBackend <- dpkg exit code: %d", status);
    if (status != 0) {
      if (error) {
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     @"Failed to install local packages with dpkg"
                                 }];
      }
      return NO;
    }
  }

  [self repairInterruptedDpkgWithProgress:progressHandler];
  [progressHandler installDidProgress:0.05f message:@"Installing packages..."];

  // Install packages from repositories
  if ([packageNames count] > 0) {
    NSMutableArray *toolArgs = [NSMutableArray arrayWithObjects:@"install", @"-y", nil];
    [toolArgs addObjectsFromArray:packageNames];
    NSArray *args = nil;
    NSString *launchPath = GWSudoCommand(kAPTGetPath, toolArgs, &args);

    int status = 0;
    // default status for the first iteration
    int retries = 0;
    const int maxRetries = 30;
    __block BOOL waitingWasReported = NO;

    do
      {
        waitingWasReported = NO;

        if (retries > 0)
          {
            NSLog(@"GWDebBackend -> lock detected, retrying (%d/%d)...", retries, maxRetries);
            [NSThread sleepForTimeInterval:2.0];
            [progressHandler installDidProgress:0.5f
                                       message:@"Waiting for other installations to finish…"];
          }

        NSLog(@"GWDebBackend -> apt-get install -y %@", packageNames);
        NSString *aptStderr = nil;
        status = [_executor execute:launchPath
                          arguments:args
                     stdoutCallback:^(NSString *line)
        {
          if ([progressHandler respondsToSelector:@selector(installDidOutputLine:)])
            [progressHandler installDidOutputLine:line];
        }
                     stderrCallback:^(NSString *line)
        {
          if ([progressHandler respondsToSelector:@selector(installDidOutputLine:)])
            [progressHandler installDidOutputLine:line];

          if (!waitingWasReported &&
              ([line rangeOfString:@"Waiting for cache lock"
                          options:NSCaseInsensitiveSearch].location != NSNotFound ||
               [line rangeOfString:@"Could not get lock"
                          options:NSCaseInsensitiveSearch].location != NSNotFound))
            {
              waitingWasReported = YES;
              [progressHandler installDidProgress:0.5f
                                         message:@"Waiting for other installations to finish…"];
            }
        }
                   capturedErrorOutput:&aptStderr];

        if (aptStderr)
          _capturedErrorOutput = [_capturedErrorOutput stringByAppendingString:aptStderr];

        retries++;
      }
    while (status != 0 && waitingWasReported && retries < maxRetries);

    NSLog(@"GWDebBackend <- apt-get exit code: %d", status);
    if (status != 0) {
      if (error) {
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     @"Failed to install packages with apt-get"
                                 }];
      }
      return NO;
    }
  }

  [progressHandler installDidProgress:1.0f message:@"Completed"];
  NSLog(@"GWDebBackend [OK] installPackages succeeded");
  return YES;
}

#pragma mark - GWPackageManagerBackend - Uninstall

- (BOOL)uninstallPackages:(NSArray<NSString *> *)packageNames
                 progress:(nullable id<GWInstallProgressHandler>)progressHandler
                    error:(NSError **)error
{
  NSLog(@"GWDebBackend -> uninstallPackages: %@", packageNames);
  [progressHandler installDidProgress:0.0f message:@"Preparing..."];
  [progressHandler installDidProgress:0.5f message:@"Removing packages..."];

  if ([packageNames count] > 0) {
    NSMutableArray *toolArgs = [NSMutableArray arrayWithObjects:@"remove", @"-y", nil];
    [toolArgs addObjectsFromArray:packageNames];
    NSArray *args = nil;
    NSString *launchPath = GWSudoCommand(kAPTGetPath, toolArgs, &args);

    int status = [_executor execute:launchPath arguments:args];
    if (status != 0) {
      if (error) {
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     @"Failed to remove packages with apt-get"
                                 }];
      }
      return NO;
    }
  }

  [progressHandler installDidProgress:1.0f message:@"Completed"];
  NSLog(@"GWDebBackend [OK] uninstallPackages succeeded");
  return YES;
}

#pragma mark - GWPackageManagerBackend - File Queries

- (NSArray<NSString *> *)filesForPackage:(NSString *)name error:(NSError **)error
{
  NSLog(@"GWDebBackend -> filesForPackage: %@", name);
  NSString *output = nil;

  int status = [_executor execute:kDpkgPath
                        arguments:@[@"-L", name]
                           output:&output];

  if (status != 0) {
    if (error) {
      *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                   code:GWPackageManagerErrorCommandFailed
                               userInfo:@{
                                 NSLocalizedDescriptionKey:
                                   [NSString stringWithFormat:
                                     @"Failed to list files for package '%@'", name]
                               }];
    }
    return nil;
  }

  if ([output length] == 0) {
    NSLog(@"GWDebBackend <- filesForPackage: %@ -> (empty)", name);
    return @[];
  }

  // Split output into lines, trimming whitespace, and filter empty lines
  NSArray *lines = [output componentsSeparatedByString:@"\n"];
  NSMutableArray *files = [NSMutableArray arrayWithCapacity:[lines count]];

  for (NSString *line in lines) {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed length] > 0) {
      [files addObject:trimmed];
    }
  }

  NSLog(@"GWDebBackend <- filesForPackage: %@ -> %lu files", name, (unsigned long)[files count]);
  return [files copy];
}

- (NSString *)packageOwningFile:(NSString *)path error:(NSError **)error
{
  NSLog(@"GWDebBackend -> packageOwningFile: %@", path);
  NSString *output = nil;

  int status = [_executor execute:kDpkgPath
                        arguments:@[@"-S", path]
                           output:&output];

  if (status != 0) {
    if (error) {
      *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                   code:GWPackageManagerErrorCommandFailed
                               userInfo:@{
                                 NSLocalizedDescriptionKey:
                                   [NSString stringWithFormat:
                                     @"No package owns the file '%@'", path]
                               }];
    }
    return nil;
  }

  // dpkg -S returns "package-name: /path/to/file", extract the package name
  NSRange colonRange = [output rangeOfString:@":"];
  if (colonRange.location == NSNotFound) {
    return nil;
  }

  NSString *pkg = [output substringToIndex:colonRange.location];
  NSLog(@"GWDebBackend <- packageOwningFile: %@ -> %@", path, pkg);
  return pkg;
}

@end
