/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "BookTextSelection.h"

@implementation BookTextSelection
{
  NSString *_string;
  BookSelectionState _state;
  BookSelectionGranularity _granularity;
  // The fixed end of the selection (the unit pressed first) and the end that
  // follows the pointer; the selection is the span covering both units.
  NSUInteger _anchor;
  NSUInteger _head;
  BOOL _pressedWithSelection;
  BOOL _pressExtended;
}

- (instancetype)initWithString:(NSString *)string
{
  self = [super init];
  if (self)
    {
      _string = [string copy] ?: @"";
      _state = BookSelectionIdle;
      _anchor = NSNotFound;
      _head = NSNotFound;
    }
  return self;
}

- (NSString *)string { return _string; }

- (void)setString:(NSString *)string
{
  _string = [string copy] ?: @"";
  [self clear];
}

- (BookSelectionState)state { return _state; }
- (BookSelectionGranularity)granularity { return _granularity; }

- (NSUInteger)clamp:(NSUInteger)index
{
  NSUInteger len = [_string length];
  return (index == NSNotFound || index > len) ? len : index;
}

// The unit (character position, word or paragraph) at `index` for the current
// granularity; a character position is an empty range so a plain press selects
// nothing until the pointer moves.
- (NSRange)unitAtIndex:(NSUInteger)index
{
  switch (_granularity)
    {
      case BookSelectByWord:
        return [BookTextSelection wordRangeAtIndex:index inString:_string];
      case BookSelectByParagraph:
        return [BookTextSelection paragraphRangeAtIndex:index inString:_string];
      case BookSelectByCharacter:
        break;
    }
  return NSMakeRange([self clamp:index], 0);
}

- (NSRange)selectedRange
{
  if (_anchor == NSNotFound || _head == NSNotFound)
    return NSMakeRange(NSNotFound, 0);
  NSRange a = [self unitAtIndex:_anchor];
  NSRange h = [self unitAtIndex:_head];
  NSUInteger lo = MIN(a.location, h.location);
  NSUInteger hi = MAX(NSMaxRange(a), NSMaxRange(h));
  if (hi <= lo)
    return NSMakeRange(NSNotFound, 0);
  return NSMakeRange(lo, hi - lo);
}

- (BOOL)hasSelection
{
  return [self selectedRange].location != NSNotFound;
}

- (void)pressAtIndex:(NSUInteger)index clickCount:(NSInteger)clickCount extend:(BOOL)extend
{
  // Every state accepts a press: a release can be lost (the button let go
  // outside the window), and the new gesture must still start cleanly.
  index = [self clamp:index];
  _pressedWithSelection = [self hasSelection];
  _pressExtended = extend;
  if (extend && _anchor != NSNotFound)
    {
      // Shift-click keeps the anchor and its granularity, as a text editor does.
      _head = index;
    }
  else
    {
      _granularity = (clickCount >= 3) ? BookSelectByParagraph
                   : (clickCount == 2) ? BookSelectByWord
                   : BookSelectByCharacter;
      _anchor = index;
      _head = index;
    }
  _state = BookSelectionTracking;
}

- (void)dragToIndex:(NSUInteger)index
{
  // Motion without a pressed button belongs to no gesture.
  if (_state != BookSelectionTracking)
    return;
  _head = [self clamp:index];
}

- (BookSelectionReleaseOutcome)releaseButton
{
  if (_state != BookSelectionTracking)
    return BookSelectionReleaseNone;
  BOOL plainClick = (_granularity == BookSelectByCharacter && !_pressExtended);
  if ([self hasSelection])
    {
      _state = BookSelectionSelected;
      return BookSelectionReleaseNone;
    }
  // The anchor stays where the click landed, like a text editor's caret, so a
  // following shift-click selects from here.
  _state = BookSelectionIdle;
  if (!plainClick)
    return BookSelectionReleaseNone;
  return _pressedWithSelection ? BookSelectionReleaseDismissed : BookSelectionReleaseClick;
}

- (void)selectRange:(NSRange)range
{
  NSUInteger len = [_string length];
  if (range.location == NSNotFound || range.location >= len || range.length == 0)
    {
      [self clear];
      return;
    }
  _granularity = BookSelectByCharacter;
  _anchor = range.location;
  _head = MIN(NSMaxRange(range), len);
  _state = BookSelectionSelected;
}

- (void)clear
{
  _anchor = NSNotFound;
  _head = NSNotFound;
  _granularity = BookSelectByCharacter;
  _state = BookSelectionIdle;
}

// Letters and digits make words; an apostrophe between letters and a soft
// hyphen stay inside, so "don't" and a hyphenation point do not split a word.
static BOOL IsWordChar(NSString *s, NSUInteger i, NSCharacterSet *alnum)
{
  unichar c = [s characterAtIndex:i];
  if ([alnum characterIsMember:c] || c == 0x00AD)
    return YES;
  if (c == '\'' || c == 0x2019)
    {
      NSUInteger len = [s length];
      return i > 0 && i + 1 < len
        && [alnum characterIsMember:[s characterAtIndex:i - 1]]
        && [alnum characterIsMember:[s characterAtIndex:i + 1]];
    }
  return NO;
}

+ (NSRange)wordRangeAtIndex:(NSUInteger)index inString:(NSString *)string
{
  NSUInteger len = [string length];
  if (index >= len)
    return NSMakeRange(len, 0);
  NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
  if (!IsWordChar(string, index, alnum))
    return NSMakeRange(index, 1);
  NSUInteger lo = index;
  NSUInteger hi = index + 1;
  while (lo > 0 && IsWordChar(string, lo - 1, alnum))
    lo--;
  while (hi < len && IsWordChar(string, hi, alnum))
    hi++;
  return NSMakeRange(lo, hi - lo);
}

+ (NSRange)paragraphRangeAtIndex:(NSUInteger)index inString:(NSString *)string
{
  NSUInteger len = [string length];
  if (len == 0)
    return NSMakeRange(0, 0);
  if (index >= len)
    index = len - 1;
  return [string paragraphRangeForRange:NSMakeRange(index, 0)];
}

@end
