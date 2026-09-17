/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ScreenshotCommandLine_h
#define ScreenshotCommandLine_h

#import <Foundation/Foundation.h>
#import "ScreenshotCapture.h"

@interface ScreenshotCommandLine : NSObject
{
    ScreenshotMode mode;
    int delay;
    NSString *outputPath;
    BOOL showHelp;
    BOOL requested;
    NSString *error;
}

/* Parses the process arguments; GNUstep defaults arguments such as
 * "-NSUseRunningCopy NO" are skipped. */
- (id)initWithArguments:(NSArray *)arguments;

/* Whether any screenshot option was given; otherwise the window opens. */
- (BOOL)isRequested;

/* Runs the capture and returns the process exit status. */
- (int)run;

@end

#endif /* ScreenshotCommandLine_h */
