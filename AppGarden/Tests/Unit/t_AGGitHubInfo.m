/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_AGGitHubInfo.m - the star count, the page text and their cache. The fetches run against
 * file:// URLs: a directory tree stands in for github.com, so the tool proves
 * the behavior without the network. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "AGGitHubInfo.h"
#import "AGApp.h"

static NSNumber *sStars = nil;
static NSString *sText = nil;
static NSError *sError = nil;
static BOOL sDone = NO;

static void resetResult(void)
{
  [sStars release]; sStars = nil;
  [sText release]; sText = nil;
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

static void fetchText(AGGitHubInfo *info, NSString *repo)
{
  resetResult();
  [info pageTextForRepo: repo completion: ^(NSString *text, NSError *error) {
    sText = [text retain]; sError = [error retain]; sDone = YES;
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
      @"<a><span id=\"repo-stars-counter-star\" aria-label=\"x\" title=\"%@\" class=\"Counter\">1.2k</span></a>"
      "<article class=\"markdown-body\"><p>An AI coding workspace.</p></article>",
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

  /* --- the text of a repository page --- */
  {
    NSString *page = @"<html><head><meta name=\"description\" content=\"A tool &amp; more - own/repo\">"
                     "<script>var ai = 'agent'; var c = 'markdown-body';</script></head><body>"
                     "<article class=\"other\">Unrelated article words</article>"
                     "<nav>GitHub Copilot AI code creation Sign in</nav>"
                     "<div class=\"about\">About</div>"
                     "<article class=\"markdown-body entry-content\" itemprop=\"text\">"
                     "<h1>Title</h1><p>An <b>AI</b> coding workspace.</p>"
                     "<style>.x { color: red }</style><p>Second&nbsp;line &lt;ok&gt;</p></article>"
                     "<footer>Terms Privacy</footer></body></html>";
    NSString *text = [AGGitHubInfo pageTextFromRepositoryHTML: page];
    PASS(text != nil, "a page with a README has text");
    PASS([text rangeOfString: @"An AI coding workspace."].location != NSNotFound,
         "the README text is read with its tags dropped");
    PASS([text rangeOfString: @"A tool & more"].location != NSNotFound,
         "the description is read and its entities are decoded");
    PASS([text rangeOfString: @"Second line <ok>"].location != NSNotFound,
         "entities in the README are decoded");
    PASS([text rangeOfString: @"Unrelated"].location == NSNotFound,
         "an article that is not the README is not read");
    PASS([text rangeOfString: @"Copilot"].location == NSNotFound,
         "the menu around the README is not read");
    PASS([text rangeOfString: @"Sign in"].location == NSNotFound, "the page's chrome is not read");
    PASS([text rangeOfString: @"color"].location == NSNotFound, "style blocks are dropped");
    PASS([text rangeOfString: @"agent"].location == NSNotFound, "script blocks are dropped");
    PASS([text rangeOfString: @"  "].location == NSNotFound, "white space is collapsed");

    PASS([[AGGitHubInfo pageTextFromRepositoryHTML:
              @"<meta name=\"description\" content=\"Only a description\">"] isEqual: @"Only a description"],
         "a page with only a description has that text");
    PASS([AGGitHubInfo pageTextFromRepositoryHTML: @"<html><body>nothing</body></html>"] == nil,
         "a page with neither has no text");
    PASS([AGGitHubInfo pageTextFromRepositoryHTML: nil] == nil, "no page has no text");

    NSMutableString *big = [NSMutableString stringWithString:
        @"<article class=\"markdown-body\"><p>"];
    for (int i = 0; i < 5000; i++)
      [big appendString: @"word "];
    [big appendString: @"</p></article>"];
    PASS([[AGGitHubInfo pageTextFromRepositoryHTML: big] length] == AGGitHubPageTextLimit,
         "a long README is cut at the limit");
  }

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

  fetchText(info, @"owner/repo");
  PASS(sText != nil && sError == nil, "the page text comes from the same page");
  PASS([sText rangeOfString: @"AI"].location != NSNotFound, "the page text has the README");

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
