/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* Shared plumbing for the two things that talk to appimage.github.io: the
 * catalog fetch and the image fetch.
 *
 * It lives as static inline functions in a header rather than in a .m for
 * one reason: both callers are in the same component and neither owns the
 * other's file, and a shared translation unit would have to be listed in the
 * GNUmakefile and compiled twice over anyway. One definition, no link order
 * to reason about, no duplicated body to drift.
 *
 * Nothing here retries, times out on its own or invents data: a failure
 * becomes an NSError whose text the caller shows to the user. */

/* Where both caches live: one directory for feed.json and the images it
 * points at, so clearing the app's caches is a single directory. */
static inline NSString *AGDefaultCacheDirectory(void)
{
  return [NSHomeDirectory() stringByAppendingPathComponent:
      @"Library/Caches/io.github.gershwin-desktop.AppGarden"];
}

/* curl's diagnostic, first line only: the banner and the tooltips each show
 * one sentence, and curl repeats itself across lines for nothing. */
static inline NSString *AGFirstLine(NSData *data)
{
  if ([data length] == 0)
    return nil;
  NSString *text = [[NSString alloc] initWithData:data
                                          encoding:NSUTF8StringEncoding];
  if (text == nil)
    return nil;
  NSRange newline = [text rangeOfString:@"\n"];
  if (newline.location != NSNotFound)
    text = [text substringToIndex:newline.location];
  text = [text stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return ([text length] > 0) ? text : nil;
}

/* Runs curl and returns its exit status. *reason gets curl's first stderr
 * line, or the launch exception's reason when curl cannot be started at all.
 *
 * curl through NSTask instead of NSURLSession: in this stack the session
 * APIs block the main thread on DNS and mishandle redirects, and every other
 * network component here does it this way. stderr is drained before
 * waitUntilExit: a full pipe would stall curl and the wait would never end. */
static inline int AGRunCurl(NSArray<NSString *> *arguments, NSString **reason)
{
  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:@"curl"];
  [task setArguments:arguments];
  NSPipe *errorPipe = [NSPipe pipe];
  [task setStandardError:errorPipe];
  // The body goes to -o, so stdout stays empty and this pipe never fills.
  [task setStandardOutput:[NSPipe pipe]];

  @try
    {
      [task launch];
    }
  @catch (NSException *exception)
    {
      if (reason != NULL)
        *reason = AGFirstLine([[exception reason]
            dataUsingEncoding:NSUTF8StringEncoding]);
      return -1;
    }

  NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
  [task waitUntilExit];
  if (reason != NULL)
    *reason = AGFirstLine(errorData);
  return [task terminationStatus];
}
