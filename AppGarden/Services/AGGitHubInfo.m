/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGGitHubInfo.h"
#import "AGFetch.h"
#import "AGApp.h"

NSString *const AGGitHubInfoErrorDomain = @"AGGitHubInfoErrorDomain";

const NSUInteger AGGitHubPageTextLimit = 12000;

static const NSTimeInterval kAGPageMaxAge = 6.0 * 3600.0;
static NSString *const kAGCacheFileName = @"github.plist";
static NSString *const kAGPagesKey = @"Pages";
static NSString *const kAGLicensesKey = @"Licenses";
static const NSTimeInterval kAGLicenseMaxAge = 7.0 * 86400.0;
static const NSTimeInterval kAGLicenseRetryAfterFailure = 3600.0;

typedef NS_ENUM(NSInteger, AGGitHubInfoErrorCode) {
  AGGitHubInfoErrorBadName = 1,
  AGGitHubInfoErrorDownload,
  AGGitHubInfoErrorUnexpectedAnswer,
};

static NSError *AGGitHubError(AGGitHubInfoErrorCode code, NSString *text)
{
  return [NSError errorWithDomain:AGGitHubInfoErrorDomain
                             code:code
                         userInfo:@{ NSLocalizedDescriptionKey : text }];
}

/* Owner and repository names are letters, digits, dots, dashes and
 * underscores; anything else never reaches a command line. */
static BOOL AGIsGitHubName(NSString *name)
{
  if ([name length] == 0)
    return NO;
  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
      @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
  return [[name stringByTrimmingCharactersInSet:allowed] length] == 0;
}

@implementation AGGitHubInfo
{
  NSString *_cacheDirectory;
  NSString *_webBaseURL;
  NSString *_apiBaseURL;
  NSMutableDictionary<NSString *, NSDate *> *_licenseFailures; /* repo -> when, this session */
  NSOperationQueue *_queue;
  NSLock *_lock;
  NSMutableDictionary *_cache;
  NSMutableDictionary<NSString *, NSMutableArray *> *_pending; /* repo -> completions */
}

- (instancetype)initWithCacheDirectory:(NSString *)directory
                            webBaseURL:(NSString *)webBaseURL
                            apiBaseURL:(NSString *)apiBaseURL
{
  self = [super init];
  if (self)
    {
      _cacheDirectory = [(directory != nil ? directory : AGDefaultCacheDirectory()) copy];
      _webBaseURL = [webBaseURL copy];
      _apiBaseURL = [apiBaseURL copy];
      _licenseFailures = [NSMutableDictionary dictionary];
      _queue = [[NSOperationQueue alloc] init];
      [_queue setMaxConcurrentOperationCount:2];
      _lock = [[NSLock alloc] init];
      _pending = [NSMutableDictionary dictionary];
      [[NSFileManager defaultManager] createDirectoryAtPath:_cacheDirectory
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:NULL];
      NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:
          [_cacheDirectory stringByAppendingPathComponent:kAGCacheFileName]];
      _cache = [NSMutableDictionary dictionary];
      [_cache setObject:[NSMutableDictionary dictionaryWithDictionary:
                            [stored objectForKey:kAGPagesKey]]
                 forKey:kAGPagesKey];
      [_cache setObject:[NSMutableDictionary dictionaryWithDictionary:
                            [stored objectForKey:kAGLicensesKey]]
                 forKey:kAGLicensesKey];
    }
  return self;
}

- (instancetype)init
{
  return [self initWithCacheDirectory:nil
                           webBaseURL:@"https://github.com"
                           apiBaseURL:@"https://api.github.com"];
}

#pragma mark - Pure parts

+ (NSString *)ownerOfRepo:(NSString *)repo
{
  NSArray<NSString *> *parts = [repo componentsSeparatedByString:@"/"];
  if ([parts count] != 2 || !AGIsGitHubName([parts objectAtIndex:0])
      || !AGIsGitHubName([parts objectAtIndex:1]))
    return nil;
  return [parts objectAtIndex:0];
}

+ (NSString *)repositoryForApp:(AGApp *)app
{
  if ([app githubRepo] != nil)
    return [app githubRepo];
  NSURL *url = [app downloadPageURL];
  NSString *host = [[url host] lowercaseString];
  if (![host isEqualToString:@"github.com"] && ![host isEqualToString:@"www.github.com"])
    return nil;
  NSMutableArray<NSString *> *parts = [NSMutableArray array];
  for (NSString *part in [[url path] componentsSeparatedByString:@"/"])
    if ([part length] > 0)
      [parts addObject:part];
  if ([parts count] < 2)
    return nil;
  NSString *repo = [NSString stringWithFormat:@"%@/%@", [parts objectAtIndex:0], [parts objectAtIndex:1]];
  return ([self ownerOfRepo:repo] != nil) ? repo : nil;
}

+ (NSString *)pageTextFromRepositoryHTML:(NSString *)html
{
  if ([html length] == 0)
    return nil;
  NSMutableArray<NSString *> *parts = [NSMutableArray array];

  NSRange meta = [html rangeOfString:@"<meta name=\"description\" content=\""];
  if (meta.location != NSNotFound)
    {
      NSString *rest = [html substringFromIndex:NSMaxRange(meta)];
      NSRange quote = [rest rangeOfString:@"\""];
      if (quote.location != NSNotFound)
        [parts addObject:[rest substringToIndex:quote.location]];
    }

  /* The README is the <article> whose own tag says markdown-body: the words
   * markdown-body also appear in the page's scripts and styles, so the first
   * mention is not necessarily the article. */
  NSUInteger from = 0;
  while (from < [html length])
    {
      NSRange open = [html rangeOfString:@"<article" options:0
                                   range:NSMakeRange(from, [html length] - from)];
      if (open.location == NSNotFound)
        break;
      NSRange tagEnd = [html rangeOfString:@">" options:0
                                     range:NSMakeRange(open.location, [html length] - open.location)];
      if (tagEnd.location == NSNotFound)
        break;
      NSString *tag = [html substringWithRange:
          NSMakeRange(open.location, tagEnd.location - open.location)];
      from = NSMaxRange(tagEnd);
      if ([tag rangeOfString:@"markdown-body"].location == NSNotFound)
        continue;
      NSRange close = [html rangeOfString:@"</article>" options:0
                                    range:NSMakeRange(from, [html length] - from)];
      if (close.location != NSNotFound)
        [parts addObject:[html substringWithRange:
            NSMakeRange(from, close.location - from)]];
      break;
    }

  NSString *joined = [parts componentsJoinedByString:@" "];
  static NSRegularExpression *blocks = nil, *tags = nil, *spaces = nil;
  if (blocks == nil)
    {
      blocks = [NSRegularExpression regularExpressionWithPattern:
          @"<(script|style)[^>]*>.*?</\\1>" options:NSRegularExpressionDotMatchesLineSeparators
                                                  error:NULL];
      tags = [NSRegularExpression regularExpressionWithPattern:@"<[^>]*>" options:0 error:NULL];
      spaces = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:NULL];
    }
  NSString *text = [blocks stringByReplacingMatchesInString:joined options:0
                                                      range:NSMakeRange(0, [joined length])
                                               withTemplate:@" "];
  text = [tags stringByReplacingMatchesInString:text options:0
                                          range:NSMakeRange(0, [text length])
                                   withTemplate:@" "];
  NSDictionary *entities = @{ @"&amp;" : @"&", @"&lt;" : @"<", @"&gt;" : @">",
                              @"&quot;" : @"\"", @"&#39;" : @"'", @"&nbsp;" : @" " };
  for (NSString *entity in entities)
    text = [text stringByReplacingOccurrencesOfString:entity
                                           withString:[entities objectForKey:entity]];
  text = [spaces stringByReplacingMatchesInString:text options:0
                                            range:NSMakeRange(0, [text length])
                                     withTemplate:@" "];
  text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([text length] == 0)
    return nil;
  return ([text length] > AGGitHubPageTextLimit)
      ? [text substringToIndex:AGGitHubPageTextLimit] : text;
}

+ (NSDictionary *)licenseFromRepositoryJSON:(NSData *)data error:(NSError **)error
{
  id root = ([data length] > 0)
      ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]
      : nil;
  if ([root isKindOfClass:[NSDictionary class]]
      && ([root objectForKey:@"full_name"] != nil || [root objectForKey:@"id"] != nil))
    {
      id license = [root objectForKey:@"license"];
      NSMutableDictionary *result = [NSMutableDictionary dictionary];
      if ([license isKindOfClass:[NSDictionary class]])
        {
          NSString *spdx = [license objectForKey:@"spdx_id"];
          NSString *name = [license objectForKey:@"name"];
          if ([spdx isKindOfClass:[NSString class]])
            [result setObject:spdx forKey:@"SPDX"];
          if ([name isKindOfClass:[NSString class]])
            [result setObject:name forKey:@"Name"];
        }
      return result;
    }

  if (error != NULL)
    {
      NSString *message = [root isKindOfClass:[NSDictionary class]]
          ? [root objectForKey:@"message"] : nil;
      NSString *text;
      if ([message rangeOfString:@"rate limit" options:NSCaseInsensitiveSearch].location
          != NSNotFound)
        text = NSLocalizedString(@"GitHub rate limit reached.", @"");
      else if ([message length] > 0)
        text = [NSString stringWithFormat:
                    NSLocalizedString(@"GitHub answered: %@", @""), message];
      else
        text = NSLocalizedString(@"GitHub gave no answer about this repository.", @"");
      *error = AGGitHubError(AGGitHubInfoErrorUnexpectedAnswer, text);
    }
  return nil;
}

+ (NSString *)licenseStringFromDictionary:(NSDictionary *)license
{
  NSString *spdx = [license objectForKey:@"SPDX"];
  if ([spdx length] > 0 && [spdx caseInsensitiveCompare:@"NOASSERTION"] != NSOrderedSame)
    return spdx;
  /* "Other" is GitHub's name for a license it did not recognize, which says
   * nothing about the license itself. */
  NSString *name = [license objectForKey:@"Name"];
  if ([spdx length] == 0 && [name length] > 0 && [name caseInsensitiveCompare:@"Other"] != NSOrderedSame)
    return name;
  return nil;
}

+ (NSNumber *)starCountFromRepositoryHTML:(NSString *)html
{
  NSRange marker = [html rangeOfString:@"id=\"repo-stars-counter-star\""];
  if (marker.location == NSNotFound)
    return nil;
  NSRange tagEnd = [html rangeOfString:@">"
                               options:0
                                 range:NSMakeRange(marker.location,
                                                   [html length] - marker.location)];
  if (tagEnd.location == NSNotFound)
    return nil;
  NSString *tag = [html substringWithRange:
      NSMakeRange(marker.location, tagEnd.location - marker.location)];
  NSRange title = [tag rangeOfString:@"title=\""];
  if (title.location == NSNotFound)
    return nil;
  NSString *rest = [tag substringFromIndex:NSMaxRange(title)];
  NSRange quote = [rest rangeOfString:@"\""];
  if (quote.location == NSNotFound)
    return nil;
  NSString *value = [rest substringToIndex:quote.location];
  NSMutableString *digits = [NSMutableString string];
  for (NSUInteger i = 0; i < [value length]; i++)
    {
      unichar c = [value characterAtIndex:i];
      if (c >= '0' && c <= '9')
        [digits appendFormat:@"%C", c];
      else if (c != ',' && c != '.' && c != ' ')
        return nil;
    }
  if ([digits length] == 0)
    return nil;
  return [NSNumber numberWithLongLong:[digits longLongValue]];
}

#pragma mark - Cache

- (void)saveCache
{
  /* Called with the lock held. */
  [_cache writeToFile:[_cacheDirectory stringByAppendingPathComponent:kAGCacheFileName]
           atomically:YES];
}

- (void)deliver:(void (^)(void))block
{
  [[NSOperationQueue mainQueue] addOperationWithBlock:block];
}

#pragma mark - The license

- (void)licenseForRepo:(NSString *)repo
            completion:(void (^)(NSString *license, NSError *error))completion
{
  if ([AGGitHubInfo ownerOfRepo:repo] == nil)
    {
      NSError *error = AGGitHubError(AGGitHubInfoErrorBadName,
          NSLocalizedString(@"This is not a GitHub repository name.", @""));
      [self deliver:^{ completion(nil, error); }];
      return;
    }

  [_lock lock];
  NSDictionary *entry = [[_cache objectForKey:kAGLicensesKey] objectForKey:repo];
  NSDate *failed = [_licenseFailures objectForKey:repo];
  [_lock unlock];

  NSDate *when = [entry objectForKey:@"Date"];
  if (entry != nil && when != nil && -[when timeIntervalSinceNow] < kAGLicenseMaxAge)
    {
      NSString *known = [AGGitHubInfo licenseStringFromDictionary:entry];
      [self deliver:^{ completion(known, nil); }];
      return;
    }
  /* After a refusal, such as the rate limit, the same question is not asked
   * again for an hour: every detail page view would otherwise spend a request
   * that is certain to be refused. */
  if (failed != nil && -[failed timeIntervalSinceNow] < kAGLicenseRetryAfterFailure)
    {
      NSError *error = AGGitHubError(AGGitHubInfoErrorDownload,
          NSLocalizedString(@"GitHub rate limit reached.", @""));
      [self deliver:^{ completion(nil, error); }];
      return;
    }

  [_queue addOperationWithBlock:^{
    NSString *body = [_cacheDirectory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"license-%@.tmp", [[NSUUID UUID] UUIDString]]];
    NSString *headers = [body stringByAppendingString:@".headers"];
    NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObjects:
        @"-sSL", @"--max-time", @"30",
        @"-H", @"Accept: application/vnd.github+json", nil];
    NSString *etag = [entry objectForKey:@"ETag"];
    if ([etag length] > 0)
      {
        /* Revalidating costs nothing against the limit when the answer is
         * "not modified". */
        [arguments addObject:@"-H"];
        [arguments addObject:[@"If-None-Match: " stringByAppendingString:etag]];
      }
    [arguments addObjectsFromArray:@[ @"-D", headers, @"-o", body,
        [NSString stringWithFormat:@"%@/repos/%@", _apiBaseURL, repo] ]];
    NSString *reason = nil;
    int status = AGRunCurl(arguments, &reason);
    NSData *data = [NSData dataWithContentsOfFile:body];
    NSString *headerText = [NSString stringWithContentsOfFile:headers
                                                     encoding:NSUTF8StringEncoding error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:body error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:headers error:NULL];

    /* Only the last header block counts: curl lists every redirect hop. */
    NSString *lastBlock = [[headerText componentsSeparatedByString:@"\r\n\r\n"]
        objectAtIndex:MAX(0, (NSInteger)[[headerText componentsSeparatedByString:@"\r\n\r\n"] count] - 2)];
    NSInteger httpStatus = 0;
    NSString *newETag = nil;
    for (NSString *line in [lastBlock componentsSeparatedByCharactersInSet:
                               [NSCharacterSet newlineCharacterSet]])
      {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trimmed hasPrefix:@"HTTP/"])
          {
            NSArray *parts = [trimmed componentsSeparatedByString:@" "];
            if ([parts count] > 1)
              httpStatus = [[parts objectAtIndex:1] integerValue];
          }
        else if ([[trimmed lowercaseString] hasPrefix:@"etag:"])
          newETag = [[trimmed substringFromIndex:5]
              stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      }

    NSDictionary *license = nil;
    NSError *error = nil;
    if (status != 0)
      error = AGGitHubError(AGGitHubInfoErrorDownload,
          [NSString stringWithFormat:
              NSLocalizedString(@"Could not reach GitHub: %@", @""),
              reason != nil ? reason : @"curl"]);
    else if (httpStatus == 304 && entry != nil)
      license = entry;
    else
      license = [AGGitHubInfo licenseFromRepositoryJSON:data error:&error];

    [_lock lock];
    if (license != nil)
      {
        NSMutableDictionary *stored = [NSMutableDictionary dictionaryWithObject:[NSDate date]
                                                                         forKey:@"Date"];
        for (NSString *key in @[ @"SPDX", @"Name" ])
          if ([license objectForKey:key] != nil)
            [stored setObject:[license objectForKey:key] forKey:key];
        NSString *keep = (newETag != nil) ? newETag : [entry objectForKey:@"ETag"];
        if (keep != nil)
          [stored setObject:keep forKey:@"ETag"];
        [[_cache objectForKey:kAGLicensesKey] setObject:stored forKey:repo];
        [_licenseFailures removeObjectForKey:repo];
        [self saveCache];
      }
    else
      [_licenseFailures setObject:[NSDate date] forKey:repo];
    [_lock unlock];

    NSString *result = (license != nil) ? [AGGitHubInfo licenseStringFromDictionary:license] : nil;
    [self deliver:^{ completion(result, error); }];
  }];
}

#pragma mark - The repository page

- (void)starsForRepo:(NSString *)repo
          completion:(void (^)(NSNumber *stars, NSError *error))completion
{
  [self pageForRepo:repo completion:^(NSDictionary *page, NSError *error) {
    NSNumber *stars = [page objectForKey:@"Count"];
    if (stars == nil && error == nil)
      error = AGGitHubError(AGGitHubInfoErrorUnexpectedAnswer,
          NSLocalizedString(@"The repository page has no star count.", @""));
    completion(stars, stars != nil ? nil : error);
  }];
}

- (void)pageTextForRepo:(NSString *)repo
             completion:(void (^)(NSString *text, NSError *error))completion
{
  [self pageForRepo:repo completion:^(NSDictionary *page, NSError *error) {
    NSString *text = [page objectForKey:@"Text"];
    if (text == nil && error == nil)
      error = AGGitHubError(AGGitHubInfoErrorUnexpectedAnswer,
          NSLocalizedString(@"The repository page has no description.", @""));
    completion(text, text != nil ? nil : error);
  }];
}

/* One fetch serves the stars and the text, from the cache while it is under
 * six hours old; two askers for the same page at once share the request. The
 * completion arrives on the main queue. */
- (void)pageForRepo:(NSString *)repo
         completion:(void (^)(NSDictionary *page, NSError *error))completion
{
  if ([AGGitHubInfo ownerOfRepo:repo] == nil)
    {
      NSError *error = AGGitHubError(AGGitHubInfoErrorBadName,
          NSLocalizedString(@"This is not a GitHub repository name.", @""));
      [self deliver:^{ completion(nil, error); }];
      return;
    }

  [_lock lock];
  NSDictionary *entry = [[_cache objectForKey:kAGPagesKey] objectForKey:repo];
  NSDate *when = [entry objectForKey:@"Date"];
  if (entry != nil && when != nil && -[when timeIntervalSinceNow] < kAGPageMaxAge)
    {
      [_lock unlock];
      [self deliver:^{ completion(entry, nil); }];
      return;
    }
  NSMutableArray *waiting = [_pending objectForKey:repo];
  if (waiting != nil)
    {
      [waiting addObject:[completion copy]];
      [_lock unlock];
      return;
    }
  [_pending setObject:[NSMutableArray arrayWithObject:[completion copy]] forKey:repo];
  [_lock unlock];

  [_queue addOperationWithBlock:^{
    NSString *tmp = [_cacheDirectory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"page-%@.tmp", [[NSUUID UUID] UUIDString]]];
    NSString *url = [NSString stringWithFormat:@"%@/%@", _webBaseURL, repo];
    NSString *reason = nil;
    int status = AGRunCurl(@[ @"-fsSL", @"--max-time", @"30", @"-o", tmp, url ], &reason);
    NSString *html = (status == 0)
        ? [NSString stringWithContentsOfFile:tmp encoding:NSUTF8StringEncoding error:NULL]
        : nil;
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];

    NSNumber *stars = [AGGitHubInfo starCountFromRepositoryHTML:html];
    NSString *text = [AGGitHubInfo pageTextFromRepositoryHTML:html];
    NSMutableDictionary *page = nil;
    NSError *error = nil;
    if (stars != nil || text != nil)
      {
        page = [NSMutableDictionary dictionaryWithObject:[NSDate date] forKey:@"Date"];
        if (stars != nil)
          [page setObject:stars forKey:@"Count"];
        if (text != nil)
          [page setObject:text forKey:@"Text"];
      }
    else if (status != 0)
      error = AGGitHubError(AGGitHubInfoErrorDownload,
          [NSString stringWithFormat:
              NSLocalizedString(@"Could not read the repository page: %@", @""),
              reason != nil ? reason : @"curl"]);
    else
      error = AGGitHubError(AGGitHubInfoErrorUnexpectedAnswer,
          NSLocalizedString(@"The repository page has no star count.", @""));

    [_lock lock];
    NSArray *completions = [_pending objectForKey:repo];
    [_pending removeObjectForKey:repo];
    if (page != nil)
      {
        [[_cache objectForKey:kAGPagesKey] setObject:page forKey:repo];
        [self saveCache];
      }
    [_lock unlock];
    [self deliver:^{
      for (void (^done)(NSDictionary *, NSError *) in completions)
        done(page, error);
    }];
  }];
}

@end
