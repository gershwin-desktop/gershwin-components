/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class AGApp, AGAppGridView, AGImageCache, AGInstaller;

/*
 * Reported when a card is clicked or Return is pressed on the focused card.
 */
@protocol AGAppGridViewDelegate <NSObject>
- (void)appGridView:(AGAppGridView *)gridView didSelectApp:(AGApp *)app;
@end

/*
 * The document view of the grid page: a flipped NSView that owns one
 * AGAppCardView per visible item and throws the rest away.
 *
 * It is flipped so "first row at the top" falls out of AGGridLayout's y-down
 * frames instead of being inverted somewhere. It is placed in an NSScrollView
 * by the controller, which configures the scroller; the view itself only
 * keeps its width matching the clip view and its height matching the content.
 *
 * Recycled cards, not hidden ones: a hidden card still sits in the view
 * hierarchy, still costs its backing store and still takes part in hit
 * testing, and with 1551 catalog entries the difference is the whole point.
 */
@interface AGAppGridView : NSView

/*
 * Designated initializer. Both services are handed down from the app
 * delegate; the image cache feeds the cards' icons and the installer is
 * passed straight to the buttons they own.
 */
- (instancetype)initWithFrame:(NSRect)frame
                   imageCache:(AGImageCache *)imageCache
                    installer:(AGInstaller *)installer NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@property (nonatomic, weak) id<AGAppGridViewDelegate> delegate;

/* The page's items in catalog order. Replacing it recycles every card. */
@property (nonatomic, copy) NSArray<AGApp *> *apps;

/* YES only before the first catalog arrives: a 32-point spinner over
 * "Loading catalog...". */
@property (nonatomic, getter=isLoading) BOOL loading;

/*
 * Centered gray line shown when apps is empty and loading is NO. nil draws
 * nothing. Build the text with one of the two helpers below so the wording
 * stays in this file with the rest of the view's strings.
 */
@property (nonatomic, copy) NSString *emptyMessage;

/*
 * Enter the grid from the search field, and step it afterwards. delta +1
 * lands on the first card and steps down, -1 lands on the last card and
 * steps up; once a card is focused, delta simply moves that far. The
 * convention matches Build's search field so the controller can wire its
 * target straight to this.
 */
- (void)exitSearchFieldIntoResultsWithDelta:(NSInteger)delta;

/* "No applications match \"foo\"." */
+ (NSString *)emptyMessageForSearchQuery:(NSString *)query;
/* The Installed page's empty state. */
+ (NSString *)installedEmptyMessage;

@end
