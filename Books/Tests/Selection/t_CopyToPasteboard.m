/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The RTF writer resolves fonts through the display backend, so this tool
   needs an X display: run it with DISPLAY set to a private Xvfb, never the
   desktop's. It writes only to a uniquely named pasteboard, so the user's
   clipboard is never touched. */
#import <AppKit/AppKit.h>
#import "Testing.h"
#import "BookTextExtraction.h"

/* Unit under test: compile its implementation directly into this TU. */
#include "../../BookTextExtraction.m"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  if (getenv("DISPLAY") == NULL)
    {
      fprintf(stderr, "t_CopyToPasteboard needs DISPLAY (a private Xvfb)\n");
      return 1;
    }
  [NSApplication sharedApplication];

  /* --- written to a private pasteboard as plain text and RTF --- */
  {
    NSPasteboard *pb = [NSPasteboard pasteboardWithUniqueName];
    NSMutableAttributedString *t = [[NSMutableAttributedString alloc]
      initWithString:@"One para­graph.\nTwo paragraphs.\nThree."];
    [t addAttribute:NSUnderlineStyleAttributeName
              value:[NSNumber numberWithInteger:NSUnderlineStyleSingle]
              range:NSMakeRange(0, 3)];
    NSRange r = NSMakeRange(0, [[t string] rangeOfString:@"Three"].location);
    PASS([BookTextExtraction writeRange:r ofText:t toPasteboard:pb], "write succeeds");
    PASS_EQUAL([pb stringForType:NSStringPboardType],
               @"One paragraph.\nTwo paragraphs.\n", "plain text flavour");
    NSData *rtf = [pb dataForType:NSRTFPboardType];
    NSAttributedString *back = rtf ? [[NSAttributedString alloc] initWithRTF:rtf
                                                           documentAttributes:NULL] : nil;
    PASS_EQUAL([back string], @"One paragraph.\nTwo paragraphs.\n", "RTF flavour round-trips");
    PASS(![BookTextExtraction writeRange:NSMakeRange(NSNotFound, 0) ofText:t toPasteboard:pb],
         "nothing selected writes nothing");
    [pb releaseGlobally];
  }

  [arp release];
  return 0;
}
