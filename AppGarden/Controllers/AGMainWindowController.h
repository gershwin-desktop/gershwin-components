/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class AGFeedLoader, AGImageCache, AGInstaller;

/* The single window: sidebar on the left, the top bar with Back, title and
   search, the optional status banner and the page stack on the right.
   Also the target of every catalog and navigation menu item. */
@interface AGMainWindowController : NSWindowController

- (instancetype)initWithFeedLoader:(AGFeedLoader *)feedLoader
                        imageCache:(AGImageCache *)imageCache
                         installer:(AGInstaller *)installer NS_DESIGNATED_INITIALIZER;

/* Fetches the catalog (from the cache when it is fresh) and shows it. */
- (void)loadCatalog;

- (void)showDiscover:(id)sender;
- (void)showInstalled:(id)sender;
- (void)reloadCatalog:(id)sender;
- (void)goBack:(id)sender;
- (void)focusSearchField:(id)sender;

@end
