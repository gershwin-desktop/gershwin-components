/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_AGInstallTask.m - the rewrite that turns a bare GitHub failure into an
 * error a person can act on ("GitHub rate limit reached: ...").
 *
 * The evidence reaches the task over two channels: the failure text of the
 * error itself, and curl's own lines through installDidOutputLine:. Neither
 * channel can be produced on demand here (curl is run with -f, so the
 * server's own words never reach us), so each one is driven directly and the
 * rule - what counts as evidence, and what does not - is what is proven. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "AGInstallTask.h"

/*
 * AGInstaller.m owns this constant in the app. This tool links the task
 * alone - the installer would drag in the catalog, the registry and the
 * downloader - so the constant is defined here; its value only has to be the
 * name the task posts, and no assertion reads it as text.
 */
NSString *const AGInstallerTaskDidChangeNotification =
    @"AGInstallerTaskDidChangeNotification";

@interface AGInstallTask (RateLimitTest)
/* The task's conformance to the download progress protocol, and with it this
 * method, lives in a class extension inside AGInstallTask.m so no other
 * reader sees a progress sink. Named here so the test can feed it a line. */
- (void)installDidOutputLine:(NSString *)line;
@end

/* Every state change is handed to the main queue, and this tool has no
 * application to spin it, so the run loop is turned by hand until the queue
 * is empty: the flags the rewrite reads are set inside those blocks. */
static void drainMainQueue(void)
{
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
  while ([[NSOperationQueue mainQueue] operationCount] > 0
         && [deadline timeIntervalSinceNow] > 0)
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                             beforeDate:
                                 [NSDate dateWithTimeIntervalSinceNow:0.05]];
}

static NSError *failureWithText(NSString *text)
{
  return [NSError errorWithDomain:@"AGTestErrorDomain"
                             code:22
                         userInfo:@{NSLocalizedDescriptionKey: text}];
}

/* One install run as the downloader leaves it: curl's line (if any) first,
 * then the failure the downloader reports. The queue order between the two
 * is the same one AGInstaller produces. */
static AGInstallTask *taskRunWithLine(NSString *line, NSString *errorText)
{
  AGInstallTask *task = [[AGInstallTask alloc] initWithApp:nil];
  if (line != nil)
    [task installDidOutputLine:line];
  drainMainQueue();
  task.error = failureWithText(errorText);
  return task;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* --- evidence in curl's own line --- */
  AGInstallTask *rateLimited = taskRunWithLine(
      @"curl: (60) The requested URL returned error: 403",
      @"Could not reach GitHub for owner/repo");
  PASS([[rateLimited.error localizedDescription]
          hasPrefix:@"GitHub rate limit reached:"],
       "a refusal from GitHub rewrites the error: %s",
       [[rateLimited.error localizedDescription] UTF8String]);
  PASS([[rateLimited.error localizedDescription]
          rangeOfString:@"Could not reach GitHub for owner/repo"].location
          != NSNotFound,
       "the original failure is kept inside the rewrite");
  PASS([rateLimited.error code] == 22,
       "the error's code is preserved, got %ld",
       (long)[rateLimited.error code]);
  PASS([[rateLimited.error domain] isEqualToString:@"AGTestErrorDomain"],
       "the error's domain is preserved, got %s",
       [[rateLimited.error domain] UTF8String]);
  PASS([rateLimited.error.userInfo objectForKey:NSUnderlyingErrorKey] != nil,
       "the original error stays reachable underneath");

  AGInstallTask *phrase = taskRunWithLine(
      @"{\"message\":\"API rate limit exceeded for 1.2.3.4.\"}",
      @"Could not reach GitHub for owner/repo");
  PASS([[phrase.error localizedDescription]
          hasPrefix:@"GitHub rate limit reached:"],
       "a line that says rate limit rewrites the error: %s",
       [[phrase.error localizedDescription] UTF8String]);

  /* --- a refusal from somewhere that is not GitHub says nothing --- */
  NSString *mirrorText =
      @"Download failed for https://mirror.example.org/pub/tool.AppImage";
  AGInstallTask *mirror = taskRunWithLine(
      @"curl: (22) The requested URL returned error: 403", mirrorText);
  PASS([[mirror.error localizedDescription] isEqualToString:mirrorText],
       "a 403 from a mirror is not a GitHub rate limit: %s",
       [[mirror.error localizedDescription] UTF8String]);

  /* --- a refusal GitHub gives for another reason is not one either --- */
  AGInstallTask *missing = taskRunWithLine(
      @"curl: (22) The requested URL returned error: 404",
      @"Could not reach GitHub for owner/repo");
  PASS([[missing.error localizedDescription]
          isEqualToString:@"Could not reach GitHub for owner/repo"],
       "a 404 is not a rate limit: %s",
       [[missing.error localizedDescription] UTF8String]);

  AGInstallTask *quiet = taskRunWithLine(
      nil, @"Download failed for https://github.com/owner/repo/releases/x");
  PASS([[quiet.error localizedDescription]
          isEqualToString:
              @"Download failed for https://github.com/owner/repo/releases/x"],
       "no evidence means no rewrite: %s",
       [[quiet.error localizedDescription] UTF8String]);

  /* --- evidence in the failure text itself --- */
  AGInstallTask *inText = taskRunWithLine(
      nil, @"GitHub API response: rate limit exceeded for this hour");
  PASS([[inText.error localizedDescription]
          hasPrefix:@"GitHub rate limit reached:"],
       "the failure text on its own still rewrites: %s",
       [[inText.error localizedDescription] UTF8String]);

  /* --- rewriting twice would wrap the message in itself --- */
  AGInstallTask *already = taskRunWithLine(
      @"curl: (22) The requested URL returned error: 403",
      @"GitHub rate limit reached: Could not reach GitHub");
  PASS([[already.error localizedDescription]
          isEqualToString:
              @"GitHub rate limit reached: Could not reach GitHub"],
       "an already rewritten error is left alone: %s",
       [[already.error localizedDescription] UTF8String]);

  /* --- a run with nothing to say stays nil --- */
  AGInstallTask *noError = [[AGInstallTask alloc] initWithApp:nil];
  [noError installDidOutputLine:
      @"curl: (22) The requested URL returned error: 403"];
  drainMainQueue();
  noError.error = nil;
  PASS(noError.error == nil, "no failure means nothing to rewrite");

  [rateLimited release];
  [phrase release];
  [mirror release];
  [missing release];
  [quiet release];
  [inText release];
  [already release];
  [noError release];
  [arp release];
  return 0;
}
