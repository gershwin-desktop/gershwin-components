/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

/*
 * Icon and screenshot loader with a memory and a disk cache.
 *
 * Everything it fetches comes from https://appimage.github.io/database/...,
 * the URLs the parser built: GitHub Pages serves those without a rate limit,
 * while raw.githubusercontent.com throttles bursts and api.github.com allows
 * only 60 anonymous requests per hour. Nothing is ever rewritten to either of
 * those, and nothing but images is fetched while the user browses.
 */
/* Twice the largest size an icon is shown at (128 points on the detail
   page), so a scaled display still has pixels to spare. */
extern const NSUInteger AGImageCacheIconPixelSize;

@interface AGImageCache : NSObject

/* Designated initializer; nil means
 * ~/Library/Caches/io.github.gershwin-desktop.AppGarden/images */
- (instancetype)initWithCacheDirectory:(NSString *)directory NS_DESIGNATED_INITIALIZER;

- (instancetype)init;

/*
 * Memory hit or nil. Synchronous and main-thread only: a card that is being
 * laid out must not block on a fetch, it asks again once the load finishes.
 */
- (NSImage *)cachedImageForURL:(NSURL *)url;

/*
 * completion arrives on the main queue. Exactly one of image and error is
 * non-nil. A URL that already failed this launch is not requested again;
 * that is what stops a scroll from turning into a request storm, and it is
 * not a fallback: the caller shows the placeholder and the user can scroll
 * back after a relaunch.
 */
- (void)imageForURL:(NSURL *)url completion:(void (^)(NSImage *image, NSError *error))completion;
/* The same, holding a bitmap no larger than maximumPixelSize on either side
   in memory (the disk copy stays as downloaded); 0 keeps the original. Icons
   ask for AGImageCacheIconPixelSize, screenshots for 0. */
- (void)imageForURL:(NSURL *)url
   maximumPixelSize:(NSUInteger)maximumPixelSize
         completion:(void (^)(NSImage *image, NSError *error))completion;

/* Drops the pending completions for a URL when its card leaves the screen. */
- (void)cancelRequestsForURL:(NSURL *)url;

@end
