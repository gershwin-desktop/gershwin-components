/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WDictationViewState.h"

@implementation WDViewState

+ (WDViewState *)viewStateForState:(WDState)s inputs:(WDViewInputs)in
{
    WDViewState *v = [[[WDViewState alloc] init] autorelease];
    BOOL recording = (s == WDStateRecording);
    BOOL idle = (s == WDStateReady || s == WDStateError);

    v->recordShowsStop = recording;
    v->recordTitle = [(recording ? @"Stop" : @"Record") retain];
    v->recordMenuTitle = [(recording ? @"Stop Recording"
                                     : @"Start Recording") retain];
    /* Usable exactly where a press does something: start when idle, stop
       while recording.  A disabled stop button would trap the user in a
       recording, an enabled one in Finishing would do nothing. */
    v->recordEnabled = idle || recording;
    v->recordingIndicatorOn = recording;
    v->fileMenuEnabled = idle;
    v->modelMenuEnabled = idle;
    /* The text of a running take or file still changes under the user. */
    v->saveEnabled = idle && in.hasResults;

    NSString *status = nil;
    switch (s) {
    case WDStateReady:
        status = [in.detail length] ? in.detail : @"Ready";
        break;
    case WDStateError:
        status = [NSString stringWithFormat:@"Recording stopped: %@",
                  [in.detail length] ? in.detail : @"unknown error"];
        break;
    case WDStateRecording: {
        int sec = (int)in.elapsed;
        status = [NSString stringWithFormat:@"Recording %02d:%02d",
                  sec / 60, sec % 60];
        if (in.hearsSilence)
            status = [status stringByAppendingString:
                @" - no speech heard, press Stop when done"];
        v->progressVisible = YES;
        v->progressIndeterminate = YES;
        break;
    }
    case WDStateFinishing:
        status = @"Transcribing recording...";
        v->progressVisible = YES;
        v->progressIndeterminate = YES;
        break;
    case WDStateTranscribing:
        v->progressVisible = YES;
        if (in.progress < 0) {
            status = @"Transcribing...";
            v->progressIndeterminate = YES;
        } else {
            status = [NSString stringWithFormat:@"Transcribing... %.0f%%",
                      in.progress];
            v->progressValue = in.progress;
        }
        break;
    case WDStateDownloading:
        v->progressVisible = YES;
        v->downloadBarVisible = YES;
        if (in.progress < 0) {
            status = [NSString stringWithFormat:@"Downloading %@",
                      in.downloadingModel];
            v->progressIndeterminate = YES;
        } else {
            status = [NSString stringWithFormat:@"Downloading %@ - %.0f%%",
                      in.downloadingModel, in.progress];
            v->progressValue = in.progress;
        }
        break;
    default:
        [NSException raise:NSInvalidArgumentException
                    format:@"WDViewState: unknown state %d", (int)s];
    }
    v->statusText = [status copy];
    return v;
}

- (void)dealloc
{
    [recordTitle release];
    [recordMenuTitle release];
    [statusText release];
    [super dealloc];
}

- (NSString *)recordTitle { return recordTitle; }
- (BOOL)recordShowsStop { return recordShowsStop; }
- (BOOL)recordEnabled { return recordEnabled; }
- (NSString *)recordMenuTitle { return recordMenuTitle; }
- (BOOL)recordingIndicatorOn { return recordingIndicatorOn; }
- (BOOL)progressVisible { return progressVisible; }
- (BOOL)downloadBarVisible { return downloadBarVisible; }
- (BOOL)progressIndeterminate { return progressIndeterminate; }
- (double)progressValue { return progressValue; }
- (NSString *)statusText { return statusText; }
- (BOOL)fileMenuEnabled { return fileMenuEnabled; }
- (BOOL)modelMenuEnabled { return modelMenuEnabled; }
- (BOOL)saveEnabled { return saveEnabled; }

@end
