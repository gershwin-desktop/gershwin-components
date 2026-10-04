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
  NSOperationQueue *_queue;
  NSLock *_lock;
  NSMutableDictionary *_cache;
  NSMutableDictionary<NSString *, NSMutableArray *> *_pending; /* repo -> completions */
}

- (instancetype)initWithCacheDirectory:(NSString *)directory
                            webBaseURL:(NSString *)webBaseURL
{
  self = [super init];
  if (self)
    {
      _cacheDirectory = [(directory != nil ? directory : AGDefaultCacheDirectory()) copy];
      _webBaseURL = [webBaseURL copy];
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
    }
  return self;
}

- (instancetype)init
{
  return [self initWithCacheDirectory:nil
                           webBaseURL:@"https://github.com"];
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
