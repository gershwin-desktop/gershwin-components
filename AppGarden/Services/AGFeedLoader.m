/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGFeedLoader.h"
#import "AGCatalog.h"
#import "AGFeedParser.h"
#import "AGFetch.h"

NSString *const AGFeedURLString = @"https://appimage.github.io/feed.json";

static NSString *const AGFeedURLDefaultKey = @"AGFeedURL";
static NSString *const AGCacheMaxAgeHoursDefaultKey = @"AGCacheMaxAgeHours";
static NSString *const AGFeedFileName = @"feed.json";
static NSString *const AGFeedDateFileName = @"feed.json.date";
static const double AGDefaultCacheMaxAgeHours = 6.0;

/* Fetch failures get their own domain: the parser's domain stays reserved
 * for documents that are not usable feeds, while these errors only ever
 * surface as one line of text beside a catalog the user can still browse. */
static NSString *const AGFeedLoaderErrorDomain =
    @"io.github.gershwin-desktop.AppGarden.AGFeedLoader";

enum {
  AGFeedLoaderErrorDownload = 1,   // curl could not fetch the feed
  AGFeedLoaderErrorNoData,         // curl fetched nothing at all
  AGFeedLoaderErrorStore,          // the fetched feed could not be stored
  AGFeedLoaderErrorCacheUnreadable // the cached feed could not be read
};

static NSError *AGLoaderError(NSInteger code, NSString *text)
{
  return [NSError errorWithDomain:AGFeedLoaderErrorDomain
                             code:code
                         userInfo:@{ NSLocalizedDescriptionKey: text }];
}

static NSError *AGDownloadError(NSString *reason)
{
  NSString *text = [NSString stringWithFormat:
      NSLocalizedString(@"Could not download the catalog: %@", @""), reason];
  return AGLoaderError(AGFeedLoaderErrorDownload, text);
}

static NSISO8601DateFormatter *AGDateFormatter(void)
{
  // One formatter per call: they are not safe to share between the fetch
  // operation and whoever reads the date file back.
  return [[NSISO8601DateFormatter alloc] init];
}

static NSDate *AGReadCacheDate(NSString *directory)
{
  NSString *path = [directory stringByAppendingPathComponent:AGFeedDateFileName];
  NSString *text = [NSString stringWithContentsOfFile:path
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
  if (text == nil)
    return nil;
  return [AGDateFormatter() dateFromString:text];
}

static BOOL AGWriteCacheDate(NSString *directory, NSDate *date)
{
  NSString *path = [directory stringByAppendingPathComponent:AGFeedDateFileName];
  NSString *text = [AGDateFormatter() stringFromDate:date];
  // A date that cannot be written costs one conditional request on the next
  // launch and nothing else, so it never fails a load that is otherwise good.
  return [text writeToFile:path
                atomically:YES
                  encoding:NSUTF8StringEncoding
                     error:NULL];
}

static NSDate *AGCacheDateOrNow(NSString *directory)
{
  NSDate *date = AGReadCacheDate(directory);
  return (date != nil) ? date : [NSDate date];
}

/* The max age is read, never written: AppGarden only owns the three keys in
 * its own list, and a user who sets AGCacheMaxAgeHours keeps that value. */
static BOOL AGCacheIsYoung(NSDate *date)
{
  id value = [[NSUserDefaults standardUserDefaults]
      objectForKey:AGCacheMaxAgeHoursDefaultKey];
  double hours = AGDefaultCacheMaxAgeHours;
  if (value != nil && [value respondsToSelector:@selector(doubleValue)])
    hours = [value doubleValue];
  return -[date timeIntervalSinceNow] <= hours * 3600.0;
}

static NSString *AGFeedURLToFetch(void)
{
  NSString *override = [[NSUserDefaults standardUserDefaults]
      stringForKey:AGFeedURLDefaultKey];
  if ([override length] > 0)
    return override;
  return AGFeedURLString;
}

static AGCatalog *AGParseCacheFile(NSString *path, NSDate *fetchDate,
                                   NSError **error)
{
  if (error != NULL)
    *error = nil;
  NSData *data = [NSData dataWithContentsOfFile:path options:0 error:NULL];
  if (data == nil)
    {
      if (error != NULL)
        *error = AGLoaderError(AGFeedLoaderErrorCacheUnreadable,
            NSLocalizedString(@"The catalog cache could not be read.", @""));
      return nil;
    }
  return [AGFeedParser catalogFromData:data fetchDate:fetchDate error:error];
}

@implementation AGFeedLoader
{
  NSOperationQueue *_queue;
  NSInteger _loadsInFlight;
}

- (instancetype)initWithCacheDirectory:(NSString *)directory
{
  self = [super init];
  if (self)
    {
      NSString *dir = (directory != nil) ? directory : AGDefaultCacheDirectory();
      _cacheDirectory = [dir copy];
      _queue = [[NSOperationQueue alloc] init];
      // One fetch at a time: two conditional requests racing over one cache
      // file would decide its contents by timing.
      [_queue setMaxConcurrentOperationCount:1];
      [[NSFileManager defaultManager] createDirectoryAtPath:_cacheDirectory
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:NULL];
    }
  return self;
}

- (instancetype)init
{
  return [self initWithCacheDirectory:nil];
}

- (NSString *)cachePath
{
  return [[self cacheDirectory] stringByAppendingPathComponent:AGFeedFileName];
}

- (BOOL)isLoading
{
  @synchronized (self)
    {
      return _loadsInFlight > 0;
    }
}

- (void)loadWithCompletion:(AGFeedLoadCompletion)completion
{
  [self startIgnoringMaxAge:NO completion:completion];
}

- (void)reloadIgnoringCacheWithCompletion:(AGFeedLoadCompletion)completion
{
  [self startIgnoringMaxAge:YES completion:completion];
}

#pragma mark - Private

- (void)startIgnoringMaxAge:(BOOL)ignoringMaxAge
                 completion:(AGFeedLoadCompletion)completion
{
  AGFeedLoadCompletion done = (completion != nil) ? completion
      : ^(AGCatalog *catalog, BOOL fromCache, NSError *error) {};
  @synchronized (self)
    {
      _loadsInFlight++;
    }

  AGFeedLoader *blockSelf = self;
  NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
    [blockSelf runLoadIgnoringMaxAge:ignoringMaxAge completion:done];
  }];
  [_queue addOperation:operation];
}

/* Every terminal path funnels through here, so a completion always arrives
 * on the main queue and always balances the in-flight count - before it
 * runs, so a Retry inside the completion starts a fresh load. */
- (void)deliverCatalog:(AGCatalog *)catalog
             fromCache:(BOOL)fromCache
                 error:(NSError *)error
            completion:(AGFeedLoadCompletion)completion
{
  AGCatalog *result = catalog;
  NSError *resultError = error;
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    @synchronized (self)
      {
        if (_loadsInFlight > 0)
          _loadsInFlight--;
      }
    completion(result, fromCache, resultError);
  }];
}

- (void)runLoadIgnoringMaxAge:(BOOL)ignoringMaxAge
                   completion:(AGFeedLoadCompletion)completion
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *path = [self cachePath];

  // Step 1: a young cache answers with no network at all, which is what
  // makes the second launch instant. The parse runs here rather than in the
  // caller so the launch path stays off the main thread; a cache that no
  // longer parses is simply not a cache, and the fetch below replaces it.
  if (!ignoringMaxAge && [fm fileExistsAtPath:path])
    {
      NSDate *cacheDate = AGReadCacheDate([self cacheDirectory]);
      if (cacheDate != nil && AGCacheIsYoung(cacheDate))
        {
          NSError *parseError = nil;
          AGCatalog *catalog = AGParseCacheFile(path, cacheDate, &parseError);
          if (catalog != nil)
            {
              [self deliverCatalog:catalog fromCache:YES error:nil
                        completion:completion];
              return;
            }
        }
    }

  [self fetchCatalogIgnoringMaxAge:ignoringMaxAge completion:completion];
}

- (void)fetchCatalogIgnoringMaxAge:(BOOL)ignoringMaxAge
                        completion:(AGFeedLoadCompletion)completion
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *path = [self cachePath];
  NSString *directory = [self cacheDirectory];
  BOOL haveCache = [fm fileExistsAtPath:path];
  NSString *tmpPath = [directory stringByAppendingPathComponent:
      [NSString stringWithFormat:@"feed-%@.tmp", [[NSUUID UUID] UUIDString]]];

  NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObjects:
      @"-fsSL", @"--max-time", @"60", nil];
  if (!ignoringMaxAge && haveCache)
    {
      // A conditional request: a 304 carries no body, so the bytes already
      // on disk stay authoritative and an unchanged feed costs one round
      // trip instead of 930 KB.
      [arguments addObject:@"-z"];
      [arguments addObject:path];
    }
  [arguments addObject:@"-o"];
  [arguments addObject:tmpPath];
  [arguments addObject:AGFeedURLToFetch()];

  NSString *reason = nil;
  int status = AGRunCurl(arguments, &reason);

  // Step 3: curl failed. The last good cache still browses, and the error
  // travels with it so the caller can explain the banner.
  if (status != 0)
    {
      [fm removeItemAtPath:tmpPath error:NULL];
      NSError *error = AGDownloadError(reason);
      if (haveCache)
        {
          AGCatalog *cached = AGParseCacheFile(path,
              AGCacheDateOrNow(directory), NULL);
          if (cached != nil)
            {
              [self deliverCatalog:cached fromCache:YES error:error
                        completion:completion];
              return;
            }
        }
      [self deliverCatalog:nil fromCache:NO error:error completion:completion];
      return;
    }

  unsigned long long tmpSize = 0;
  NSDictionary *attributes = [fm attributesOfItemAtPath:tmpPath error:NULL];
  if (attributes != nil)
    tmpSize = [attributes fileSize];

  // Exit 0 with an empty or missing file is a 304: the cache is current.
  // Its date moves forward so the next launch is served by step 1 without
  // any request at all.
  if (tmpSize == 0)
    {
      [fm removeItemAtPath:tmpPath error:NULL];
      if (haveCache)
        {
          AGWriteCacheDate(directory, [NSDate date]);
          NSError *cacheError = nil;
          AGCatalog *cached = AGParseCacheFile(path,
              AGCacheDateOrNow(directory), &cacheError);
          [self deliverCatalog:cached fromCache:(cached != nil)
                         error:(cached != nil ? nil : cacheError)
                    completion:completion];
          return;
        }
      NSError *error = AGLoaderError(AGFeedLoaderErrorNoData,
          NSLocalizedString(@"The catalog download produced no data.", @""));
      [self deliverCatalog:nil fromCache:NO error:error completion:completion];
      return;
    }

  // Step 2, second half: parse before storing. A feed the parser rejects
  // must never replace a cache that still works, so the failure goes out
  // with the old catalog when there is one - and with no catalog at all
  // when there is not.
  NSData *data = [NSData dataWithContentsOfFile:tmpPath options:0 error:NULL];
  NSError *parseError = nil;
  AGCatalog *fresh = (data != nil)
      ? [AGFeedParser catalogFromData:data fetchDate:[NSDate date]
                                error:&parseError]
      : nil;
  if (fresh == nil)
    {
      [fm removeItemAtPath:tmpPath error:NULL];
      if (parseError == nil)
        parseError = AGLoaderError(AGFeedLoaderErrorNoData,
            NSLocalizedString(@"The catalog download produced no data.", @""));
      if (haveCache)
        {
          AGCatalog *cached = AGParseCacheFile(path,
              AGCacheDateOrNow(directory), NULL);
          if (cached != nil)
            {
              [self deliverCatalog:cached fromCache:YES error:parseError
                        completion:completion];
              return;
            }
        }
      [self deliverCatalog:nil fromCache:NO error:parseError
                completion:completion];
      return;
    }

  NSError *storeError = nil;
  if ([fm fileExistsAtPath:path] &&
      ![fm removeItemAtPath:path error:&storeError])
    {
      [fm removeItemAtPath:tmpPath error:NULL];
      NSString *text = [NSString stringWithFormat:
          NSLocalizedString(@"Could not save the catalog: %@", @""),
          [storeError localizedDescription]];
      [self deliverCatalog:nil fromCache:NO
                     error:AGLoaderError(AGFeedLoaderErrorStore, text)
                completion:completion];
      return;
    }
  if (![fm moveItemAtPath:tmpPath toPath:path error:&storeError])
    {
      [fm removeItemAtPath:tmpPath error:NULL];
      NSString *text = [NSString stringWithFormat:
          NSLocalizedString(@"Could not save the catalog: %@", @""),
          [storeError localizedDescription]];
      [self deliverCatalog:nil fromCache:NO
                     error:AGLoaderError(AGFeedLoaderErrorStore, text)
                completion:completion];
      return;
    }
  AGWriteCacheDate(directory, [NSDate date]);
  [self deliverCatalog:fresh fromCache:NO error:nil completion:completion];
}

@end
