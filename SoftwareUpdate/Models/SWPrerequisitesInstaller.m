/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWPrerequisitesInstaller.h"

// Adapts GWPackageManager's install-progress callbacks onto a plain
// SWGitLogLine block, so apt-get's/pacman's/pkg's real output streams into
// the app's Log window exactly like every other phase's commands do.
@interface SWPrereqInstallLogForwarder : NSObject <GWInstallProgressHandler>
{
  SWGitLogLine _logHandler;
}
- (instancetype)initWithLogHandler:(SWGitLogLine)logHandler;
@end

@implementation SWPrereqInstallLogForwarder

- (instancetype)initWithLogHandler:(SWGitLogLine)logHandler
{
  self = [super init];
  if (self) _logHandler = [logHandler copy];
  return self;
}

- (void)installDidProgress:(float)progress message:(NSString *)message
{
  if (_logHandler && [message length] > 0) _logHandler(message);
}

- (void)installDidOutputLine:(NSString *)line
{
  if (_logHandler) _logHandler(line);
}

@end

@interface SWPrerequisitesInstaller ()
{
  NSString *_osSupportDirectory;
  GWPackageManager *_packageManager;
  NSString *_osIdentifier;
}
@end

@implementation SWPrerequisitesInstaller

@synthesize logHandler = _logHandler;

- (instancetype)initWithOSSupportDirectory:(NSString *)osSupportDirectory
                            packageManager:(GWPackageManager *)packageManager
                             osIdentifier:(NSString *)osIdentifier
{
  self = [super init];
  if (self) {
    _osSupportDirectory = [osSupportDirectory copy];
    _packageManager = packageManager ?: [GWPackageManager sharedManager];
    _osIdentifier = [osIdentifier copy] ?: [GWOSDetector currentOSIdentifier];
  }
  return self;
}

- (NSArray<NSString *> *)declaredPackages
{
  if (!_osIdentifier) return nil;

  // Library/OSSupport/ already carries a symlink per OS variant onto its
  // family's file (e.g. artix.txt -> arch.txt, ubuntu.txt -> debian.txt), so
  // a single direct lookup is enough - no extra ID_LIKE fallback needed here.
  NSString *path = [_osSupportDirectory stringByAppendingPathComponent:
    [_osIdentifier stringByAppendingPathExtension:@"txt"]];
  NSString *contents = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
  if (!contents) return nil; // no package list known for this OS - not an error

  NSMutableArray *packages = [NSMutableArray array];
  for (NSString *rawLine in [contents componentsSeparatedByString:@"\n"]) {
    // debian.txt allows a trailing "# comment"; strip it before trimming.
    NSString *line = rawLine;
    NSRange hash = [line rangeOfString:@"#"];
    if (hash.location != NSNotFound) line = [line substringToIndex:hash.location];
    line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([line length] > 0) [packages addObject:line];
  }
  return [packages copy];
}

- (NSArray<NSString *> *)missingPackages
{
  NSArray<NSString *> *declared = [self declaredPackages];
  if (_logHandler) {
    _logHandler([NSString stringWithFormat:@"Checking %lu declared package%@ for %@…",
      (unsigned long)[declared count], [declared count] == 1 ? @"" : @"s", _osIdentifier ?: @"this OS"]);
  }
  if ([declared count] == 0) return @[];
  return [_packageManager missingPackagesFrom:declared];
}

- (BOOL)installMissingPackagesWithProgress:(void (^)(NSString *, NSUInteger, NSUInteger))progress
                                       error:(NSError **)error
{
  NSArray<NSString *> *missing = [self missingPackages];
  if ([missing count] == 0) {
    if (_logHandler) _logHandler(@"All prerequisites are already installed.");
    return YES; // phase completes at once, per spec
  }

  SWPrereqInstallLogForwarder *forwarder = _logHandler
    ? [[SWPrereqInstallLogForwarder alloc] initWithLogHandler:_logHandler] : nil;

  NSUInteger total = [missing count];
  NSUInteger index = 0;
  for (NSString *packageName in missing) {
    index++;
    if (progress) progress(packageName, index, total);
    if (_logHandler) {
      _logHandler([NSString stringWithFormat:@"Installing %@ (package %lu of %lu)…",
        packageName, (unsigned long)index, (unsigned long)total]);
    }

    NSError *installError = nil;
    if (![_packageManager installPackages:@[packageName]
                            localFilePaths:nil
                                  progress:forwarder
                                     error:&installError]) {
      // The backend's own message ("Failed to install packages with
      // apt-get") never names which package it was invoked with - not a
      // problem for the backend, which is always called with the whole
      // list, but here it leaves the alert saying nothing the user did not
      // already know. This loop is the only place that still knows which
      // single package was being attempted, so name it here.
      if (error) {
        NSString *underlying = [installError localizedDescription];
        NSString *description = underlying
          ? [NSString stringWithFormat:@"%@: %@", packageName, underlying]
          : [NSString stringWithFormat:@"Failed to install %@", packageName];
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:description
                                                                            forKey:NSLocalizedDescriptionKey];
        if (installError) [userInfo setObject:installError forKey:NSUnderlyingErrorKey];
        *error = [NSError errorWithDomain:[installError domain] ?: @"SWPrerequisitesInstallerErrorDomain"
                                      code:[installError code]
                                  userInfo:userInfo];
      }
      return NO; // stop before any other repository changes, per spec
    }
  }
  return YES;
}

@end
