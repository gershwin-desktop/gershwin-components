/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import "ObjectTesting.h"
#import "StickyNoteDocument.h"

int main(void)
{
    @autoreleasepool {
        /* StickyNoteDocument falls back to NSFont fontWithName:, which needs
         * a backend connection - run this tool against a private Xvfb. */
        [NSApplication sharedApplication];

        START_SET("scroll position round-trips through the saved database")

        StickyNoteDocument *doc = [[StickyNoteDocument alloc]
            initWithText:@"line one\nline two\nline three"
                   color:nil frame:NSMakeRect(10, 20, 280, 240)
                    font:nil
              floatOnTop:NO translucent:NO collapsed:NO
            creationDate:[NSDate date] modificationDate:[NSDate date]];

        PASS(NSEqualPoints(doc.scrollPosition, NSZeroPoint),
             "a fresh note starts scrolled to the top");

        doc.scrollPosition = NSMakePoint(0, 42);
        NSDictionary *dict = [doc dictionaryRepresentation];
        PASS([dict objectForKey:@"scrollY"] != nil,
             "the saved record carries the vertical scroll offset");
        PASS([[dict objectForKey:@"scrollY"] floatValue] == 42,
             "the saved value matches what was set");

        StickyNoteDocument *reloaded = [[StickyNoteDocument alloc]
            initWithDictionary:dict];
        PASS(NSEqualPoints(reloaded.scrollPosition, NSMakePoint(0, 42)),
             "reloading the record restores the exact scroll position");

        /* A database written before scroll tracking existed has no
         * scrollX/scrollY keys; loading it must not crash and must open at
         * the top rather than some garbage offset. */
        NSMutableDictionary *legacy = [[dict mutableCopy] autorelease];
        [legacy removeObjectForKey:@"scrollX"];
        [legacy removeObjectForKey:@"scrollY"];
        StickyNoteDocument *fromLegacy = [[StickyNoteDocument alloc]
            initWithDictionary:legacy];
        PASS(NSEqualPoints(fromLegacy.scrollPosition, NSZeroPoint),
             "a record saved before this feature existed opens at the top");

        [doc release];
        [reloaded release];
        [fromLegacy release];

        END_SET("scroll position round-trips through the saved database")
    }
    return 0;
}
