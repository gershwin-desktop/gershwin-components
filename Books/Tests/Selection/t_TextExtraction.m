/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "Testing.h"
#import "BookTextExtraction.h"
#import "EPUBPageRenderer.h"

/* Unit under test: compile its implementation directly into this TU. */
#include "../../BookTextExtraction.m"

/* EPUBPageRenderer.m is not linked; the attribute only needs a name here. */
NSString *EPUBPageBreakAttributeName = @"EPUBPageBreakAttribute";

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* --- paragraph breaks survive, soft hyphens and placeholders do not --- */
  {
    NSString *src = @"Intro.\nA sim­ple para­graph \nends here.  \n"
                    @"Next Line break￼ done.";
    NSString *all = [BookTextExtraction plainTextInRange:NSMakeRange(0, [src length])
                                                ofString:src];
    PASS_EQUAL(all, @"Intro.\nA simple paragraph\nends here.\nNext\nLine\nbreak done.",
               "plain text keeps paragraphs, joins soft hyphens, drops placeholders");

    NSRange two = [src rangeOfString:@"A sim"];
    two.length = [src rangeOfString:@"Next"].location - two.location;
    PASS_EQUAL([BookTextExtraction plainTextInRange:two ofString:src],
               @"A simple paragraph\nends here.\n",
               "two paragraphs copied with their break");
  }

  /* --- out-of-range requests are clamped, never raise --- */
  {
    NSString *src = @"short";
    PASS_EQUAL([BookTextExtraction plainTextInRange:NSMakeRange(2, 99) ofString:src],
               @"ort", "range clamped to the text");
    PASS_EQUAL([BookTextExtraction plainTextInRange:NSMakeRange(NSNotFound, 0)
                                           ofString:src],
               @"", "no selection copies nothing");
  }

  /* --- a range across a chapter/page break carries no page furniture --- */
  {
    NSMutableAttributedString *t = [[NSMutableAttributedString alloc]
      initWithString:@"end of chapter one.\nChapter Two\n"];
    [t addAttribute:EPUBPageBreakAttributeName value:@YES range:NSMakeRange(20, 1)];
    NSAttributedString *rich = [BookTextExtraction richTextInRange:NSMakeRange(0, [t length])
                                                            ofText:t];
    PASS_EQUAL([rich string], @"end of chapter one.\nChapter Two\n",
               "page break joins the text with nothing inserted");
    PASS([rich attribute:EPUBPageBreakAttributeName atIndex:20 effectiveRange:NULL] == nil,
         "reader-private attributes are not exported");
  }

  /* --- rich text keeps fonts, drops theme colours and invisible chars --- */
  {
    /* Styling without NSFont: fonts need a display backend, an underline does
       not, and both go through the same attribute filtering. */
    NSNumber *under = [NSNumber numberWithInteger:NSUnderlineStyleSingle];
    NSMutableAttributedString *t = [[NSMutableAttributedString alloc]
      initWithString:@"Bold sof­t text"];
    [t addAttribute:NSUnderlineStyleAttributeName value:under range:NSMakeRange(0, 4)];
    [t addAttribute:NSForegroundColorAttributeName value:[NSColor whiteColor]
              range:NSMakeRange(0, [t length])];
    [t addAttribute:NSBackgroundColorAttributeName value:[NSColor yellowColor]
              range:NSMakeRange(0, [t length])];
    NSAttributedString *rich = [BookTextExtraction richTextInRange:NSMakeRange(0, [t length])
                                                            ofText:t];
    PASS_EQUAL([rich string], @"Bold soft text", "rich text joins soft hyphen");
    PASS_EQUAL([rich attribute:NSUnderlineStyleAttributeName atIndex:0 effectiveRange:NULL],
               under, "styling preserved");
    PASS([rich attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL] == nil,
         "theme text colour not exported (white text on a light document)");
    PASS([rich attribute:NSBackgroundColorAttributeName atIndex:0 effectiveRange:NULL] == nil,
         "highlight background not exported");
  }

  [arp release];
  return 0;
}
