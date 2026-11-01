/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <AppKit/AppKit.h>

/* The row builders every part of the Mouse pane lays its controls out with,
 * so all device sections, the curve editor and the pane itself share one
 * look (AppearanceMetrics).  Rows are top-anchored (their distance to the
 * top of their view stays fixed) and either stretch with their view or keep
 * their distance to its left or right edge.  The returned controls are
 * autoreleased and owned by the view they are added to. */

typedef NS_ENUM(NSInteger, MousePaneRowResizing) {
    MousePaneRowStretches,
    MousePaneRowKeepsLeft,
    MousePaneRowKeepsRight,
};

typedef struct {
    CGFloat x;
    CGFloat y;            /* bottom of the row */
    CGFloat width;
    CGFloat labelWidth;
    CGFloat valueWidth;   /* 0: no value field */
    MousePaneRowResizing resizing;
} MousePaneRow;

extern const CGFloat MousePaneCheckboxHeight;
extern const CGFloat MousePaneCheckboxStep;
extern const CGFloat MousePaneRowHeight;

NSTextField *MousePaneLabel(NSString *text, NSRect frame, NSTextAlignment alignment);

/* Keeps its distance to the right edge, like the column it sits in. */
NSButton *MousePaneAddCheckbox(NSView *view, NSString *title, NSRect frame,
                               id target, SEL action);

/* label, slider and (with valueWidth) a value field to its right. */
NSSlider *MousePaneAddSliderRow(NSView *view, NSString *label, MousePaneRow row,
                                NSTextField **value, id target, SEL action);

NSPopUpButton *MousePaneAddPopUpRow(NSView *view, NSString *label, MousePaneRow row,
                                    id target, SEL action);
