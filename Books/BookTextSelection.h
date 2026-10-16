/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// The reading selection as an explicit state machine, kept free of AppKit so
// every state x event pair is decided and tested headless. Indexes are absolute
// in the book's reading text, so a selection survives page turns and can span
// pages; the page view only maps points to indexes and paints the range.
//
//   state \ event   Press      MultiPress  ShiftPress  Drag       Release     Clear
//   Idle            Tracking   Tracking    Tracking    Idle(ign)  Idle(ign)   Idle
//   Selected        Tracking   Tracking    Tracking    Sel.(ign)  Sel.(ign)   Idle
//   Tracking        Tracking   Tracking    Tracking    Tracking   Idle|Sel.   Idle
//
// Release from Tracking ends in Selected when the range is non-empty, else in
// Idle; its outcome tells the owner whether the gesture was a plain click.

typedef NS_ENUM(NSUInteger, BookSelectionState)
{
  BookSelectionIdle,
  BookSelectionSelected,
  BookSelectionTracking
};

typedef NS_ENUM(NSUInteger, BookSelectionGranularity)
{
  BookSelectByCharacter,
  BookSelectByWord,
  BookSelectByParagraph
};

typedef NS_ENUM(NSUInteger, BookSelectionReleaseOutcome)
{
  // Not a plain click (a drag, a word/paragraph click or a shift-click), or a
  // release while no button was tracked.
  BookSelectionReleaseNone,
  // A plain click over unselected text: the owner may turn the page.
  BookSelectionReleaseClick,
  // A plain click that dismissed a selection; it must not also turn the page.
  BookSelectionReleaseDismissed
};

@interface BookTextSelection : NSObject

- (instancetype)initWithString:(NSString *)string;

// Replacing the text drops any selection, since its indexes no longer apply.
@property (nonatomic, copy) NSString *string;
@property (nonatomic, readonly) BookSelectionState state;
@property (nonatomic, readonly) BookSelectionGranularity granularity;
// {NSNotFound, 0} when nothing is selected.
@property (nonatomic, readonly) NSRange selectedRange;
- (BOOL)hasSelection;

// clickCount 1 selects by character, 2 by word, 3 or more by paragraph.
// `extend` (shift) keeps the existing anchor and moves the other end.
- (void)pressAtIndex:(NSUInteger)index clickCount:(NSInteger)clickCount extend:(BOOL)extend;
- (void)dragToIndex:(NSUInteger)index;
- (BookSelectionReleaseOutcome)releaseButton;
- (void)selectRange:(NSRange)range;
- (void)clear;

+ (NSRange)wordRangeAtIndex:(NSUInteger)index inString:(NSString *)string;
+ (NSRange)paragraphRangeAtIndex:(NSUInteger)index inString:(NSString *)string;

@end
