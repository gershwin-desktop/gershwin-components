/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class PrinterInfo;

/* The options of one printer: its name, location and sharing, the settings
 * its driver offers (paper size, quality, installed accessories) and the
 * supplies it reports.  The owner keeps this object for as long as the window
 * is to stay: a window nothing retains is freed with the next autorelease
 * pool. */
@interface PrinterOptionsPanel : NSObject <NSWindowDelegate>
{
    PrinterInfo *printer;
    NSString *privilegeHint;
    id target;
    SEL changedAction;

    NSWindow *window;
    NSTextField *descriptionField;
    NSTextField *locationField;
    NSButton *sharedCheckbox;
    NSButton *acceptingCheckbox;
    NSButton *pausedCheckbox;

    /* The driver's settings: one entry per pop-up, keyword -> pop-up. */
    NSMutableArray *optionPopups;
    NSMutableDictionary *initialChoices;
}

/* privilegeHint says how to become allowed to change printers, for the message
 * shown when the user is not.  changedAction is sent to target after a change
 * was saved. */
- (id)initWithPrinter:(PrinterInfo *)aPrinter
        privilegeHint:(NSString *)hint
               target:(id)aTarget
        changedAction:(SEL)action;

- (void)show;
- (void)close;

@end
