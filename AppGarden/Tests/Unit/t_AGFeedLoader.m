/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_AGFeedLoader.m - the catalog cache and refresh rules of AGFeedLoader.
 * Every URL is a file:// URL, so the tool proves the cache behavior without
 * touching the network: a source file stands in for the feed, a path that
 * does not exist stands in for an unreachable server, and a cache file whose
 * modification time is newer than the source makes curl -z answer exactly
 * the way a 304 Not Modified does (exit 0, no output file). */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "AGFeedLoader.h"
#import "AGCatalog.h"
#import "AGApp.h"

/* The tool runs with the Tests/Unit directory as its working directory
 * (the test runner changes into the suite before running each tool). */
static NSString *const fixturePath = @"../../Fixtures/feed-sample.json";

/* The result of the load being waited on. File-scope, so the completion
 * block captures nothing and keeps alive what the loader hands it after
 * the loader's own references are released. */
static AGCatalog *sCatalog = nil;
static NSError *sError = nil;
static BOOL sFromCache = NO;
static BOOL sDone = NO;

static const char *errorText(NSError *error)
{
  return (error != nil) ? [[error localizedDescription] UTF8String]
                        : "(no error)";
}

static void resetResult(void)
{
  [sCatalog release];
  sCatalog = nil;
  [sError release];
  sError = nil;
  sFromCache = NO;
  sDone = NO;
}

static void startLoad(AGFeedLoader *loader, BOOL reload)
{
  resetResult();
  AGFeedLoadCompletion completion = ^(AGCatalog *catalog, BOOL fromCache,
                                      NSError *error) {
    sCatalog = [catalog retain];
    sError = [error retain];
    sFromCache = fromCache;
    sDone = YES;
  };
  if (reload)
    [loader reloadIgnoringCacheWithCompletion: completion];
  else
    [loader loadWithCompletion: completion];
}

static BOOL waitForLoad(NSTimeInterval timeout)
{
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: timeout];
  while (!sDone && [deadline timeIntervalSinceNow] > 0)
    {
      [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                               beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.05]];
    }
  return sDone;
}

static void setFeedURL(NSString *path)
{
  /* fileURLWithPath: percent-encodes the path, which is what curl wants in
   * a file:// URL built from a temporary directory. */
  NSURL *url = [NSURL fileURLWithPath: path];
  [[NSUserDefaults standardUserDefaults] setObject: [url absoluteString]
                                            forKey: @"AGFeedURL"];
}

static NSString *dateFilePath(NSString *cacheDir)
{
  return [cacheDir stringByAppendingPathComponent: @"feed.json.date"];
}

static NSString *readDateFile(NSString *cacheDir)
{
  return [NSString stringWithContentsOfFile: dateFilePath(cacheDir)
                                   encoding: NSUTF8StringEncoding
                                      error: NULL];
}

static BOOL writeDateFile(NSString *cacheDir, NSDate *date)
{
  NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
  NSString *text = [formatter stringFromDate: date];
  return [text writeToFile: dateFilePath(cacheDir)
                atomically: YES
                  encoding: NSUTF8StringEncoding
                     error: NULL];
}

static void setModificationDate(NSString *path, NSDate *date)
{
  [[NSFileManager defaultManager]
      setAttributes: @{ NSFileModificationDate: date }
       ofItemAtPath: path
              error: NULL];
}

static NSUInteger entryCount(NSString *dir)
{
  NSArray *entries = [[NSFileManager defaultManager]
      contentsOfDirectoryAtPath: dir error: NULL];
  return [entries count];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSFileManager *fm = [NSFileManager defaultManager];

  NSString *runDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat: @"t_AGFeedLoader-%d", (int)getpid()]];
  [fm removeItemAtPath: runDir error: NULL];
  [fm createDirectoryAtPath: runDir
       withIntermediateDirectories: YES
                    attributes: NULL
                         error: NULL];
  NSString *cacheDir = [runDir stringByAppendingPathComponent: @"cache"];
  NSString *sourcePath = [runDir stringByAppendingPathComponent: @"source.json"];
  NSString *gonePath = [runDir stringByAppendingPathComponent: @"gone.json"];

  NSData *fixtureBytes = [NSData dataWithContentsOfFile: fixturePath];
  PASS(fixtureBytes != nil, "the fixture %s is readable", [fixturePath UTF8String]);
  [fixtureBytes writeToFile: sourcePath atomically: YES];

  /* --- the cache must never be the user's own, proven before any write --- */
  AGFeedLoader *loader = [[AGFeedLoader alloc] initWithCacheDirectory: cacheDir];
  NSString *expectedCachePath = [cacheDir stringByAppendingPathComponent: @"feed.json"];
  PASS_EQUAL([loader cachePath], expectedCachePath,
             "the cache file sits inside the directory the test handed out: %s",
             [[loader cachePath] UTF8String]);
  PASS([loader isLoading] == NO, "a fresh loader is not loading");
  PASS_EQUAL(AGFeedURLString, @"https://appimage.github.io/feed.json",
             "the default feed URL is the catalog site");

  /* --- 1. the first load fetches, parses and stores --- */
  setFeedURL(sourcePath);
  startLoad(loader, NO);
  PASS([loader isLoading], "loading is YES while the first load is in flight");
  PASS(waitForLoad(30.0), "the first load completes");
  PASS(sError == nil, "the first load reports no error: %s", errorText(sError));
  PASS(sFromCache == NO, "the first load came from the network");
  PASS(sCatalog != nil && [[sCatalog apps] count] == 16,
       "the first load parses all 16 fixture items (got %lu)",
       (sCatalog != nil) ? (unsigned long)[[sCatalog apps] count] : 0UL);
  PASS([loader isLoading] == NO, "loading is clear once the completion ran");

  PASS([fm fileExistsAtPath: [loader cachePath]],
       "the fetched feed lands in the cache file");
  NSData *cachedBytes = [NSData dataWithContentsOfFile: [loader cachePath]];
  PASS(cachedBytes != nil && [cachedBytes isEqualToData: fixtureBytes],
       "the cache holds byte for byte what was fetched");

  NSString *dateText = readDateFile(cacheDir);
  PASS(dateText != nil, "the fetch date file exists");
  NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
  NSDate *fetchDate = [formatter dateFromString: dateText];
  PASS(fetchDate != nil, "the fetch date is written in ISO 8601: %s",
       (dateText != nil) ? [dateText UTF8String] : "(missing)");
  PASS(fetchDate != nil && -[fetchDate timeIntervalSinceNow] < 3600.0,
       "the fetch date says now");

  /* --- 2. a young cache answers with no network at all --- */
  /* The URL now points at a file that does not exist: only the cache can
   * satisfy this load, so any request would put an error in the result. */
  setFeedURL(gonePath);
  startLoad(loader, NO);
  PASS(waitForLoad(30.0), "the cached load completes");
  PASS(sError == nil, "a young cache is served without any request: %s",
       errorText(sError));
  PASS(sFromCache == YES, "the cached load is marked fromCache YES");
  PASS(sCatalog != nil && [[sCatalog apps] count] == 16,
       "the cached catalog is complete");

  /* --- 2b. the default max age is 6 hours: 5 hours still counts --- */
  PASS(writeDateFile(cacheDir, [NSDate dateWithTimeIntervalSinceNow: -5.0 * 3600.0]),
       "a 5 hour old date is written for the max age check");
  startLoad(loader, NO);
  PASS(waitForLoad(30.0), "the load with a 5 hour old cache completes");
  PASS(sError == nil && sFromCache == YES,
       "a 5 hour old cache is still inside the default 6 hour max age: %s",
       errorText(sError));

  /* --- 2c. AGCacheMaxAgeHours is read, never hard-coded --- */
  [[NSUserDefaults standardUserDefaults] setDouble: 1.0
                                             forKey: @"AGCacheMaxAgeHours"];
  PASS(writeDateFile(cacheDir, [NSDate dateWithTimeIntervalSinceNow: -2.0 * 3600.0]),
       "a 2 hour old date is written for the max age key check");
  startLoad(loader, NO);
  PASS(waitForLoad(30.0), "the load with a shortened max age completes");
  PASS(sError != nil,
       "AGCacheMaxAgeHours is read: a 2 hour old cache is refused when the max age is 1: %s",
       errorText(sError));
  PASS(sCatalog != nil && sFromCache == YES,
       "the refused load still serves the cached catalog beside the error");
  [[NSUserDefaults standardUserDefaults] removeObjectForKey: @"AGCacheMaxAgeHours"];

  /* --- 3. a conditional request that comes back unchanged (304) --- */
  setFeedURL(sourcePath);
  PASS(writeDateFile(cacheDir, [NSDate dateWithTimeIntervalSinceNow: -7.0 * 3600.0]),
       "a 7 hour old date forces the conditional request path");
  NSString *staleDateText = readDateFile(cacheDir);
  /* The source file is older than the cached copy (it was written before
   * the first download), so curl -z reports "not modified": exit 0 with no
   * output file, the same observable a real 304 produces. */
  startLoad(loader, NO);
  PASS(waitForLoad(30.0), "the conditional load completes");
  PASS(sError == nil, "an unchanged feed reports no error: %s", errorText(sError));
  PASS(sFromCache == YES, "an unchanged feed is served from the cache");
  PASS(sCatalog != nil && [[sCatalog apps] count] == 16,
       "an unchanged feed serves the full catalog");
  NSString *touchedDateText = readDateFile(cacheDir);
  PASS(touchedDateText != nil && ![staleDateText isEqualToString: touchedDateText],
       "the date file is touched by the unchanged answer (was %s, now %s)",
       [staleDateText UTF8String],
       (touchedDateText != nil) ? [touchedDateText UTF8String] : "(missing)");
  NSDate *touchedDate = [formatter dateFromString: touchedDateText];
  PASS(touchedDate != nil && -[touchedDate timeIntervalSinceNow] < 3600.0,
       "the touched date says now, so the next launch skips the network again");
  cachedBytes = [NSData dataWithContentsOfFile: [loader cachePath]];
  PASS(cachedBytes != nil && [cachedBytes isEqualToData: fixtureBytes],
       "an unchanged answer leaves the cache bytes alone");
  PASS(entryCount(cacheDir) == 2,
       "no temporary file survives the conditional load (got %lu entries)",
       (unsigned long)entryCount(cacheDir));

  /* --- 4. a feed that does not parse must not destroy a good cache --- */
  /* The source now holds broken bytes and its modification time is pushed
   * into the past: a conditional request would answer 304 and never see
   * them, so only a reload that omits -z can deliver this failure. That
   * makes the error assertion below discriminate on both rules at once. */
  [[@"{ this is not json" dataUsingEncoding: NSUTF8StringEncoding]
      writeToFile: sourcePath atomically: YES];
  setModificationDate(sourcePath, [NSDate dateWithTimeIntervalSince1970: 1577836800.0]);
  PASS(writeDateFile(cacheDir, [NSDate dateWithTimeIntervalSince1970: 1593561600.0]),
       "a distinctive old date is written for the broken feed case");
  NSString *dateBeforeBroken = readDateFile(cacheDir);

  startLoad(loader, YES);
  PASS(waitForLoad(30.0), "the reload of a broken feed completes");
  PASS(sError != nil, "a feed that does not parse reports an error: %s",
       errorText(sError));
  PASS(sCatalog != nil && [[sCatalog apps] count] == 16,
       "the cached catalog is served beside the error");
  PASS(sFromCache == YES, "the result of the broken reload is the cached one");
  cachedBytes = [NSData dataWithContentsOfFile: [loader cachePath]];
  PASS(cachedBytes != nil && [cachedBytes isEqualToData: fixtureBytes],
       "a feed that does not parse never destroys the good cache");
  PASS_EQUAL(readDateFile(cacheDir), dateBeforeBroken,
             "a rejected feed never rewrites the fetch date");
  PASS_EQUAL([sCatalog fetchDate], [formatter dateFromString: dateBeforeBroken],
             "the served catalog carries the cached fetch date for the banner");

  /* --- 5. curl failure with a cache: catalog and error together --- */
  setFeedURL(gonePath);
  startLoad(loader, NO); /* the date is still old, so this fetches */
  PASS(waitForLoad(30.0), "the failing load completes");
  PASS(sCatalog != nil && sFromCache == YES,
       "a failed fetch still serves the cached catalog");
  PASS(sError != nil, "and reports the failure together with it");
  PASS([[sError localizedDescription] hasPrefix: @"Could not download the catalog: "],
       "the error says what failed: %s", errorText(sError));
  PASS([[sError localizedDescription] rangeOfString: @"\n"].location == NSNotFound,
       "the error carries curl's first stderr line only: %s", errorText(sError));
  PASS([[sError localizedDescription] rangeOfString: @"curl"].location != NSNotFound,
       "the error carries curl's own message: %s", errorText(sError));

  /* --- 6. curl failure with no cache: nothing to show --- */
  NSString *cacheDir2 = [runDir stringByAppendingPathComponent: @"cache2"];
  AGFeedLoader *loader2 = [[AGFeedLoader alloc] initWithCacheDirectory: cacheDir2];
  NSString *expectedCachePath2 = [cacheDir2 stringByAppendingPathComponent: @"feed.json"];
  PASS_EQUAL([loader2 cachePath], expectedCachePath2,
             "the second loader's cache path also stays inside its own directory");
  startLoad(loader2, NO);
  PASS([loader2 isLoading], "the second loader reports loading");
  PASS(waitForLoad(30.0), "the load with no cache completes");
  PASS(sCatalog == nil, "with no cache there is nothing to show");
  PASS(sError != nil, "the failure is reported: %s", errorText(sError));
  PASS([[sError localizedDescription] hasPrefix: @"Could not download the catalog: "],
       "the error says what failed: %s", errorText(sError));
  PASS(sFromCache == NO, "nothing came from the cache");
  PASS(entryCount(cacheDir2) == 0,
       "a failed first fetch leaves no files behind (got %lu entries)",
       (unsigned long)entryCount(cacheDir2));

  /* --- the loader reads the defaults, it never writes them --- */
  PASS([[NSUserDefaults standardUserDefaults] objectForKey: @"AGCacheMaxAgeHours"] == nil,
       "the loader never writes AGCacheMaxAgeHours back");
  PASS_EQUAL([[NSUserDefaults standardUserDefaults] stringForKey: @"AGFeedURL"],
             [[NSURL fileURLWithPath: gonePath] absoluteString],
             "the loader never rewrites AGFeedURL");

  /* --- teardown --- */
  [[NSUserDefaults standardUserDefaults] removeObjectForKey: @"AGFeedURL"];
  [[NSUserDefaults standardUserDefaults] removeObjectForKey: @"AGCacheMaxAgeHours"];
  [loader release];
  [loader2 release];
  [fm removeItemAtPath: runDir error: NULL];
  resetResult();
  [arp release];
  return 0;
}
