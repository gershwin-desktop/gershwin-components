/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class SCPageListView, SCImage;

@protocol SCPageListViewDelegate <NSObject>
/* index 0 is the scanner bed (the preview), pages follow from 1 */
- (void) pageList: (SCPageListView *)list didSelectIndex: (NSInteger)index;
- (void) pageListDeleteSelected: (SCPageListView *)list;
/* A second line under a page, e.g. how far its text recognition is; may be nil */
- (NSString *) pageList: (SCPageListView *)list noteForPage: (SCImage *)page;
@end

/*
 * The scanned pages as thumbnails in a column, after an entry for the
 * scanner bed. Pages are what will be saved, so the user sees exactly
 * that: black and white, inverted, cropped, as processed.
 */
@interface SCPageListView : NSView

@property (nonatomic, weak) id<SCPageListViewDelegate> delegate;
@property (nonatomic, copy) NSArray *pages;
@property (nonatomic, strong) NSImage *bedImage;
@property (nonatomic) NSInteger selectedIndex;
/* NO for the document feeder, which has no bed to preview */
@property (nonatomic) BOOL showsBed;

/* Lays out again after pages, notes or the width changed */
- (void) reload;

@end
