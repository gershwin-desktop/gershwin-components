/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef WDICTATION_VIEW_STATE_H
#define WDICTATION_VIEW_STATE_H

#import <Foundation/Foundation.h>
#import "WDictationMachine.h"

/* Facts the view needs besides the state; none of them decides anything. */
typedef struct {
    NSTimeInterval elapsed;      // seconds the take has been running
    double progress;             // 0..100, or < 0 when not known yet
    BOOL hearsSilence;
    BOOL hasResults;             // there is text to copy or save
    NSString *detail;            // the machine's -detail
    NSString *downloadingModel;
} WDViewInputs;

/* Everything the window and the menu show, as a pure function of the state
   and the inputs, so the UI is computed in one place and can be tested
   without AppKit. */
@interface WDViewState : NSObject
{
    NSString *recordTitle;
    BOOL recordShowsStop;
    BOOL recordEnabled;
    NSString *recordMenuTitle;
    BOOL recordingIndicatorOn;
    BOOL progressVisible;
    BOOL downloadBarVisible;
    BOOL progressIndeterminate;
    double progressValue;
    NSString *statusText;
    BOOL fileMenuEnabled;
    BOOL modelMenuEnabled;
    BOOL saveEnabled;
}

+ (WDViewState *)viewStateForState:(WDState)s inputs:(WDViewInputs)inputs;

- (NSString *)recordTitle;
- (BOOL)recordShowsStop;
- (BOOL)recordEnabled;
- (NSString *)recordMenuTitle;
- (BOOL)recordingIndicatorOn;
- (BOOL)progressVisible;
/// The separate bar of a model download.
- (BOOL)downloadBarVisible;
- (BOOL)progressIndeterminate;
- (double)progressValue;
- (NSString *)statusText;
- (BOOL)fileMenuEnabled;
- (BOOL)modelMenuEnabled;
- (BOOL)saveEnabled;

@end

#endif
