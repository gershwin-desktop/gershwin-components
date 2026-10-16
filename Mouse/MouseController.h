/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "PointerSection.h"

@class MouseBackend;

/* The Mouse pane: one group box whose tabs are the pointer classes this
 * machine has (a desktop with a mouse sees only the mouse, a laptop sees
 * trackpad and whatever else is plugged in), the system-wide double-click
 * speed below it and a status line. */
@interface MouseController : NSObject <PointerSectionDelegate>
{
    NSView *mainView;
    NSBox *devicesBox;
    NSTabView *devicesTabView;
    NSTextField *noDeviceLabel;
    NSSlider *doubleClickSlider;
    NSTextField *doubleClickValue;
    NSTextField *statusLabel;

    MouseBackend *backend;
    /* One per class, in the order their tabs appear. */
    NSArray *sections;
    NSMutableDictionary *tabItems;
    BOOL refreshing;
}

- (NSView *)createMainView;
- (void)relayoutWithWidth:(CGFloat)width;
- (void)refreshFromSystem;

@end
