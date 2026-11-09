/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class AGCatalog;

/*
 * The catalog location. Overridable with the AGFeedURL user default so tests
 * and development can point the app at a local file server.
 */
extern NSString *const AGFeedURLString;

/*
 * completion always arrives on the main queue.
 * fromCache YES means no network was used for this result. catalog and error
 * are both non-nil when a fetch failed but an older catalog could be served,
 * because the caller has to show the banner and the error text; catalog nil
 * and error non-nil means there was nothing to show at all.
 */
typedef void (^AGFeedLoadCompletion)(AGCatalog *catalog, BOOL fromCache, NSError *error);

/*
 * Fetches feed.json with curl and keeps the last good copy on disk.
 *
 * curl through NSTask instead of NSURLSession: in this stack the session
 * APIs block the main thread on DNS and mishandle redirects, and every other
 * network component here (Books, PackageManager, SoftwareUpdate) does this.
 */
@interface AGFeedLoader : NSObject

/* Designated initializer; tests point it at a temporary directory.
 * nil means ~/Library/Caches/io.github.gershwin-desktop.AppGarden */
- (instancetype)initWithCacheDirectory:(NSString *)directory NS_DESIGNATED_INITIALIZER;

- (instancetype)init;

@property (nonatomic, readonly, copy) NSString *cacheDirectory;

/* <cacheDirectory>/feed.json */
@property (nonatomic, readonly, copy) NSString *cachePath;

/* YES while a load is in flight; the Reload menu item validates on it. */
@property (nonatomic, readonly, getter=isLoading) BOOL loading;

- (void)loadWithCompletion:(AGFeedLoadCompletion)completion;

/* Skips the "cache is younger than the max age" step and sends no
 * If-Modified-Since, so the user always gets the current feed. */
- (void)reloadIgnoringCacheWithCompletion:(AGFeedLoadCompletion)completion;

@end
