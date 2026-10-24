/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "MousePaneControls.h"
#import "AppearanceMetrics.h"

const CGFloat MousePaneCheckboxHeight = METRICS_RADIO_BUTTON_SIZE;
const CGFloat MousePaneCheckboxStep = METRICS_RADIO_BUTTON_LINE_SPACING;
const CGFloat MousePaneRowHeight = METRICS_TEXT_INPUT_FIELD_HEIGHT;

/* Labels sit 1pt above the control's origin so their baseline lines up with
   the control's text. */
static const CGFloat kLabelHeight = 20;

NSTextField *MousePaneLabel(NSString *text, NSRect frame, NSTextAlignment alignment)
{
    NSTextField *label = [[[NSTextField alloc] initWithFrame:frame] autorelease];
    [label setStringValue:(text ? text : @"")];
    [label setBezeled:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setDrawsBackground:NO];
    [label setFont:[NSFont systemFontOfSize:11]];
    [label setAlignment:alignment];
    return label;
}

NSButton *MousePaneAddCheckbox(NSView *view, NSString *title, NSRect frame, id target, SEL action)
{
    NSButton *checkbox = [[[NSButton alloc] initWithFrame:frame] autorelease];
    [checkbox setButtonType:NSSwitchButton];
    [checkbox setTitle:title];
    [checkbox setTarget:target];
    [checkbox setAction:action];
    [checkbox setAutoresizingMask:NSViewMinYMargin | NSViewMinXMargin];
    [view addSubview:checkbox];
    return checkbox;
}

/* Lays out label | control | value across the row and returns the frame
   left for the control. */
static NSRect AddRowFrame(NSView *view, NSString *label, MousePaneRow row, NSTextField **value)
{
    const CGFloat gap = METRICS_SPACE_8;
    const NSUInteger anchor = row.resizing == MousePaneRowKeepsRight ? NSViewMinXMargin : NSViewMaxXMargin;
    CGFloat controlW = row.width - row.labelWidth - gap
        - (row.valueWidth > 0 ? gap + row.valueWidth : 0);

    NSTextField *labelField = MousePaneLabel(label,
        NSMakeRect(row.x, row.y + 1, row.labelWidth, kLabelHeight), NSTextAlignmentRight);
    [labelField setAutoresizingMask:anchor | NSViewMinYMargin];
    [view addSubview:labelField];

    if (value != NULL) {
        *value = MousePaneLabel(@"", NSMakeRect(row.x + row.width - row.valueWidth, row.y + 1,
                                                row.valueWidth, kLabelHeight),
                                NSTextAlignmentLeft);
        [*value setAutoresizingMask:(row.resizing == MousePaneRowKeepsLeft ? NSViewMaxXMargin : NSViewMinXMargin)
                                    | NSViewMinYMargin];
        [view addSubview:*value];
    }
    return NSMakeRect(row.x + row.labelWidth + gap, row.y, controlW, MousePaneRowHeight);
}

static NSUInteger ControlMask(MousePaneRow row)
{
    switch (row.resizing) {
    case MousePaneRowStretches:
        return NSViewWidthSizable | NSViewMinYMargin;
    case MousePaneRowKeepsLeft:
        return NSViewMaxXMargin | NSViewMinYMargin;
    case MousePaneRowKeepsRight:
        break;
    }
    return NSViewMinXMargin | NSViewMinYMargin;
}

NSSlider *MousePaneAddSliderRow(NSView *view, NSString *label, MousePaneRow row,
                                NSTextField **value, id target, SEL action)
{
    NSSlider *slider = [[[NSSlider alloc] initWithFrame:
        AddRowFrame(view, label, row, row.valueWidth > 0 ? value : NULL)] autorelease];
    [slider setContinuous:YES];
    [slider setTarget:target];
    [slider setAction:action];
    [slider setAutoresizingMask:ControlMask(row)];
    [view addSubview:slider];
    return slider;
}

NSPopUpButton *MousePaneAddPopUpRow(NSView *view, NSString *label, MousePaneRow row,
                                    id target, SEL action)
{
    NSPopUpButton *popup = [[[NSPopUpButton alloc] initWithFrame:
        AddRowFrame(view, label, row, NULL) pullsDown:NO] autorelease];
    /* The pane decides which items are usable, not the menu's validation. */
    [popup setAutoenablesItems:NO];
    [popup setTarget:target];
    [popup setAction:action];
    [popup setAutoresizingMask:ControlMask(row)];
    [view addSubview:popup];
    return popup;
}
