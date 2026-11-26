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

// --- Reading the Actions page ---------------------------------------------
//
// The page is a client side app: its run list is JSON in a script block, and
// GitHub moves and renames things in it without notice.  The API that is the
// alternative is limited to 60 requests an hour.  So runs are found by what a
// run must say, not by where it says it: it names a commit and says how it
// went.

typedef NS_ENUM(NSInteger, SWStateClass) {
  SWStateIgnored = 0,   // not a verdict: "completed" alone, "skipped", "active", ...
  SWStateRunning,
  SWStatePassed,
  SWStateFailed,
};

// Tolerant reading of a status or conclusion: any casing, with or without a
// WORKFLOW_RUN_STATUS_ style prefix.
// "completed" on its own says the run is over but not how it went, so it is
// ignored, as is anything unknown: neither can ever make a pass.
static SWStateClass SWClassifyState(NSString *raw)
{
  if (![raw isKindOfClass:[NSString class]] || [raw length] == 0 || [raw length] > 64) return SWStateIgnored;
  NSString *s = [raw lowercaseString];
  for (NSString *prefix in @[ @"workflow_run_status_", @"workflow_run_conclusion_", @"check_conclusion_state_",
                              @"check_status_state_" ]) {
    if ([s hasPrefix:prefix]) s = [s substringFromIndex:[prefix length]];
  }
  s = [[s stringByReplacingOccurrencesOfString:@"_" withString:@" "]
        stringByReplacingOccurrencesOfString:@"-" withString:@" "];
  for (NSString *w in @[ @"fail", @"unsuccessful", @"cancel", @"timed out", @"timeout", @"action required",
                         @"stopped", @"error" ]) {
    if ([s containsString:w]) return SWStateFailed;
  }
  for (NSString *w in @[ @"in progress", @"running", @"queued", @"pending", @"waiting", @"requested" ]) {
    if ([s containsString:w]) return SWStateRunning;
  }
  if ([s containsString:@"success"]) return SWStatePassed;
  return SWStateIgnored;
}

static BOOL SWIsSha40(NSString *s)
{
  if ([s length] != 40) return NO;
  NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
  return [s rangeOfCharacterFromSet:bad].location == NSNotFound;
}

// The sha of the first /commit/<40 hex> in a string, lower case, or nil.
static NSString *SWShaInCommitLink(NSString *s)
{
  NSRange at = [s rangeOfString:@"/commit/"];
  if (at.location == NSNotFound || NSMaxRange(at) + 40 > [s length]) return nil;
  NSString *sha = [s substringWithRange:NSMakeRange(NSMaxRange(at), 40)];
  return SWIsSha40(sha) ? [sha lowercaseString] : nil;
}

static BOOL SWShaMatches(NSString *runSha, NSString *wanted)
{
  return [runSha hasPrefix:wanted] || [wanted hasPrefix:runSha];
}

// Evidence found in an object (a commit link anywhere in a
// string value, or a 40 hex value under a key that has "sha" in its name; a
// recognised value under a key that has status, conclusion or state in its
// name) is passed up until an object holds both, and that object is a run.
// Evidence of different list entries is never mixed, so one run's commit
// cannot borrow another's verdict.
static void SWWalkJSON(id node, NSMutableArray *shas, NSMutableArray *states, NSMutableArray *runs)
{
  if ([node isKindOfClass:[NSArray class]]) {
    for (id element in node) {
      SWWalkJSON(element, [NSMutableArray array], [NSMutableArray array], runs);
    }
    return;
  }
  if (![node isKindOfClass:[NSDictionary class]]) return;

  NSMutableArray *ownShas = [NSMutableArray array], *ownStates = [NSMutableArray array];
  [node enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
    if ([value isKindOfClass:[NSString class]]) {
      NSString *lowerKey = [[key description] lowercaseString];
      NSString *linked = SWShaInCommitLink(value);
      if (linked) {
        [ownShas addObject:linked];
      } else if ([lowerKey containsString:@"sha"] && SWIsSha40(value)) {
        [ownShas addObject:[value lowercaseString]];
      }
      if ([lowerKey containsString:@"status"] || [lowerKey containsString:@"conclusion"]
          || [lowerKey containsString:@"state"]) {
        SWStateClass c = SWClassifyState(value);
        if (c != SWStateIgnored) [ownStates addObject:@(c)];
      }
    } else {
      SWWalkJSON(value, ownShas, ownStates, runs);
    }
  }];

  if ([ownShas count] > 0 && [ownStates count] > 0) {
    [runs addObject:@{ @"shas": ownShas, @"states": ownStates }];
  } else {
    [shas addObjectsFromArray:ownShas];
    [states addObjectsFromArray:ownStates];
  }
}

// The verdict for one commit from a set of state classes, or nil when there is
// none: any failed run makes it failed, else any run still going makes it
// running, else a passed run makes it passed.
static NSNumber *SWVerdict(BOOL failed, BOOL running, BOOL passed)
{
  if (failed) return @(SWBuildStatusFailed);
  if (running) return @(SWBuildStatusRunning);
  return passed ? @(SWBuildStatusPassed) : nil;
}

static NSNumber *SWStatusFromEmbeddedJSON(NSString *html, NSString *sha)
{
  NSRegularExpression *scripts = [NSRegularExpression regularExpressionWithPattern:@"<script\\b[^>]*>(.*?)</script>"
                                                                           options:NSRegularExpressionDotMatchesLineSeparators
                                                                             error:NULL];
  BOOL failed = NO, running = NO, passed = NO;
  for (NSTextCheckingResult *m in [scripts matchesInString:html options:0 range:NSMakeRange(0, [html length])]) {
    NSString *body = [[html substringWithRange:[m rangeAtIndex:1]]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([body length] == 0 || ([body characterAtIndex:0] != '{' && [body characterAtIndex:0] != '[')) continue;
    id json = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding]
                                              options:0 error:NULL];
    if (!json) continue;
    NSMutableArray *runs = [NSMutableArray array];
    SWWalkJSON(json, [NSMutableArray array], [NSMutableArray array], runs);
    for (NSDictionary *run in runs) {
      BOOL mine = NO;
      for (NSString *runSha in run[@"shas"]) {
        if (SWShaMatches(runSha, sha)) { mine = YES; break; }
      }
      if (!mine) continue;
      for (NSNumber *c in run[@"states"]) {
        switch ((SWStateClass)[c integerValue]) {
          case SWStateFailed: failed = YES; break;
          case SWStateRunning: running = YES; break;
          case SWStatePassed: passed = YES; break;
          default: break;
        }
      }
    }
  }
  return SWVerdict(failed, running, passed);
}

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

// Reads the run list of an Actions page for one commit.  Of the runs for it:
// any failed run makes it failed, else any run still going makes it running,
// else a passed run makes it passed.  nil when the page has no verdict for the
// commit or no JSON, so that the caller asks the API instead.  Never a guess.
- (NSNumber *)statusFromActionsPageData:(NSData *)data forSha:(NSString *)sha
{
  if (!data || [sha length] < 7) return nil;
  NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if ([html length] == 0) return nil;
  NSNumber *answer = SWStatusFromEmbeddedJSON(html, [sha lowercaseString]);
  // Logged so that a future change of the page shows up as a missing answer.
  NSDebugLog(@"SWGitHubBuildStatus: Actions page %@ for %@",
             answer ? @"answered" : @"had no verdict", sha);
  return answer;
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
