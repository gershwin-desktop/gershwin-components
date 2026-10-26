/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import "ObjectTesting.h"
#import "StickyNoteView.h"

#define RESIZE_HANDLE_SIZE 12.0

int main(void)
{
    @autoreleasepool {
        /* StickyNoteView's initWithFrame: builds an NSTextView, and NSFont
         * needs a backend connection before it can be touched at all - run
         * this tool against a private Xvfb, never the user's :0. */
        [NSApplication sharedApplication];

        START_SET("resize handle geometry (cursor tracking rect)")

        StickyNoteView *view = [[StickyNoteView alloc]
            initWithFrame:NSMakeRect(0, 0, 200, 150)];

        NSRect handle = [view resizeHandleRect];
        PASS(handle.size.width == RESIZE_HANDLE_SIZE &&
             handle.size.height == RESIZE_HANDLE_SIZE,
             "the grip is a fixed-size square");
        PASS(handle.origin.x == 200 - RESIZE_HANDLE_SIZE &&
             handle.origin.y == 150 - RESIZE_HANDLE_SIZE,
             "the grip sits in the bottom-right corner of the view's own bounds");

        /* Points a hovering cursor would actually sample. */
        PASS(NSPointInRect(NSMakePoint(199, 149), handle),
             "a point deep in the corner is in the grip");
        PASS(!NSPointInRect(NSMakePoint(100, 75), handle),
             "the middle of the note is not in the grip");
        PASS(!NSPointInRect(NSMakePoint(0, 0), handle),
             "the opposite corner is not in the grip");

        /* -isInResizeHandle: must agree with -resizeHandleRect (no window,
         * so -isCollapsed on a nil window returns NO and the check proceeds
         * on geometry alone). */
        PASS([view isInResizeHandle:NSMakePoint(195, 145)],
             "isInResizeHandle: agrees with resizeHandleRect for a corner point");
        PASS(![view isInResizeHandle:NSMakePoint(50, 50)],
             "isInResizeHandle: agrees with resizeHandleRect away from the corner");

        [view setFrameSize:NSMakeSize(300, 220)];
        NSRect resized = [view resizeHandleRect];
        PASS(resized.origin.x == 300 - RESIZE_HANDLE_SIZE &&
             resized.origin.y == 220 - RESIZE_HANDLE_SIZE,
             "the grip tracks the view after a resize, not a frame baked in at init");

        [view release];

        END_SET("resize handle geometry (cursor tracking rect)")
    }
    return 0;
}
