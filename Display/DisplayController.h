/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class DisplayView;
@class DisplayLayout;
@class X11DisplayManager;

@interface DisplayController : NSObject
{
    DisplayLayout *layout;          /* as last read from the X server */
    NSString *selectedOutputName;
    DisplayView *displayView;
    NSView *mainView;
    NSBox *settingsBox;
    NSPopUpButton *outputPopup;
    NSPopUpButton *resolutionPopup;
    NSPopUpButton *scalePopup;      /* scale of the selected output */
    NSTextField *statusLabel;
    NSButton *mirrorDisplaysCheckbox;
    X11DisplayManager *x11;
}

- (NSView *)createMainView;
- (void)relayoutWithWidth:(CGFloat)width;
- (void)refreshDisplays:(NSTimer *)timer;
/* Like refreshDisplays:, but asks the hardware for newly connected monitors
 * first; for when the pane is opened. */
- (void)probeDisplays;

- (DisplayLayout *)layout;
- (NSString *)selectedOutputName;
- (void)selectOutput:(NSString *)name;

/* Called by the arrangement view when the user dropped an output. */
- (void)moveOutput:(NSString *)name toViewRect:(NSRect)viewRect;
- (void)setPrimaryOutput:(NSString *)name;

- (void)outputChanged:(id)sender;
- (void)resolutionChanged:(id)sender;
- (void)mirrorDisplaysChanged:(id)sender;
- (void)scaleChanged:(id)sender;

@end
