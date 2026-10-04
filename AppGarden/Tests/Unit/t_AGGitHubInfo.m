/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_AGGitHubInfo.m - the star count and its cache. The fetches run against
 * file:// URLs: a directory tree stands in for github.com, so the tool proves
 * the behavior without the network. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "AGGitHubInfo.h"
#import "AGApp.h"

static NSNumber *sStars = nil;
static NSError *sError = nil;
static BOOL sDone = NO;

static void resetResult(void)
{
  [sStars release]; sStars = nil;
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
  NSString *cache = [root stringByAppendingPathComponent: @"cache"];
  NSString *webURL = [[NSURL fileURLWithPath: web] absoluteString];
  writeFile([web stringByAppendingPathComponent: @"owner/repo"], counterPage(@"4,321"));
  writeFile([web stringByAppendingPathComponent: @"owner/bare"], @"<html></html>");

  AGGitHubInfo *info = [[AGGitHubInfo alloc] initWithCacheDirectory: cache
                                                         webBaseURL: webURL];
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

  /* A new object reads the file the first one wrote. */
  [info release];
  info = [[AGGitHubInfo alloc] initWithCacheDirectory: cache webBaseURL: webURL];
  fetchStars(info, @"owner/repo");
  PASS_EQUAL(sStars, [NSNumber numberWithInt: 4321], "the star count survives a restart");

  [info release];
  [[NSFileManager defaultManager] removeItemAtPath: root error: NULL];
  resetResult();
  [pool release];
  return 0;
}
