/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWRunGuard.h"

// The two flags main.m is invoked with, and therefore the two things that
// distinguish a *run* from the ordinary windowed app. The windowed app is
// always running while a run is in progress (it launched it), so the
// executable path alone cannot be the test.
static NSString *const kRunFlagUpdate = @"--run-update";
static NSString *const kRunFlagRebuild = @"--rebuild";

@implementation SWRunGuard

#pragma mark - Reading the process list

// The invocations to try, in order, and where each is known to work. ps is
// not one program: it is procps on Linux and a 4.4BSD descendant on every BSD,
// and the option spellings differ. Rather than bet the lock on one spelling
// working on an operating system nobody here can test, each candidate's output
// is validated before it is trusted, and the next one is tried if it is not.
//
// "args" is a keyword in both families (the BSD original), and "=" to suppress
// a header is in both too; the differences are in the selectors (-ax vs -A)
// and in whether -o may be repeated. That is why the list is this long.
+ (NSArray<NSArray<NSString *> *> *)psCandidates
{
  return @[
    // Linux (procps-ng) and FreeBSD/NetBSD: verified working.
    @[@"-ax", @"-o", @"pid=", @"-o", @"args="],
    // Single -o with both keywords comma-separated, for ps builds that take
    // only one.
    @[@"-ax", @"-o", @"pid=,args="],
    // -A rather than -ax, for ps builds whose -x means something else.
    @[@"-A", @"-o", @"pid=", @"-o", @"args="],
  ];
}

// "/bin/ps" is where ps lives on every BSD and on Linux with merged /usr.
// A path that does not exist is skipped rather than treated as an error, so
// an unusual layout costs a candidate rather than the whole check.
+ (NSString *)psPath
{
  for (NSString *candidate in @[@"/bin/ps", @"/usr/bin/ps"]) {
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:candidate]) {
      return candidate;
    }
  }
  return nil;
}

+ (NSString *)runPSWithPath:(NSString *)path arguments:(NSArray<NSString *> *)arguments
{
  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:path];
  [task setArguments:arguments];
  NSPipe *out = [NSPipe pipe];
  [task setStandardOutput:out];
  // Discarded: ps writes complaints (unknown keyword, bad selector) to stderr
  // and the exit status already says whether it worked. Letting them fill an
  // unread pipe would deadlock on a chatty ps, so give it its own and never
  // read it.
  [task setStandardError:[NSPipe pipe]];

  @try {
    [task launch];
  } @catch (NSException *exception) {
    return nil;
  }

  NSData *data = [[out fileHandleForReading] readDataToEndOfFile];
  [task waitUntilExit];
  if ([task terminationStatus] != 0) return nil;

  return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] copy];
}

// Does this look like the "<pid> <command>" listing we asked for? A ps that
// ignored the "=" would still return 0 with a header row, and one that
// ignored the selectors would return columns we cannot read; both would
// otherwise be mistaken for "no other run".
+ (BOOL)listingLooksUsable:(NSString *)listing
{
  if ([listing length] == 0) return NO;
  NSCharacterSet *space = [NSCharacterSet whitespaceAndNewlineCharacterSet];
  NSUInteger examined = 0;
  for (NSString *rawLine in [listing componentsSeparatedByString:@"\n"]) {
    NSString *line = [rawLine stringByTrimmingCharactersInSet:space];
    if ([line length] == 0) continue;
    NSRange split = [line rangeOfString:@" "];
    if (split.location == NSNotFound) return NO;
    NSString *pidText = [line substringToIndex:split.location];
    for (NSUInteger i = 0; i < [pidText length]; i++) {
      unichar c = [pidText characterAtIndex:i];
      if (c < '0' || c > '9') return NO;
    }
    if (++examined >= 5) break; // a handful of rows is enough to judge the shape
  }
  return examined > 0;
}

+ (NSString *)processList
{
  NSString *ps = [self psPath];
  if (!ps) return nil;

  for (NSArray<NSString *> *arguments in [self psCandidates]) {
    NSString *listing = [self runPSWithPath:ps arguments:arguments];
    if (![self listingLooksUsable:listing]) continue;
    return listing;
  }
  return nil;
}

#pragma mark - The decision

+ (BOOL)rejectListing:(NSString *)listing
           executable:(NSString *)executable
                selfPID:(pid_t)selfPID
                reason:(NSString **)outReason
{
  if ([listing length] == 0 || [executable length] == 0) return NO;

  NSCharacterSet *space = [NSCharacterSet whitespaceAndNewlineCharacterSet];
  for (NSString *rawLine in [listing componentsSeparatedByString:@"\n"]) {
    NSString *line = [rawLine stringByTrimmingCharactersInSet:space];
    if ([line length] == 0) continue;

    NSRange split = [line rangeOfString:@" "];
    if (split.location == NSNotFound) continue;
    NSString *pidText = [line substringToIndex:split.location];
    NSString *command = [line substringFromIndex:NSMaxRange(split)];

    if ((pid_t)[pidText integerValue] == selfPID) continue;

    // The line must START with our own executable, not merely mention it.
    // That is what excludes the `sudo -A -E <exe> --rebuild ...` wrapper the
    // windowed app launches, whose argv[0] is sudo: it carries our path and
    // one of our flags but is an ancestor of this process, not a second run.
    if (![command hasPrefix:executable]) continue;

    // ...and it must carry a run flag, which is what excludes the windowed
    // app itself, which starts with the same executable and has no flag.
    if ([command rangeOfString:[@" " stringByAppendingString:kRunFlagUpdate]].location == NSNotFound &&
        [command rangeOfString:[@" " stringByAppendingString:kRunFlagRebuild]].location == NSNotFound) {
      continue;
    }

    if (outReason) {
      *outReason = [NSString stringWithFormat:
        @"Another Software Update run is already in progress (process %@). "
        @"Wait for it to finish before starting this one.", pidText];
    }
    return YES;
  }

  return NO;
}

+ (BOOL)acquireRunLockWithReason:(NSString **)outReason
{
  NSString *executable = [[NSBundle mainBundle] executablePath];
  if ([executable length] == 0) return YES; // fail open

  NSString *listing = [self processList];
  if ([listing length] == 0) return YES;     // fail open, see the header

  return ![self rejectListing:listing
                  executable:executable
                       selfPID:[[NSProcessInfo processInfo] processIdentifier]
                       reason:outReason];
}

@end
