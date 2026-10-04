/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

extern NSString *const AGGitHubInfoErrorDomain;

/*
 * What AppGarden asks GitHub about the repository an AppImage comes from: how
 * many stars it has, for the detail page.
 *
 * The count is read from the repository's web page: the API allows 60
 * anonymous requests per hour per address, which one desktop uses up in
 * minutes of browsing, while the page is not metered that way.
 *
 * Foundation only. The fetch goes through curl on an NSOperationQueue, like
 * the catalog and the images, and every completion arrives on the main queue.
 */
@class AGApp;

/* The most characters of README kept per repository. */
extern const NSUInteger AGGitHubPageTextLimit;

@interface AGGitHubInfo : NSObject

- (instancetype)initWithCacheDirectory:(NSString *)directory
                            webBaseURL:(NSString *)webBaseURL NS_DESIGNATED_INITIALIZER;
/* github.com, caching under the default cache directory. */
- (instancetype)init;

/* The star count, from the cache when it is under six hours old. */
- (void)starsForRepo:(NSString *)repo
          completion:(void (^)(NSNumber *stars, NSError *error))completion;

/* What the repository's front page says about itself, as plain text: its
 * description and its README. This is what the risk check reads besides the
 * catalog's own entry, because a catalog entry is often one line while the
 * README says what the software really is. Served from the same page and the
 * same cache as the star count, so asking for both costs one request. */
- (void)pageTextForRepo:(NSString *)repo
             completion:(void (^)(NSString *text, NSError *error))completion;

/* The repository an app's AppImage comes from: its GitHub repository when the
 * feed names one, else the repository a direct link on github.com points into
 * (https://github.com/owner/repo/releases/download/...). Nil for an app that
 * is not hosted on GitHub. */
+ (NSString *)repositoryForApp:(AGApp *)app;

/* "owner" of "owner/repo", nil for anything else. */
+ (NSString *)ownerOfRepo:(NSString *)repo;

/* The description and README of a repository page as plain text: tags and
 * scripts dropped, entities decoded, white space collapsed, at most
 * AGGitHubPageTextLimit characters. Only those two parts of the page are
 * read, not the page around them, whose menus mention AI and Copilot on every
 * repository. Nil when the page has neither. */
+ (NSString *)pageTextFromRepositoryHTML:(NSString *)html;

/* The count in the title of the repository page's star counter, which holds
 * the exact number (the visible text is abbreviated). Nil when the page has
 * no such counter. */
+ (NSNumber *)starCountFromRepositoryHTML:(NSString *)html;

@end
