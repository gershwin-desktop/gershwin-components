/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGGitHubInfo.h"
#import "AGFetch.h"

NSString *const AGGitHubInfoErrorDomain = @"AGGitHubInfoErrorDomain";
const NSInteger AGGitHubMinimumAccountAgeDays = 30;

static const NSTimeInterval kAGStarsMaxAge = 6.0 * 3600.0;
static NSString *const kAGCacheFileName = @"github.plist";
static NSString *const kAGStarsKey = @"Stars";
static NSString *const kAGAccountsKey = @"Accounts";

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
  NSOperationQueue *_queue;
  NSLock *_lock;
  NSMutableDictionary *_cache;
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
      _queue = [[NSOperationQueue alloc] init];
      [_queue setMaxConcurrentOperationCount:2];
      _lock = [[NSLock alloc] init];
      [[NSFileManager defaultManager] createDirectoryAtPath:_cacheDirectory
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:NULL];
      NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:
          [_cacheDirectory stringByAppendingPathComponent:kAGCacheFileName]];
      _cache = [NSMutableDictionary dictionary];
      [_cache setObject:[NSMutableDictionary dictionaryWithDictionary:
                            [stored objectForKey:kAGStarsKey]]
                 forKey:kAGStarsKey];
      [_cache setObject:[NSMutableDictionary dictionaryWithDictionary:
                            [stored objectForKey:kAGAccountsKey]]
                 forKey:kAGAccountsKey];
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

+ (NSDate *)creationDateFromUserJSON:(NSData *)data error:(NSError **)error
{
  id root = ([data length] > 0)
      ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]
      : nil;
  NSString *created = [root isKindOfClass:[NSDictionary class]]
      ? [root objectForKey:@"created_at"] : nil;
  NSDate *date = [created isKindOfClass:[NSString class]]
      ? [[[NSISO8601DateFormatter alloc] init] dateFromString:created] : nil;
  if (date != nil)
    return date;

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
        text = NSLocalizedString(@"GitHub gave no answer about this account.", @"");
      *error = AGGitHubError(AGGitHubInfoErrorUnexpectedAnswer, text);
    }
  return nil;
}

+ (NSInteger)daysFromDate:(NSDate *)date toDate:(NSDate *)now
{
  NSTimeInterval seconds = [now timeIntervalSinceDate:date];
  return (seconds <= 0.0) ? 0 : (NSInteger)floor(seconds / 86400.0);
}

+ (NSString *)warningForAccountCreatedOn:(NSDate *)date now:(NSDate *)now
{
  if (date == nil)
    return NSLocalizedString(@"AppGarden could not check how old the publisher's GitHub account is.", @"");
  NSInteger days = [self daysFromDate:date toDate:now];
  if (days >= AGGitHubMinimumAccountAgeDays)
    return nil;
  if (days < 1)
    return NSLocalizedString(@"The publisher's GitHub account was created today.", @"");
  if (days == 1)
    return NSLocalizedString(@"The publisher's GitHub account is only 1 day old.", @"");
  return [NSString stringWithFormat:
              NSLocalizedString(@"The publisher's GitHub account is only %ld days old.", @""),
              (long)days];
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

#pragma mark - Stars

- (void)starsForRepo:(NSString *)repo
          completion:(void (^)(NSNumber *stars, NSError *error))completion
{
  NSString *owner = [AGGitHubInfo ownerOfRepo:repo];
  if (owner == nil)
    {
      NSError *error = AGGitHubError(AGGitHubInfoErrorBadName,
          NSLocalizedString(@"This is not a GitHub repository name.", @""));
      [self deliver:^{ completion(nil, error); }];
      return;
    }

  [_lock lock];
  NSDictionary *entry = [[_cache objectForKey:kAGStarsKey] objectForKey:repo];
  [_lock unlock];
  NSDate *when = [entry objectForKey:@"Date"];
  NSNumber *known = [entry objectForKey:@"Count"];
  if (known != nil && when != nil && -[when timeIntervalSinceNow] < kAGStarsMaxAge)
    {
      [self deliver:^{ completion(known, nil); }];
      return;
    }

  [_queue addOperationWithBlock:^{
    NSString *tmp = [_cacheDirectory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"stars-%@.tmp", [[NSUUID UUID] UUIDString]]];
    NSString *url = [NSString stringWithFormat:@"%@/%@", _webBaseURL, repo];
    NSString *reason = nil;
    int status = AGRunCurl(@[ @"-fsSL", @"--max-time", @"30", @"-o", tmp, url ], &reason);
    NSString *html = (status == 0)
        ? [NSString stringWithContentsOfFile:tmp encoding:NSUTF8StringEncoding error:NULL]
        : nil;
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];

    NSNumber *stars = [AGGitHubInfo starCountFromRepositoryHTML:html];
    NSError *error = nil;
    if (stars != nil)
      {
        [_lock lock];
        [[_cache objectForKey:kAGStarsKey] setObject:@{ @"Count" : stars,
                                                        @"Date" : [NSDate date] }
                                              forKey:repo];
        [self saveCache];
        [_lock unlock];
      }
    else if (status != 0)
      error = AGGitHubError(AGGitHubInfoErrorDownload,
          [NSString stringWithFormat:
              NSLocalizedString(@"Could not read the repository page: %@", @""),
              reason != nil ? reason : @"curl"]);
    else
      error = AGGitHubError(AGGitHubInfoErrorUnexpectedAnswer,
          NSLocalizedString(@"The repository page has no star count.", @""));
    [self deliver:^{ completion(stars, error); }];
  }];
}

#pragma mark - Account age

- (void)accountCreationDateForOwner:(NSString *)owner
                         completion:(void (^)(NSDate *date, NSError *error))completion
{
  if (!AGIsGitHubName(owner))
    {
      NSError *error = AGGitHubError(AGGitHubInfoErrorBadName,
          NSLocalizedString(@"This is not a GitHub account name.", @""));
      [self deliver:^{ completion(nil, error); }];
      return;
    }

  [_lock lock];
  NSDate *known = [[_cache objectForKey:kAGAccountsKey] objectForKey:owner];
  [_lock unlock];
  if (known != nil)
    {
      [self deliver:^{ completion(known, nil); }];
      return;
    }

  [_queue addOperationWithBlock:^{
    NSString *tmp = [_cacheDirectory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"account-%@.tmp", [[NSUUID UUID] UUIDString]]];
    NSString *url = [NSString stringWithFormat:@"%@/users/%@", _apiBaseURL, owner];
    NSString *reason = nil;
    /* No -f: a refusal such as the rate limit comes with a JSON body that
     * says so, and curl would otherwise throw it away. */
    int status = AGRunCurl(@[ @"-sSL", @"--max-time", @"30",
                              @"-H", @"Accept: application/vnd.github+json",
                              @"-o", tmp, url ], &reason);
    NSData *data = (status == 0) ? [NSData dataWithContentsOfFile:tmp] : nil;
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];

    NSError *error = nil;
    NSDate *date = nil;
    if (status != 0)
      error = AGGitHubError(AGGitHubInfoErrorDownload,
          [NSString stringWithFormat:
              NSLocalizedString(@"Could not reach GitHub: %@", @""),
              reason != nil ? reason : @"curl"]);
    else
      date = [AGGitHubInfo creationDateFromUserJSON:data error:&error];

    if (date != nil)
      {
        [_lock lock];
        [[_cache objectForKey:kAGAccountsKey] setObject:date forKey:owner];
        [self saveCache];
        [_lock unlock];
      }
    [self deliver:^{ completion(date, error); }];
  }];
}

@end
