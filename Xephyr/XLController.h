/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <AppKit/AppKit.h>

/* Window and process handling of the Xephyr launcher.  What is decided
 * before launching lives in XLXephyr. */
@interface XLController : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate>
{
    NSWindow *mainWindow;
    NSPopUpButton *sizePopUp;
    NSTextField *widthField;
    NSTextField *heightField;
    NSPopUpButton *screensPopUp;
    NSTextField *commandField;
    NSTextField *statusLabel;
    NSButton *startStopButton;

    NSTask *xephyrTask;
    NSTask *commandTask;
    NSInteger displayNumber;
    NSString *xephyrLogPath;
    NSString *commandLogPath;
    NSString *commandLine;
    NSTimer *pollTimer;
    NSDate *startedAt;
    BOOL serverIsUp;
    BOOL stopRequested;
}
@end
