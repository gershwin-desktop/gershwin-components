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
 * The downloader's failure text names the step that failed and now usually the
 * reason as well ("No release of owner/repo has an AppImage", "The newest
 * release of owner/repo has several AppImages and none of them is clearly the
 * right one for this machine: ..."), but a refusal by GitHub is still
 * indistinguishable from a network fault in it. The evidence lives in curl's
 * own output, which reaches this task through installDidOutputLine: - the one
 * channel that carries raw tool output - or, when the failure text itself
 * already says so, in the text. Either way the rewrite happens here so the
 * framework itself stays untouched (section 8 of the brief).
 *
 * curl is run with -f, so the server's own words ("API rate limit exceeded")
 * never reach us: on a refused response curl writes only the status line.
 * That status is the evidence that does arrive, and GitHub answers an
 * unauthenticated client that has used its quota with 403 (429 for a burst),
 * so a status line from curl together with a failure the text already pins on
 * GitHub is the same fact the phrase would have told us.
 */
static BOOL AGOutputSaidRateLimitPhrase(NSString *line)
{
  return [line rangeOfString:@"rate limit"
                     options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL AGOutputSaidRefusal(NSString *line)
{
  /* curl's own wording for an HTTP error with -f: "The requested URL
   * returned error: 403", newer versions appending the reason name.
   * Matched with the words around the number so a "403" in a URL or a byte
   * count cannot read as a refusal. */
  NSRange hit = [line rangeOfString:@"returned error: 403"
                           options:NSCaseInsensitiveSearch];
  if (hit.location == NSNotFound)
    hit = [line rangeOfString:@"returned error: 429"
                      options:NSCaseInsensitiveSearch];
  return hit.location != NSNotFound;
}

static NSError *AGRewrittenRateLimitError(NSError *error,
                                          BOOL outputSaidRateLimit,
                                          BOOL outputSaidRefusal)
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
    {
      /* The refusal only counts when the failure is a GitHub one: a mirror
       * or a download page answering 403 says nothing about a quota. */
      BOOL textSaysGitHub =
          [original rangeOfString:@"github"
                          options:NSCaseInsensitiveSearch].location != NSNotFound;
      if (!outputSaidRefusal || !textSaysGitHub)
        return error;
    }
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
  BOOL _sawRefusalOutput;
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
  if (line == nil)
    return;
  BOOL saidRateLimit = AGOutputSaidRateLimitPhrase(line);
  BOOL saidRefusal = AGOutputSaidRefusal(line);
  if (!saidRateLimit && !saidRefusal)
    return;
  /* Recorded on the main queue as well: setError: reads the flags from there,
   * and the downloader emits every line before it returns the failure, so
   * the queue's order guarantees the flags are set before the rewrite runs. */
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    if (saidRateLimit)
      _sawRateLimitOutput = YES;
    if (saidRefusal)
      _sawRefusalOutput = YES;
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
  _error = AGRewrittenRateLimitError(error, _sawRateLimitOutput,
                                     _sawRefusalOutput);
}

/* Defined only so the interface's NS_UNAVAILABLE entry has a body; the
 * attribute keeps callers out and the route to the designated initializer
 * keeps the compiler's initializer chain well formed. */
- (instancetype)init
{
  return [self initWithApp:nil];
}

@end
