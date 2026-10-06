/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWGitHubBuildStatus.h"

@interface SWGitHubBuildStatus ()
{
  SWHTTPFetcher _fetcher;
  NSMutableDictionary<NSString *, NSNumber *> *_cache; // sha -> SWBuildStatus
}
@end

@implementation SWGitHubBuildStatus

- (instancetype)initWithFetcher:(SWHTTPFetcher)fetcher
{
  self = [super init];
  if (self) {
    _fetcher = fetcher ? (SWHTTPFetcher)[fetcher copy] : [self defaultFetcher];
    _cache = [NSMutableDictionary dictionary];
  }
  return self;
}

- (SWHTTPFetcher)defaultFetcher
{
  return [^NSData *(NSURL *url) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    // GitHub's API rejects requests with no User-Agent.
    [request setValue:@"gershwin-desktop-software-update" forHTTPHeaderField:@"User-Agent"];
    // The API is asked for JSON, the Actions page for HTML.
    [request setValue:([[url host] isEqualToString:@"github.com"] ? @"text/html"
                                                                   : @"application/vnd.github+json")
        forHTTPHeaderField:@"Accept"];
    // Without a token GitHub allows 60 requests an hour per address, which a
    // few checks use up; with one, the limit is far higher.
    NSDictionary *env = [[NSProcessInfo processInfo] environment];
    NSString *token = [env objectForKey:@"GITHUB_TOKEN"] ?: [env objectForKey:@"GH_TOKEN"];
    if ([token length] > 0)
      [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    NSURLResponse *response = nil;
    NSError *error = nil;
    return [NSURLConnection sendSynchronousRequest:request
                                  returningResponse:&response
                                              error:&error];
  } copy];
}

- (void)clearCache
{
  @synchronized (self) {
    [_cache removeAllObjects];
  }
}

// SWUpdateChecker checks several repositories concurrently (see
// -checkRepositories:...), each potentially calling in here with its own
// sha at the same time. NSMutableDictionary is not safe for concurrent
// mutation even when the keys never collide (which they won't - each
// repository's tip sha is its own), so the read-check/fetch/write-back
// still needs to be serialized; @synchronized only guards the dictionary
// access, not the network fetch itself, so concurrent lookups for
// different shas still overlap where it matters (the slow part).
- (SWBuildStatus)statusForRepositoryNamed:(NSString *)repoName sha:(NSString *)sha
{
  if ([sha length] == 0) return SWBuildStatusUnknown;

  NSNumber *cached;
  @synchronized (self) {
    cached = [_cache objectForKey:sha];
  }
  if (cached) return (SWBuildStatus)[cached integerValue];

  NSString *urlString = [NSString stringWithFormat:
    @"https://api.github.com/repos/gershwin-desktop/%@/commits/%@/check-runs", repoName, sha];
  NSData *data = _fetcher([NSURL URLWithString:urlString]);
  SWBuildStatus status = [self statusFromResponseData:data];

  // An answer that is no answer (rate limit, no network) is not kept, so the
  // next ask asks again, and it is not a pass.
  if (status != SWBuildStatusUnavailable) {
    @synchronized (self) {
      [_cache setObject:@(status) forKey:sha];
    }
  }
  return status;
}

- (SWBuildStatus)statusForRepositoryNamed:(NSString *)repoName
                                    branch:(NSString *)branch
                                    tipSha:(NSString *)tipSha
{
  if ([tipSha length] == 0 || [branch length] == 0) {
    return [self statusForRepositoryNamed:repoName sha:tipSha];
  }

  NSNumber *cached;
  @synchronized (self) {
    cached = [_cache objectForKey:tipSha];
  }
  if (cached) return (SWBuildStatus)[cached integerValue];

  NSString *urlString = [NSString stringWithFormat:
    @"https://github.com/gershwin-desktop/%@/actions?query=branch%%3A%@+event%%3Apush",
    repoName, [branch stringByAddingPercentEncodingWithAllowedCharacters:
      [NSCharacterSet alphanumericCharacterSet]]];
  NSData *page = _fetcher([NSURL URLWithString:urlString]);
  NSNumber *scraped = [self statusFromActionsPageData:page forSha:tipSha];
  if (scraped) {
    @synchronized (self) {
      [_cache setObject:scraped forKey:tipSha];
    }
    return (SWBuildStatus)[scraped integerValue];
  }

  // The page said nothing about this commit: ask the API.
  return [self statusForRepositoryNamed:repoName sha:tipSha];
}

// Reads the run rows of an Actions page.  A row holds the commit its run is
// for (a link to /commit/<sha>) and the state of the run in the label of its
// icon: "currently running", "queued", "failed", "cancelled", "completed
// successfully" and the like.  Of the rows for this commit: any failed run
// makes it failed, else any run still going makes it running, else a passed
// run makes it passed.  nil when no row is for this commit or the page is not
// understood, so that the caller asks the API instead.
- (NSNumber *)statusFromActionsPageData:(NSData *)data forSha:(NSString *)sha
{
  if (!data || [sha length] < 7) return nil;
  NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if ([html length] == 0) return nil;

  NSError *error = nil;
  NSRegularExpression *rowStart = [NSRegularExpression regularExpressionWithPattern:@"class=\"[^\"]*Box-row"
                                                                              options:0
                                                                                error:&error];
  NSRegularExpression *label = [NSRegularExpression regularExpressionWithPattern:@"aria-label=\"([A-Za-z ]+): "
                                                                         options:0
                                                                           error:&error];
  NSRegularExpression *commit = [NSRegularExpression regularExpressionWithPattern:@"/commit/([0-9a-f]{40})"
                                                                          options:0
                                                                            error:&error];
  if (error) return nil;

  NSArray<NSTextCheckingResult *> *starts = [rowStart matchesInString:html options:0 range:NSMakeRange(0, [html length])];
  BOOL failed = NO, running = NO, passed = NO, seen = NO;
  NSString *lowerSha = [sha lowercaseString];

  for (NSUInteger i = 0; i < [starts count]; i++) {
    NSUInteger from = [starts[i] range].location;
    NSUInteger to = (i + 1 < [starts count]) ? [starts[i + 1] range].location : [html length];
    NSRange rowRange = NSMakeRange(from, to - from);

    NSTextCheckingResult *c = [commit firstMatchInString:html options:0 range:rowRange];
    if (!c) continue;
    NSString *rowSha = [html substringWithRange:[c rangeAtIndex:1]];
    if (![rowSha hasPrefix:lowerSha] && ![lowerSha hasPrefix:rowSha]) continue;

    NSTextCheckingResult *l = [label firstMatchInString:html options:0 range:rowRange];
    if (!l) continue;
    NSString *state = [[html substringWithRange:[l rangeAtIndex:1]] lowercaseString];

    if ([state hasPrefix:@"failed"] || [state hasPrefix:@"cancel"] || [state hasPrefix:@"timed"]
        || [state hasPrefix:@"stopped"]) {
      failed = YES; seen = YES;
    } else if ([state hasPrefix:@"currently"] || [state hasPrefix:@"queued"] || [state hasPrefix:@"waiting"]
               || [state hasPrefix:@"pending"] || [state hasPrefix:@"in progress"]) {
      running = YES; seen = YES;
    } else if ([state hasPrefix:@"completed"] || [state hasPrefix:@"success"]) {
      passed = YES; seen = YES;
    }                                        // skipped and the like count for nothing
  }

  if (!seen) return nil;
  if (failed) return @(SWBuildStatusFailed);
  if (running) return @(SWBuildStatusRunning);
  return passed ? @(SWBuildStatusPassed) : nil;
}

// Parses a check-runs response: no runs -> unknown; any check that has not
// passed and is still running -> running; any check that failed -> failed;
// otherwise passed. A response that cannot be parsed (network failure, rate
// limit) is treated as unknown - never as a false pass or fail.
//
// A commit usually has the same check twice: a workflow starts on the push
// and again on the pull request, and a failed job may have been run again.
// One run of a check that passed is enough for that check, so a flaky job in
// one of the runs does not block an update the other run proved good; runs
// without a name are told apart by their position.
- (SWBuildStatus)statusFromResponseData:(NSData *)data
{
  if (!data) return SWBuildStatusUnavailable;

  NSError *error = nil;
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
  if (![json isKindOfClass:[NSDictionary class]]) return SWBuildStatusUnavailable;

  NSArray *checkRuns = [(NSDictionary *)json objectForKey:@"check_runs"];
  if (![checkRuns isKindOfClass:[NSArray class]]) {
    return SWBuildStatusUnavailable;       // an error body, e.g. the rate limit message
  }
  if ([checkRuns count] == 0) {
    return SWBuildStatusUnknown;           // a commit with no checks at all
  }

  NSMutableSet *passedChecks = [NSMutableSet set];
  NSMutableSet *runningChecks = [NSMutableSet set];
  NSMutableSet *failedChecks = [NSMutableSet set];

  NSUInteger position = 0;
  for (NSDictionary *run in checkRuns) {
    NSString *name = [run objectForKey:@"name"];
    NSString *key = [name length] > 0 ? name : [NSString stringWithFormat:@"#%lu", (unsigned long)position];
    position++;

    NSString *runStatus = [run objectForKey:@"status"];
    if (![runStatus isEqualToString:@"completed"]) {
      [runningChecks addObject:key]; // queued or in_progress
      continue;
    }
    NSString *conclusion = [run objectForKey:@"conclusion"];
    if ([conclusion isEqualToString:@"failure"] ||
        [conclusion isEqualToString:@"timed_out"] ||
        [conclusion isEqualToString:@"cancelled"]) {
      [failedChecks addObject:key];
    } else {
      [passedChecks addObject:key];
    }
  }

  [failedChecks minusSet:passedChecks];
  [runningChecks minusSet:passedChecks];

  if ([failedChecks count] > 0) return SWBuildStatusFailed;
  if ([runningChecks count] > 0) return SWBuildStatusRunning;
  return SWBuildStatusPassed;
}

@end
