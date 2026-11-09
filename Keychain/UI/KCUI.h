/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "AppearanceMetrics.h"

/* Label column width of the forms in the panels. */
extern const CGFloat KCFormLabelWidth;

/* Control factories shared by the windows and panels, so every one of them
 * gets the same fonts, heights and bezels. Frames are set by the caller's
 * layout code. */
NSTextField *KCMakeLabel(NSString *text);
NSTextField *KCMakeWrappingLabel(NSString *text);
NSTextField *KCMakeField(BOOL secure);
NSButton *KCMakeButton(NSString *title, id target, SEL action);
NSButton *KCMakeCheckbox(NSString *title, id target, SEL action);

/* Width for a push button: its title plus padding, never below the
 * HIG minimum. */
CGFloat KCButtonWidth(NSButton *button);

/* Places buttons right-aligned in a row, rightmost first in the array
 * order (default button first), and returns the leftmost x used. */
CGFloat KCLayoutButtonRow(NSArray *buttons, CGFloat right, CGFloat y);

/* Lays out form rows top-down starting below top: a right-aligned label
 * and a control that fills the rest of the width. rows holds pairs of
 * (label text, control). Returns the y of the lowest row's bottom edge. */
CGFloat KCLayoutFormRows(NSView *content, NSArray *rows, CGFloat top, CGFloat width);

/* Height KCLayoutFormRows uses for n rows. */
CGFloat KCFormHeight(NSUInteger rows);

/* Height a wrapping label needs at a given width. */
CGFloat KCWrappedHeight(NSTextField *label, CGFloat width);
