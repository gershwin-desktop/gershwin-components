/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class BookPageView;
@class BookPageTextView;

@protocol BookPageViewDelegate <NSObject>
- (void)pageViewDidRequestNext:(BookPageView *)view;
- (void)pageViewDidRequestPrevious:(BookPageView *)view;
// Ctrl + scroll wheel: `delta` is the wheel's deltaY (positive = zoom in).
- (void)pageView:(BookPageView *)view fontSizeDelta:(CGFloat)delta;
// The user asked to highlight the selection (menu, context menu); `range` is
// absolute in the book's concatenated reading text. Selecting alone never
// highlights, so copying text leaves no marks behind.
- (void)pageView:(BookPageView *)view highlightRange:(NSRange)range;
// Select All selects the reading unit (the chapter) around `index`, the first
// character shown; the page view does not know where chapters begin.
- (NSRange)pageView:(BookPageView *)view selectAllRangeAtIndex:(NSUInteger)index;
@end

@interface BookPageView : NSView

@property (nonatomic, weak) id<BookPageViewDelegate> delegate;

@property (nonatomic, strong) NSColor *backgroundColor;
@property (nonatomic, strong) NSColor *textColor;
// Footer page numbers, one per paginated visual page, in page order. An empty
// string (or an index past the end) means "draw nothing" for that page.
@property (nonatomic, copy) NSArray<NSString *> *pageLabels;
// Active highlights to paint over the text. Each entry is an NSDictionary with
// keys @"range" (NSValue wrapping an NSRange, absolute in the reading text) and
// @"color" (an NSColor). Painted as translucent background behind the glyphs.
@property (nonatomic, copy) NSArray<NSDictionary *> *highlights;

- (void)configureWithAttributedString:(NSAttributedString *)attr;
- (NSSize)contentSize;
- (void)setThemeTextColor:(NSColor *)textColor;
// Total paginated visual pages. Read-only: pages are derived natively from the
// view's own geometry in -configureWithAttributedString: and on every resize.
@property (nonatomic, assign, readonly) NSUInteger pageCount;
- (NSRange)rangeForPage:(NSUInteger)page;
// Visual page index (0-based) shown at `side` (0 = left/verso, 1 = right/recto)
// of `spread`. Returns NSNotFound when that side is intentionally blank (the
// first spread opens on the right, so its left page is empty, like a real book).
- (NSUInteger)pageIndexForSpread:(NSUInteger)spread side:(NSUInteger)side;
// The spread that displays visual page `page`.
- (NSUInteger)spreadForPageIndex:(NSUInteger)page;
- (NSUInteger)spreadCount;
- (NSUInteger)currentSpread;
- (BOOL)canGoNext;
- (BOOL)canGoPrevious;
- (void)showSpread:(NSUInteger)spread animated:(BOOL)animated;
- (void)next;
- (void)previous;
- (NSUInteger)pageForCharacterIndex:(NSUInteger)idx;
// The current selection, absolute in the reading text; {NSNotFound, 0} if none.
- (NSRange)selectedRange;
// Edit actions answered by this view as first responder; Copy writes plain text
// and RTF to the general pasteboard.
- (void)copy:(id)sender;
- (void)selectAll:(id)sender;
- (void)highlightSelection:(id)sender;

@end
