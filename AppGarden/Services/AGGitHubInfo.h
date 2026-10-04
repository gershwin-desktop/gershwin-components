/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

extern NSString *const AGGitHubInfoErrorDomain;

/* An account younger than this many days earns a warning before a download. */
extern const NSInteger AGGitHubMinimumAccountAgeDays;

/*
 * What AppGarden asks GitHub about the repository an AppImage comes from:
 * how many stars it has, for the detail page, and how old the owning user or
 * organization is, before a download.
 *
 * Stars are read from the repository's web page: the API allows 60 anonymous
 * requests per hour per address, which one desktop uses up in minutes of
 * browsing, while the page is not metered that way. The age of an account is
 * not on any page, so it comes from the API, once per owner: the creation
 * date never changes, so it is kept on disk for good and a second download
 * from the same owner costs no request.
 *
 * Foundation only. The fetch goes through curl on an NSOperationQueue, like
 * the catalog and the images, and every completion arrives on the main queue.
 */
@class AGApp;

@interface AGGitHubInfo : NSObject

- (instancetype)initWithCacheDirectory:(NSString *)directory
                            webBaseURL:(NSString *)webBaseURL
                            apiBaseURL:(NSString *)apiBaseURL NS_DESIGNATED_INITIALIZER;
/* github.com and api.github.com, caching under the default cache directory. */
- (instancetype)init;

/* The star count, from the cache when it is under six hours old. */
- (void)starsForRepo:(NSString *)repo
          completion:(void (^)(NSNumber *stars, NSError *error))completion;

/* When the user or organization was created, from the disk when known. */
- (void)accountCreationDateForOwner:(NSString *)owner
                         completion:(void (^)(NSDate *date, NSError *error))completion;

/* The repository an app's AppImage comes from: its GitHub repository when the
 * feed names one, else the repository a direct link on github.com points into
 * (https://github.com/owner/repo/releases/download/...). Nil for an app that
 * is not hosted on GitHub. */
+ (NSString *)repositoryForApp:(AGApp *)app;

/* "owner" of "owner/repo", nil for anything else. */
+ (NSString *)ownerOfRepo:(NSString *)repo;

/* The count in the title of the repository page's star counter, which holds
 * the exact number (the visible text is abbreviated). Nil when the page has
 * no such counter. */
+ (NSNumber *)starCountFromRepositoryHTML:(NSString *)html;

/* created_at of a /users/<name> answer; an error naming GitHub's own
 * message when the answer is something else, such as the rate limit. */
+ (NSDate *)creationDateFromUserJSON:(NSData *)data error:(NSError **)error;

/* Whole days from date to now, 0 for a date in the future. */
+ (NSInteger)daysFromDate:(NSDate *)date toDate:(NSDate *)now;

/* The sentence a download warns with about an account created on date, or nil
 * when the account is at least AGGitHubMinimumAccountAgeDays old. A nil date
 * is a warning of its own, because not knowing is not the same as being old. */
+ (NSString *)warningForAccountCreatedOn:(NSDate *)date now:(NSDate *)now;

@end
