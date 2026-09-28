/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGInstallTask.h"
#import "AGInstaller.h"
#import <PackageManager/GWPackageManager.h>

/*
 * The conformance lives in this extension rather than in AGInstallTask.h:
 * AGInstaller is the only object that hands this task to the downloader, and
 * every other reader should see a plain record of one install run instead of
 * a progress sink it could call into.
 */
@interface AGInstallTask () <GWInstallProgressHandler>
- (void)applyProgress:(float)progress message:(NSString *)message;
- (void)postChangeNotification;
@end

/*
 * The downloader's failure text names the step that failed ("GitHub release
 * lookup failed for owner/repo") but never why, and a 403 from the release
 * API is indistinguishable from a network fault in it. The evidence that it
 * was a rate limit lives in curl's output, which reaches this task through
 * installDidOutputLine: - the one channel that carries raw tool output - or,
 * when the failure text itself already says so, in the text. Either way the
 * rewrite happens here so the framework itself stays untouched (section 8 of
 * the brief).
 */
static NSError *AGRewrittenRateLimitError(NSError *error, BOOL outputSaidRateLimit)
{
  if (error == nil)
    return nil;

  NSString *original = [error localizedDescription];
  if (original == nil)
    original = @"";

  BOOL textSaysRateLimit =
      [original rangeOfString:@"rate limit"
                      options:NSCaseInsensitiveSearch].location != NSNotFound;
  if (!textSaysRateLimit && !outputSaidRateLimit)
    return error;
  if ([original rangeOfString:@"GitHub rate limit"
                      options:NSCaseInsensitiveSearch].location != NSNotFound)
    return error;

  NSString *text = [NSString stringWithFormat:
      NSLocalizedString(@"GitHub rate limit reached: %@", @""),
      original];
  return [NSError errorWithDomain:[error domain]
                             code:[error code]
                         userInfo:@{
                           NSLocalizedDescriptionKey: text,
                           NSUnderlyingErrorKey: error,
                         }];
}

@implementation AGInstallTask
{
  BOOL _sawRateLimitOutput;
}

- (instancetype)initWithApp:(AGApp *)app
{
  self = [super init];
  if (self)
    {
      _app = app;
      _state = AGInstallTaskStateWaiting;
      /* No phase has a measurable size until the downloader names one, so
       * the button starts with a barber pole instead of a zero-width bar. */
      _progress = -1.0f;
    }
  return self;
}

#pragma mark - GWInstallProgressHandler

- (void)installDidProgress:(float)progress message:(NSString *)message
{
  /* The downloader calls from its download operation, while the observers
   * (cards, the detail page) live on the main thread, so the change hops
   * there before anything is written or announced. */
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    [self applyProgress:progress message:message];
  }];
}

- (void)installDidOutputLine:(NSString *)line
{
  if ([line rangeOfString:@"rate limit"
                  options:NSCaseInsensitiveSearch].location == NSNotFound)
    return;
  /* Recorded on the main queue as well: setError: reads the flag from there,
   * and the downloader emits every line before it returns the failure, so
   * the queue's order guarantees the flag is set before the rewrite runs. */
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    _sawRateLimitOutput = YES;
  }];
}

#pragma mark - Private

/* Main queue only. A task that already ended does not restart because a
 * late callback landed: cancellation and failure are decisions the user or
 * the installer made after the last progress report. */
- (void)applyProgress:(float)progress message:(NSString *)message
{
  if (_state == AGInstallTaskStateDone ||
      _state == AGInstallTaskStateFailed ||
      _state == AGInstallTaskStateCancelled)
    return;

  _state = AGInstallTaskStateDownloading;
  _progress = progress;
  _message = [message copy];
  [self postChangeNotification];
}

/* Main queue only, which is where both notifications are promised to land. */
- (void)postChangeNotification
{
  [[NSNotificationCenter defaultCenter]
      postNotificationName:AGInstallerTaskDidChangeNotification
                    object:self];
}

/* The only writer of the error is AGInstaller's failure path, so the rate
 * limit rewrite sits in the setter instead of in a call the writer could
 * forget: every failure text passes through here exactly once. */
- (void)setError:(NSError *)error
{
  _error = AGRewrittenRateLimitError(error, _sawRateLimitOutput);
}

/* Defined only so the interface's NS_UNAVAILABLE entry has a body; the
 * attribute keeps callers out and the route to the designated initializer
 * keeps the compiler's initializer chain well formed. */
- (instancetype)init
{
  return [self initWithApp:nil];
}

@end
