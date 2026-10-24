/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "BookTextSelection.h"

/* Unit under test: compile its implementation directly into this TU. */
#include "../../BookTextSelection.m"

static NSString * const kText =
  @"First para has words.\nSecond para, long enough to drag.\nThird one.";

static BOOL RangeIs(NSRange r, NSUInteger loc, NSUInteger len)
{
  return r.location == loc && r.length == len;
}

/* Bring a fresh selection into `state` through its public events only. */
static BookTextSelection *InState(BookSelectionState state)
{
  BookTextSelection *s = [[BookTextSelection alloc] initWithString:kText];
  if (state == BookSelectionSelected)
    [s selectRange:NSMakeRange(0, 5)];
  else if (state == BookSelectionTracking)
    [s pressAtIndex:3 clickCount:1 extend:NO];
  return s;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* --- plain drag selects text and keeps it after release --- */
  {
    BookTextSelection *s = [[BookTextSelection alloc] initWithString:kText];
    [s pressAtIndex:22 clickCount:1 extend:NO];
    [s dragToIndex:40];
    PASS(RangeIs([s selectedRange], 22, 18), "drag selects from press to pointer");
    PASS([s releaseButton] == BookSelectionReleaseNone, "a drag is not a click");
    PASS([s state] == BookSelectionSelected, "selection stays after mouse up");
    PASS(RangeIs([s selectedRange], 22, 18), "range kept after mouse up");
  }

  /* --- dragging backwards selects the same span --- */
  {
    BookTextSelection *s = [[BookTextSelection alloc] initWithString:kText];
    [s pressAtIndex:40 clickCount:1 extend:NO];
    [s dragToIndex:22];
    PASS(RangeIs([s selectedRange], 22, 18), "backward drag normalised");
  }

  /* --- plain click: page turn when nothing selected, dismiss otherwise --- */
  {
    BookTextSelection *s = [[BookTextSelection alloc] initWithString:kText];
    [s pressAtIndex:5 clickCount:1 extend:NO];
    PASS([s releaseButton] == BookSelectionReleaseClick, "click on unselected text is a click");
    PASS([s state] == BookSelectionIdle, "click leaves no selection");

    [s selectRange:NSMakeRange(0, 5)];
    [s pressAtIndex:30 clickCount:1 extend:NO];
    PASS(![s hasSelection], "click elsewhere drops the selection at once");
    PASS([s releaseButton] == BookSelectionReleaseDismissed, "the click only dismissed the selection");
    PASS([s state] == BookSelectionIdle, "dismissed selection leaves Idle");
  }

  /* --- a press with a zero-length drag is still a click --- */
  {
    BookTextSelection *s = [[BookTextSelection alloc] initWithString:kText];
    [s pressAtIndex:5 clickCount:1 extend:NO];
    [s dragToIndex:5];
    PASS([s releaseButton] == BookSelectionReleaseClick, "jitter without movement is a click");
  }

  /* --- double-click selects a word, triple-click a paragraph --- */
  {
    BookTextSelection *s = [[BookTextSelection alloc] initWithString:kText];
    [s pressAtIndex:15 clickCount:2 extend:NO];          /* inside "words" */
    PASS(RangeIs([s selectedRange], 15, 5), "double-click selects the word");
    PASS([s releaseButton] == BookSelectionReleaseNone, "double-click is not a page turn");
    PASS([s state] == BookSelectionSelected, "word stays selected");

    [s pressAtIndex:30 clickCount:3 extend:NO];          /* in "Second para" */
    PASS(RangeIs([s selectedRange], 22, 34), "triple-click selects the paragraph");
    [s releaseButton];
  }

  /* --- word drag extends by whole words --- */
  {
    BookTextSelection *s = [[BookTextSelection alloc] initWithString:kText];
    [s pressAtIndex:7 clickCount:2 extend:NO];           /* "para" 6..10 */
    [s dragToIndex:16];                                  /* inside "words" */
    PASS(RangeIs([s selectedRange], 6, 14), "word drag snaps both ends to words");
  }

  /* --- paragraph drag covers whole paragraphs, across paragraphs --- */
  {
    BookTextSelection *s = [[BookTextSelection alloc] initWithString:kText];
    [s pressAtIndex:2 clickCount:3 extend:NO];
    [s dragToIndex:30];
    PASS(RangeIs([s selectedRange], 0, 56), "paragraph drag covers two paragraphs");
  }

  /* --- shift-click extends from the anchor --- */
  {
    BookTextSelection *s = [[BookTextSelection alloc] initWithString:kText];
    [s pressAtIndex:22 clickCount:1 extend:NO];
    [s dragToIndex:28];
    [s releaseButton];
    [s pressAtIndex:60 clickCount:1 extend:YES];
    PASS(RangeIs([s selectedRange], 22, 38), "shift-click moves the far end");
    PASS([s releaseButton] == BookSelectionReleaseNone, "shift-click is not a page turn");
    [s pressAtIndex:10 clickCount:1 extend:YES];
    PASS(RangeIs([s selectedRange], 10, 12), "shift-click before the anchor flips");
    [s releaseButton];
  }

  /* --- a plain click places the anchor a later shift-click extends from --- */
  {
    BookTextSelection *s = [[BookTextSelection alloc] initWithString:kText];
    [s pressAtIndex:22 clickCount:1 extend:NO];
    [s releaseButton];
    [s pressAtIndex:40 clickCount:1 extend:YES];
    PASS(RangeIs([s selectedRange], 22, 18), "click then shift-click selects between them");
    [s releaseButton];
  }

  /* --- shift-click with no selection starts one from the press --- */
  {
    BookTextSelection *s = [[BookTextSelection alloc] initWithString:kText];
    [s pressAtIndex:4 clickCount:1 extend:YES];
    PASS(![s hasSelection], "shift-press alone selects nothing");
    PASS([s releaseButton] == BookSelectionReleaseNone, "shift-click never turns the page");
  }

  /* --- word and paragraph helpers --- */
  {
    PASS(RangeIs([BookTextSelection wordRangeAtIndex:0 inString:kText], 0, 5),
         "word at start of text");
    PASS(RangeIs([BookTextSelection wordRangeAtIndex:5 inString:kText], 5, 1),
         "a space is its own unit");
    NSString *apos = @"don't stop";
    PASS(RangeIs([BookTextSelection wordRangeAtIndex:1 inString:apos], 0, 5),
         "apostrophe stays inside the word");
    NSString *shy = @"sim­ple word";
    PASS(RangeIs([BookTextSelection wordRangeAtIndex:0 inString:shy], 0, 7),
         "soft hyphen does not split a word");
    PASS(RangeIs([BookTextSelection paragraphRangeAtIndex:70 inString:kText], 56, 10),
         "last paragraph without newline");
    PASS(RangeIs([BookTextSelection wordRangeAtIndex:999 inString:kText], 66, 0),
         "index past the end clamps");
  }

  /* --- setting new text drops the selection --- */
  {
    BookTextSelection *s = [[BookTextSelection alloc] initWithString:kText];
    [s selectRange:NSMakeRange(1, 3)];
    [s setString:@"other"];
    PASS(![s hasSelection] && [s state] == BookSelectionIdle, "new text clears selection");
  }

  /* --- every state x event pair is decided --- */
  {
    BookSelectionState states[3] = { BookSelectionIdle, BookSelectionSelected,
                                     BookSelectionTracking };
    for (int i = 0; i < 3; i++)
      {
        BookSelectionState st = states[i];
        BookTextSelection *s;

        s = InState(st); [s pressAtIndex:8 clickCount:1 extend:NO];
        PASS([s state] == BookSelectionTracking, "state %d + Press -> Tracking", i);
        s = InState(st); [s pressAtIndex:8 clickCount:2 extend:NO];
        PASS([s state] == BookSelectionTracking, "state %d + MultiPress -> Tracking", i);
        s = InState(st); [s pressAtIndex:8 clickCount:1 extend:YES];
        PASS([s state] == BookSelectionTracking, "state %d + ShiftPress -> Tracking", i);

        s = InState(st); [s dragToIndex:12];
        if (st == BookSelectionTracking)
          {
            PASS([s state] == BookSelectionTracking && RangeIs([s selectedRange], 3, 9),
                 "Tracking + Drag extends");
          }
        else
          {
            PASS([s state] == st, "state %d ignores Drag without a press", i);
          }

        s = InState(st);
        BookSelectionReleaseOutcome o = [s releaseButton];
        if (st == BookSelectionTracking)
          {
            PASS([s state] == BookSelectionIdle && o == BookSelectionReleaseClick,
                 "Tracking + Release (empty) -> Idle, click");
          }
        else
          {
            PASS([s state] == st && o == BookSelectionReleaseNone,
                 "state %d ignores Release without a press", i);
          }

        s = InState(st); [s clear];
        PASS([s state] == BookSelectionIdle && ![s hasSelection],
             "state %d + Clear -> Idle", i);
      }
  }

  [arp release];
  return 0;
}
