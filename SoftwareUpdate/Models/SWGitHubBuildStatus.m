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
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
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

  @synchronized (self) {
    [_cache setObject:@(status) forKey:sha];
  }
  return status;
}

// Parses a check-runs response: no runs -> unknown; any run not yet
// completed -> running; any completed run that failed -> failed; otherwise
// passed. A response that cannot be parsed (network failure, rate limit) is
// treated as unknown - never as a false pass or fail.
- (SWBuildStatus)statusFromResponseData:(NSData *)data
{
  if (!data) return SWBuildStatusUnknown;

  NSError *error = nil;
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
  if (![json isKindOfClass:[NSDictionary class]]) return SWBuildStatusUnknown;

  NSArray *checkRuns = [(NSDictionary *)json objectForKey:@"check_runs"];
  if (![checkRuns isKindOfClass:[NSArray class]] || [checkRuns count] == 0) {
    return SWBuildStatusUnknown;
  }

  BOOL sawFailure = NO;
  for (NSDictionary *run in checkRuns) {
    NSString *runStatus = [run objectForKey:@"status"];
    if (![runStatus isEqualToString:@"completed"]) {
      return SWBuildStatusRunning; // queued or in_progress
    }
    NSString *conclusion = [run objectForKey:@"conclusion"];
    if ([conclusion isEqualToString:@"failure"] ||
        [conclusion isEqualToString:@"timed_out"] ||
        [conclusion isEqualToString:@"cancelled"]) {
      sawFailure = YES;
    }
  }
  return sawFailure ? SWBuildStatusFailed : SWBuildStatusPassed;
}

@end
