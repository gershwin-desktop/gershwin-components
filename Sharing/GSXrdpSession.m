/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSXrdpSession.h"

static NSString *const GSXrdpMarker = @"# gershwin-xrdp-session: managed by the Sharing preferences";
static NSString *const GSXrdpErrorDomain = @"GSXrdpSession";

@implementation GSXrdpSession

+ (NSString *)defaultSessionScript
{
  return @"/System/Library/Scripts/Gershwin.sh";
}

+ (NSString *)wrapperPathInHome:(NSString *)home
{
  return [home stringByAppendingPathComponent:@"startwm.sh"];
}

+ (NSString *)backupPathInHome:(NSString *)home
{
  return [home stringByAppendingPathComponent:@"startwm.sh.gershwin-backup"];
}

+ (BOOL)fail:(NSError **)error message:(NSString *)message
{
  if (error)
    {
      *error = [NSError errorWithDomain:GSXrdpErrorDomain code:1
                               userInfo:[NSDictionary dictionaryWithObject:message
                                                                    forKey:NSLocalizedDescriptionKey]];
    }
  return NO;
}

+ (BOOL)isOurs:(NSString *)path
{
  NSString *text = [NSString stringWithContentsOfFile:path
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
  return text != nil && [text rangeOfString:GSXrdpMarker].location != NSNotFound;
}

+ (BOOL)isConfiguredInHome:(NSString *)home
{
  return [self isOurs:[self wrapperPathInHome:home]];
}

+ (BOOL)configureInHome:(NSString *)home
          sessionScript:(NSString *)sessionScript
                  error:(NSError **)error
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *wm = [self wrapperPathInHome:home];
  NSString *bak = [self backupPathInHome:home];

  if ([sessionScript rangeOfString:@"'"].location != NSNotFound
      || ![fm isExecutableFileAtPath:sessionScript])
    {
      return [self fail:error message:
        [NSString stringWithFormat:@"%@ is not an executable session script", sessionScript]];
    }

  BOOL exists = [fm fileExistsAtPath:wm];
  if (exists && ![self isOurs:wm])
    {
      if ([fm fileExistsAtPath:bak])
        {
          return [self fail:error message:
            @"~/startwm.sh and ~/startwm.sh.gershwin-backup both exist; move one away first"];
        }
      if (![fm moveItemAtPath:wm toPath:bak error:error])
        {
          return NO;
        }
    }

  /* The path is quoted so that a home or install path with spaces still works. */
  NSString *body = [NSString stringWithFormat:
    @"#!/bin/sh\n%@\nexec '%@'\n", GSXrdpMarker, sessionScript];
  if (![body writeToFile:wm atomically:YES encoding:NSUTF8StringEncoding error:error])
    {
      return NO;
    }
  return [fm setAttributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0755]
                                                       forKey:NSFilePosixPermissions]
              ofItemAtPath:wm error:error];
}

+ (BOOL)restoreInHome:(NSString *)home error:(NSError **)error
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *wm = [self wrapperPathInHome:home];
  NSString *bak = [self backupPathInHome:home];

  if ([fm fileExistsAtPath:wm])
    {
      if (![self isOurs:wm])
        {
          return [self fail:error message:@"~/startwm.sh was not written by Sharing; leaving it alone"];
        }
      if (![fm removeItemAtPath:wm error:error])
        {
          return NO;
        }
    }
  if ([fm fileExistsAtPath:bak])
    {
      return [fm moveItemAtPath:bak toPath:wm error:error];
    }
  return YES;
}

@end
