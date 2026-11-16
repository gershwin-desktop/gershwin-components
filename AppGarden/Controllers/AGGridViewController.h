/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "AGPage.h"

@class AGApp, AGAppGridView, AGGridViewController, AGImageCache, AGInstaller;

@protocol AGGridViewControllerDelegate <NSObject>
- (void)gridViewController:(AGGridViewController *)controller didSelectApp:(AGApp *)app;
@end

/* One grid page: the scroll view around an AGAppGridView plus the list it
   shows. The window controller keeps one per navigation entry and swaps
   their views in and out of the page area. */
@interface AGGridViewController : NSViewController <AGPage>

- (instancetype)initWithImageCache:(AGImageCache *)imageCache
                         installer:(AGInstaller *)installer NS_DESIGNATED_INITIALIZER;

@property (nonatomic, weak) id<AGGridViewControllerDelegate> delegate;
@property (nonatomic, readonly) AGAppGridView *gridView;
@property (nonatomic, copy) NSArray<AGApp *> *apps;
@property (nonatomic, getter=isLoading) BOOL loading;
@property (nonatomic, copy) NSString *emptyMessage;

@end
