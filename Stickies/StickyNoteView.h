/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@interface StickyNoteView : NSView
{
    NSColor *backgroundColor;
    NSTextView *textView;
    NSScrollView *scrollView;
    BOOL resizing;
    NSPoint resizeStartPoint;
    NSRect resizeStartFrame;
    NSTrackingRectTag resizeCursorTag;
}

@property (nonatomic, retain) NSColor *backgroundColor;
@property (nonatomic, readonly) NSTextView *textView;

- (void)setNoteColor:(NSColor *)color;
- (BOOL)isInTitleBar:(NSPoint)point;
- (BOOL)isInResizeHandle:(NSPoint)point;
// Shared by -isInResizeHandle: (hit testing) and the cursor tracking rect,
// so the grip's geometry is defined in exactly one place.
- (NSRect)resizeHandleRect;

@end