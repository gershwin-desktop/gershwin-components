/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_AGGitHubInfo.m - star count, account age and their cache. The fetches
 * run against file:// URLs: a directory tree stands in for github.com and
 * another for api.github.com, so the tool proves the behavior without the
 * network. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "AGGitHubInfo.h"
#import "AGApp.h"

static NSNumber *sStars = nil;
static NSDate *sDate = nil;
static NSError *sError = nil;
static BOOL sDone = NO;

static void resetResult(void)
{
  [sStars release]; sStars = nil;
  [sDate release]; sDate = nil;
  [sError release]; sError = nil;
  sDone = NO;
}

static BOOL waitDone(void)
{
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: 20.0];
  while (!sDone && [deadline timeIntervalSinceNow] > 0)
    [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                             beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.05]];
  return sDone;
}

static void fetchStars(AGGitHubInfo *info, NSString *repo)
{
  resetResult();
  [info starsForRepo: repo completion: ^(NSNumber *stars, NSError *error) {
    sStars = [stars retain]; sError = [error retain]; sDone = YES;
  }];
  waitDone();
}

static void fetchDate(AGGitHubInfo *info, NSString *owner)
{
  resetResult();
  [info accountCreationDateForOwner: owner completion: ^(NSDate *date, NSError *error) {
    sDate = [date retain]; sError = [error retain]; sDone = YES;
  }];
  waitDone();
}

static void writeFile(NSString *path, NSString *text)
{
  [[NSFileManager defaultManager] createDirectoryAtPath: [path stringByDeletingLastPathComponent]
                            withIntermediateDirectories: YES attributes: nil error: NULL];
  [text writeToFile: path atomically: YES encoding: NSUTF8StringEncoding error: NULL];
}

static NSString *counterPage(NSString *title)
{
  return [NSString stringWithFormat:
      @"<a><span id=\"repo-stars-counter-star\" aria-label=\"x\" title=\"%@\" class=\"Counter\">1.2k</span></a>",
      title];
}

int main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];

  /* --- the pure parts --- */
  PASS_EQUAL([AGGitHubInfo ownerOfRepo: @"rishabh3354/4KWALL"], @"rishabh3354",
             "the owner is the part before the slash");
  PASS([AGGitHubInfo ownerOfRepo: @"nonsense"] == nil, "no slash is no repository");
  PASS([AGGitHubInfo ownerOfRepo: @"a/b/c"] == nil, "three parts is no repository");
  PASS([AGGitHubInfo ownerOfRepo: @"a/b; rm -rf"] == nil, "a repository name is not a command");

  PASS_EQUAL([AGGitHubInfo starCountFromRepositoryHTML: counterPage(@"1,234")],
             [NSNumber numberWithInt: 1234], "the exact count comes from the title");
  PASS_EQUAL([AGGitHubInfo starCountFromRepositoryHTML: counterPage(@"7")],
             [NSNumber numberWithInt: 7], "a single digit works");
  PASS([AGGitHubInfo starCountFromRepositoryHTML: counterPage(@"many")] == nil,
       "a title that is not a number is no count");
  PASS([AGGitHubInfo starCountFromRepositoryHTML: @"<html>nothing</html>"] == nil,
       "a page without the counter has no count");

  NSError *error = nil;
  NSDate *date = [AGGitHubInfo creationDateFromUserJSON:
      [@"{\"login\":\"x\",\"created_at\":\"2011-01-25T18:44:36Z\"}" dataUsingEncoding: NSUTF8StringEncoding]
                                                  error: &error];
  PASS(date != nil && error == nil, "created_at is read");
  PASS([date timeIntervalSince1970] == 1295981076.0, "created_at is the right moment");
  date = [AGGitHubInfo creationDateFromUserJSON:
      [@"{\"message\":\"API rate limit exceeded for 1.2.3.4.\"}" dataUsingEncoding: NSUTF8StringEncoding]
                                          error: &error];
  PASS(date == nil && error != nil, "an answer without created_at is an error");
  PASS([[error localizedDescription] rangeOfString: @"rate limit"].location != NSNotFound,
       "the rate limit is named as such");
  date = [AGGitHubInfo creationDateFromUserJSON: [NSData data] error: &error];
  PASS(date == nil && error != nil, "an empty answer is an error");

  NSDate *now = [NSDate dateWithTimeIntervalSince1970: 1000000.0];
  PASS_EQUAL([NSNumber numberWithInteger:
                 [AGGitHubInfo daysFromDate: [now dateByAddingTimeInterval: -29.5 * 86400.0] toDate: now]],
             [NSNumber numberWithInt: 29], "29.5 days is 29 whole days");
  PASS_EQUAL([NSNumber numberWithInteger:
                 [AGGitHubInfo daysFromDate: [now dateByAddingTimeInterval: -30.0 * 86400.0] toDate: now]],
             [NSNumber numberWithInt: 30], "30 days is 30 whole days");
  PASS_EQUAL([NSNumber numberWithInteger:
                 [AGGitHubInfo daysFromDate: [now dateByAddingTimeInterval: 86400.0] toDate: now]],
             [NSNumber numberWithInt: 0], "a date in the future is 0 days");
  PASS(AGGitHubMinimumAccountAgeDays == 30, "the threshold is 30 days");

  PASS([AGGitHubInfo warningForAccountCreatedOn: [now dateByAddingTimeInterval: -30.0 * 86400.0] now: now] == nil,
       "an account of 30 days is old enough");
  PASS([AGGitHubInfo warningForAccountCreatedOn: [now dateByAddingTimeInterval: -400.0 * 86400.0] now: now] == nil,
       "an old account has no warning");
  PASS_EQUAL([AGGitHubInfo warningForAccountCreatedOn: [now dateByAddingTimeInterval: -29.0 * 86400.0] now: now],
             @"The publisher's GitHub account is only 29 days old.",
             "29 days is a warning that says 29 days");
  PASS_EQUAL([AGGitHubInfo warningForAccountCreatedOn: [now dateByAddingTimeInterval: -86400.0 * 1.5] now: now],
             @"The publisher's GitHub account is only 1 day old.", "one day is singular");
  PASS_EQUAL([AGGitHubInfo warningForAccountCreatedOn: [now dateByAddingTimeInterval: -3600.0] now: now],
             @"The publisher's GitHub account was created today.", "under a day is today");
  PASS([[AGGitHubInfo warningForAccountCreatedOn: nil now: now] rangeOfString: @"could not check"].location != NSNotFound,
       "an unknown date is a warning that says so");

  /* --- the repository an app comes from --- */
  {
    NSDictionary *named = @{ @"name": @"A", @"links": @[
        @{ @"type": @"GitHub", @"url": @"own/named" },
        @{ @"type": @"Download", @"url": @"https://github.com/other/place/releases/download/v1/A.AppImage" } ] };
    NSDictionary *direct = @{ @"name": @"B", @"links": @[
        @{ @"type": @"Download", @"url": @"https://github.com/own/direct/releases/download/v1/B-x86_64.AppImage" } ] };
    NSDictionary *www = @{ @"name": @"C", @"links": @[
        @{ @"type": @"Download", @"url": @"https://WWW.GitHub.com/own/www/releases/download/v1/C.AppImage" } ] };
    NSDictionary *elsewhere = @{ @"name": @"D", @"links": @[
        @{ @"type": @"Download", @"url": @"https://example.org/own/direct/D.AppImage" } ] };
    NSDictionary *shortPath = @{ @"name": @"E", @"links": @[
        @{ @"type": @"Download", @"url": @"https://github.com/own" } ] };
    PASS_EQUAL([AGGitHubInfo repositoryForApp: [[AGApp alloc] initWithFeedItem: named]], @"own/named",
               "the feed's repository wins");
    PASS_EQUAL([AGGitHubInfo repositoryForApp: [[AGApp alloc] initWithFeedItem: direct]], @"own/direct",
               "a direct link on github.com names its repository");
    PASS_EQUAL([AGGitHubInfo repositoryForApp: [[AGApp alloc] initWithFeedItem: www]], @"own/www",
               "www.github.com and capital letters in the host are the same host");
    PASS([AGGitHubInfo repositoryForApp: [[AGApp alloc] initWithFeedItem: elsewhere]] == nil,
         "a link on another host is not GitHub");
    PASS([AGGitHubInfo repositoryForApp: [[AGApp alloc] initWithFeedItem: shortPath]] == nil,
         "a link without a repository is not a repository");
    PASS([AGGitHubInfo repositoryForApp: nil] == nil, "no app is no repository");
  }

  /* --- fetching and caching --- */
  NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat: @"agghi-%d", getpid()]];
  [[NSFileManager defaultManager] removeItemAtPath: root error: NULL];
  NSString *web = [root stringByAppendingPathComponent: @"web"];
  NSString *api = [root stringByAppendingPathComponent: @"api"];
  NSString *cache = [root stringByAppendingPathComponent: @"cache"];
  NSString *webURL = [[NSURL fileURLWithPath: web] absoluteString];
  NSString *apiURL = [[NSURL fileURLWithPath: api] absoluteString];
  writeFile([web stringByAppendingPathComponent: @"owner/repo"], counterPage(@"4,321"));
  writeFile([web stringByAppendingPathComponent: @"owner/bare"], @"<html></html>");
  writeFile([api stringByAppendingPathComponent: @"users/owner"],
            @"{\"created_at\":\"2020-03-01T00:00:00Z\"}");
  writeFile([api stringByAppendingPathComponent: @"users/limited"],
            @"{\"message\":\"API rate limit exceeded\"}");

  AGGitHubInfo *info = [[AGGitHubInfo alloc] initWithCacheDirectory: cache
                                                         webBaseURL: webURL
                                                         apiBaseURL: apiURL];
  fetchStars(info, @"owner/repo");
  PASS_EQUAL(sStars, [NSNumber numberWithInt: 4321], "the stars are fetched");
  PASS(sError == nil, "fetching the stars is not an error");

  [[NSFileManager defaultManager] removeItemAtPath: [web stringByAppendingPathComponent: @"owner/repo"] error: NULL];
  fetchStars(info, @"owner/repo");
  PASS_EQUAL(sStars, [NSNumber numberWithInt: 4321],
             "a second ask within six hours is answered from the cache");

  fetchStars(info, @"owner/gone");
  PASS(sStars == nil && sError != nil, "an unreachable page is an error");
  fetchStars(info, @"owner/bare");
  PASS(sStars == nil && sError != nil, "a page without a counter is an error");
  fetchStars(info, @"not a repo");
  PASS(sStars == nil && sError != nil, "a bad name is an error");

  fetchDate(info, @"owner");
  PASS(sDate != nil && sError == nil, "the account date is fetched");
  PASS([sDate timeIntervalSince1970] == 1583020800.0, "the account date is created_at");

  [[NSFileManager defaultManager] removeItemAtPath: [api stringByAppendingPathComponent: @"users/owner"] error: NULL];
  fetchDate(info, @"owner");
  PASS(sDate != nil, "a known account is answered from the cache");

  /* A new object reads the file the first one wrote. */
  [info release];
  info = [[AGGitHubInfo alloc] initWithCacheDirectory: cache webBaseURL: webURL apiBaseURL: apiURL];
  fetchDate(info, @"owner");
  PASS(sDate != nil, "the account date survives a restart");
  fetchStars(info, @"owner/repo");
  PASS_EQUAL(sStars, [NSNumber numberWithInt: 4321], "the star count survives a restart");

  fetchDate(info, @"limited");
  PASS(sDate == nil && sError != nil, "a refusal is an error");
  PASS([[sError localizedDescription] rangeOfString: @"rate limit"].location != NSNotFound,
       "a refusal names the rate limit");
  fetchDate(info, @"nobody");
  PASS(sDate == nil && sError != nil, "an unknown account is an error");

  [info release];
  [[NSFileManager defaultManager] removeItemAtPath: root error: NULL];
  resetResult();
  [pool release];
  return 0;
}
