/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The window and the menu are a pure function of the dictation state:
 * every state maps to one consistent picture, and the record control says
 * "Stop" exactly while the microphone is open.
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "WDictationViewState.h"

static WDViewInputs noInputs(void)
{
    WDViewInputs in;
    memset(&in, 0, sizeof(in));
    in.progress = -1;
    return in;
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    WDViewInputs in = noInputs();
    WDViewState *v;
    int s;

    /* --- the record control tells the truth in every state --- */
    for (s = 0; s < WDStateCount; s++) {
        v = [WDViewState viewStateForState:s inputs:in];
        const char *n = [[WDictationMachine nameOfState:s] UTF8String];
        BOOL rec = (s == WDStateRecording);
        PASS([v recordShowsStop] == rec, "%s: stop square only while recording", n);
        PASS([[v recordTitle] isEqualToString:(rec ? @"Stop" : @"Record")],
             "%s: button title", n);
        PASS([[v recordMenuTitle] isEqualToString:
                 (rec ? @"Stop Recording" : @"Start Recording")],
             "%s: menu title", n);
        PASS([v recordingIndicatorOn] == rec, "%s: indicator only while recording", n);
        /* The control must be usable exactly where the machine reacts to
           the toggle, or the user is left with a button that does nothing
           or a recording they cannot stop. */
        BOOL reacts = ([WDictationMachine targetOfEvent:WDEventUserToggle
                                                inState:s] != s);
        PASS([v recordEnabled] == reacts, "%s: enabled iff toggle does something", n);
        BOOL files = ([WDictationMachine targetOfEvent:WDEventUserTranscribeFile
                                               inState:s] != s);
        PASS([v fileMenuEnabled] == files, "%s: file menu iff it does something", n);
        BOOL models = ([WDictationMachine targetOfEvent:WDEventUserDownloadModel
                                                inState:s] != s);
        PASS([v modelMenuEnabled] == models, "%s: model menu iff it does something", n);
        PASS([[v statusText] length] > 0, "%s: has a status text", n);
        PASS([v downloadBarVisible] == (s == WDStateDownloading),
             "%s: download bar only while downloading", n);
    }

    /* --- status texts --- */
    v = [WDViewState viewStateForState:WDStateReady inputs:in];
    PASS_EQUAL([v statusText], @"Ready", "Ready without detail says Ready");
    PASS(![v progressVisible], "Ready shows no progress");

    in.detail = @"Done (1.2 s)";
    v = [WDViewState viewStateForState:WDStateReady inputs:in];
    PASS_EQUAL([v statusText], @"Done (1.2 s)", "Ready shows the detail");

    in = noInputs();
    in.elapsed = 75.4;
    v = [WDViewState viewStateForState:WDStateRecording inputs:in];
    PASS_EQUAL([v statusText], @"Recording 01:15", "elapsed time while recording");
    PASS([v progressVisible] && [v progressIndeterminate],
         "recording shows an indeterminate bar");

    in.hearsSilence = YES;
    v = [WDViewState viewStateForState:WDStateRecording inputs:in];
    PASS_EQUAL([v statusText],
               @"Recording 01:15 - no speech heard, press Stop when done",
               "silence is only a hint");
    PASS([v recordShowsStop] && [v recordEnabled],
         "silence leaves the stop button usable");

    in = noInputs();
    in.detail = @"The audio input stopped";
    v = [WDViewState viewStateForState:WDStateError inputs:in];
    PASS_EQUAL([v statusText], @"Recording stopped: The audio input stopped",
               "Error says recording stopped and why");
    PASS(![v recordShowsStop] && [v recordEnabled],
         "after an error the user can record again");

    in = noInputs();
    v = [WDViewState viewStateForState:WDStateError inputs:in];
    PASS_EQUAL([v statusText], @"Recording stopped: unknown error",
               "Error without a reason still says it stopped");

    in = noInputs();
    in.progress = 40;
    v = [WDViewState viewStateForState:WDStateTranscribing inputs:in];
    PASS([v progressVisible] && ![v progressIndeterminate] &&
         [v progressValue] == 40.0, "file progress is determinate");
    PASS_EQUAL([v statusText], @"Transcribing... 40%", "file progress text");

    in = noInputs();
    v = [WDViewState viewStateForState:WDStateFinishing inputs:in];
    PASS_EQUAL([v statusText], @"Transcribing recording...", "finishing text");
    PASS([v progressVisible] && [v progressIndeterminate], "finishing spins");

    in = noInputs();
    in.downloadingModel = @"ggml-base.en.bin";
    in.progress = 12;
    v = [WDViewState viewStateForState:WDStateDownloading inputs:in];
    PASS_EQUAL([v statusText], @"Downloading ggml-base.en.bin - 12%",
               "download text");

    in = noInputs();
    in.hasResults = YES;
    v = [WDViewState viewStateForState:WDStateReady inputs:in];
    PASS([v saveEnabled], "results can be saved when idle");
    v = [WDViewState viewStateForState:WDStateRecording inputs:in];
    PASS(![v saveEnabled], "not while the take is still growing");

    [arp release];
    return 0;
}
