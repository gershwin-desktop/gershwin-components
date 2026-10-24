/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Headless coverage of Whisper's dictation machine: every state x event
 * pair is decided, and the user's rule holds - only the user's toggle ever
 * enters or leaves Recording, except a failure or a lost input, which may
 * only end it into Error.
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "WDictationMachine.h"

static NSString * const kInputLost = @"The audio input stopped";

/* Drive a fresh machine into s along the user's normal path; returns it
   autoreleased. */
static WDictationMachine *machineIn(WDState s)
{
    WDictationMachine *m = [[[WDictationMachine alloc] init] autorelease];
    switch (s) {
    case WDStateReady:
        break;
    case WDStateDownloading:
        [m handleUserEvent:WDEventUserDownloadModel];
        break;
    case WDStateRecording:
        [m handleUserEvent:WDEventUserToggle];
        break;
    case WDStateFinishing:
        [m handleUserEvent:WDEventUserToggle];
        [m handleUserEvent:WDEventUserToggle];
        break;
    case WDStateTranscribing:
        [m handleUserEvent:WDEventUserTranscribeFile];
        break;
    case WDStateError:
        [m handleUserEvent:WDEventUserToggle];
        [m handleEvent:WDEventDeviceLost generation:[m generation]
                detail:kInputLost];
        break;
    default:
        break;
    }
    return m;
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    int s, e;

    /* --- the table is complete --- */
    {
        int undecided = 0;
        for (s = 0; s < WDStateCount; s++)
            for (e = 0; e < WDEventCount; e++)
                if (![WDictationMachine isDecidedEvent:e inState:s]) {
                    undecided++;
                    NSLog(@"undecided: %@ x %@",
                          [WDictationMachine nameOfState:s],
                          [WDictationMachine nameOfEvent:e]);
                }
        PASS(undecided == 0, "every state x event pair is decided");

        int unexplained = 0;
        for (s = 0; s < WDStateCount; s++)
            for (e = 0; e < WDEventCount; e++)
                if ([WDictationMachine isIgnoredEvent:e inState:s] &&
                    [[WDictationMachine ignoreReasonOfEvent:e inState:s]
                        length] == 0)
                    unexplained++;
        PASS(unexplained == 0, "every ignore carries a reason");
    }

    /* --- user rule: nothing but the user enters Recording --- */
    {
        int intoRecording = 0, userIntoRecording = 0;
        for (s = 0; s < WDStateCount; s++) {
            if (s == WDStateRecording) continue;
            for (e = 0; e < WDEventCount; e++) {
                if ([WDictationMachine targetOfEvent:e inState:s]
                        != WDStateRecording)
                    continue;
                if ([WDictationMachine isUserEvent:e])
                    userIntoRecording++;
                else
                    intoRecording++;
            }
        }
        PASS(intoRecording == 0, "no system event leads into Recording");
        PASS(userIntoRecording == 2,
             "the user's toggle enters Recording from Ready and Error only");
        PASS([WDictationMachine targetOfEvent:WDEventUserToggle
                                      inState:WDStateReady] == WDStateRecording,
             "Ready + UserToggle -> Recording");
        PASS([WDictationMachine targetOfEvent:WDEventUserToggle
                                      inState:WDStateError] == WDStateRecording,
             "Error + UserToggle -> Recording");

        int startsCapture = 0;
        for (s = 0; s < WDStateCount; s++)
            for (e = 0; e < WDEventCount; e++)
                if (([WDictationMachine effectsOfEvent:e inState:s]
                        & WDEffectStartCapture) &&
                    !(e == WDEventUserToggle &&
                      (s == WDStateReady || s == WDStateError)))
                    startsCapture++;
        PASS(startsCapture == 0,
             "only the user's toggle opens the microphone");
    }

    /* --- user rule: nothing but the user (or a failure) leaves Recording --- */
    {
        int badExit = 0, failureExits = 0;
        for (e = 0; e < WDEventCount; e++) {
            WDState t = [WDictationMachine targetOfEvent:e
                                                 inState:WDStateRecording];
            if (t == WDStateRecording) continue;
            if ([WDictationMachine isUserEvent:e]) {
                if (e != WDEventUserToggle || t != WDStateFinishing)
                    badExit++;
                continue;
            }
            if ((e == WDEventDeviceLost || e == WDEventCaptureFailed) &&
                (t == WDStateError || t == WDStateReady))
                failureExits++;
            else
                badExit++;
        }
        PASS(badExit == 0, "no other event leaves Recording");
        PASS(failureExits == 2,
             "a lost input or a failed start ends Recording into Error");
        PASS([WDictationMachine targetOfEvent:WDEventSilenceHeard
                                      inState:WDStateRecording]
                 == WDStateRecording,
             "silence keeps recording");
        PASS([WDictationMachine targetOfEvent:WDEventSpeechHeard
                                      inState:WDStateRecording]
                 == WDStateRecording,
             "speech keeps recording");

        int closes = 0;
        for (s = 0; s < WDStateCount; s++)
            for (e = 0; e < WDEventCount; e++) {
                WDEffect fx = [WDictationMachine effectsOfEvent:e inState:s];
                if (!(fx & (WDEffectStopCaptureAndFinish |
                            WDEffectCancelCapture)))
                    continue;
                if (s != WDStateRecording) closes++;
                else if ((fx & WDEffectStopCaptureAndFinish) &&
                         e != WDEventUserToggle) closes++;
                else if ((fx & WDEffectCancelCapture) &&
                         e != WDEventDeviceLost && e != WDEventCaptureFailed)
                    closes++;
            }
        PASS(closes == 0, "the microphone closes only on the toggle, "
             "a lost input or a failed start");
    }

    /* --- the rows --- */
    {
        PASS([WDictationMachine targetOfEvent:WDEventUserToggle
                                      inState:WDStateRecording]
                 == WDStateFinishing, "Recording + UserToggle -> Finishing");
        PASS([WDictationMachine effectsOfEvent:WDEventUserToggle
                                       inState:WDStateRecording]
                 == WDEffectStopCaptureAndFinish, "stop closes and finishes");
        PASS([WDictationMachine targetOfEvent:WDEventUserToggle
                                      inState:WDStateFinishing]
                 == WDStateFinishing, "toggle while finishing is ignored");
        PASS([WDictationMachine targetOfEvent:WDEventDeviceLost
                                      inState:WDStateRecording]
                 == WDStateError, "Recording + DeviceLost -> Error");
        PASS([WDictationMachine effectsOfEvent:WDEventDeviceLost
                                       inState:WDStateRecording]
                 == WDEffectCancelCapture, "a lost input cancels the capture");
        PASS([WDictationMachine targetOfEvent:WDEventCaptureFailed
                                      inState:WDStateRecording]
                 == WDStateError, "Recording + CaptureFailed -> Error");
        PASS([WDictationMachine targetOfEvent:WDEventFinishDone
                                      inState:WDStateFinishing]
                 == WDStateReady, "Finishing + FinishDone -> Ready");
        PASS([WDictationMachine effectsOfEvent:WDEventFinishDone
                                       inState:WDStateFinishing]
                 == WDEffectDeliverText, "the finished take is delivered");
        PASS([WDictationMachine targetOfEvent:WDEventFinishFailed
                                      inState:WDStateFinishing]
                 == WDStateError, "Finishing + FinishFailed -> Error");
        PASS([WDictationMachine targetOfEvent:WDEventUserTranscribeFile
                                      inState:WDStateReady]
                 == WDStateTranscribing, "Ready + file -> Transcribing");
        PASS([WDictationMachine targetOfEvent:WDEventFileDone
                                      inState:WDStateTranscribing]
                 == WDStateReady, "Transcribing + FileDone -> Ready");
        PASS([WDictationMachine targetOfEvent:WDEventFileFailed
                                      inState:WDStateTranscribing]
                 == WDStateError, "Transcribing + FileFailed -> Error");
        PASS([WDictationMachine targetOfEvent:WDEventLaunchDownloadModel
                                      inState:WDStateReady]
                 == WDStateDownloading, "launch download -> Downloading");
        PASS([WDictationMachine targetOfEvent:WDEventUserDownloadModel
                                      inState:WDStateRecording]
                 == WDStateRecording, "no download while recording");
        PASS([WDictationMachine targetOfEvent:WDEventDownloadDone
                                      inState:WDStateDownloading]
                 == WDStateReady, "Downloading + DownloadDone -> Ready");
        PASS([WDictationMachine targetOfEvent:WDEventDownloadFailed
                                      inState:WDStateDownloading]
                 == WDStateError, "Downloading + DownloadFailed -> Error");
        PASS([WDictationMachine targetOfEvent:WDEventUserToggle
                                      inState:WDStateDownloading]
                 == WDStateDownloading, "no recording without a model");
        PASS([WDictationMachine targetOfEvent:WDEventUserToggle
                                      inState:WDStateTranscribing]
                 == WDStateTranscribing, "no recording while transcribing");
    }

    /* --- walking real instances: every system event, every state --- */
    {
        int entered = 0, left = 0;
        for (s = 0; s < WDStateCount; s++)
            for (e = 0; e < WDEventCount; e++) {
                if ([WDictationMachine isUserEvent:e]) continue;
                WDictationMachine *m = machineIn(s);
                PASS([m state] == s, "reached %s",
                     [[WDictationMachine nameOfState:s] UTF8String]);
                [m handleEvent:e generation:[m generation] detail:nil];
                if (s != WDStateRecording && [m state] == WDStateRecording)
                    entered++;
                if (s == WDStateRecording && [m state] != WDStateRecording &&
                    [m state] != WDStateError)
                    left++;
            }
        PASS(entered == 0, "no system event starts a recording, live");
        PASS(left == 0, "system events end a recording only into Error, live");
    }

    /* --- generations: late reports of an older job change nothing --- */
    {
        WDictationMachine *m = machineIn(WDStateRecording);
        NSUInteger take1 = [m generation];
        [m handleUserEvent:WDEventUserToggle];
        [m handleEvent:WDEventFinishDone generation:take1 detail:@"Done"];
        PASS([m state] == WDStateReady, "take 1 finished");
        [m handleUserEvent:WDEventUserToggle];
        PASS([m state] == WDStateRecording && [m generation] != take1,
             "take 2 has its own generation");
        WDEffect fx = [m handleEvent:WDEventDeviceLost generation:take1
                              detail:kInputLost];
        PASS([m state] == WDStateRecording && fx == WDEffectNone &&
             [m lastOutcome] == WDOutcomeStale,
             "a late DeviceLost of take 1 does not stop take 2");
        [m handleEvent:WDEventFinishDone generation:take1 detail:nil];
        PASS([m state] == WDStateRecording &&
             [m lastOutcome] == WDOutcomeStale,
             "a late FinishDone of take 1 does not stop take 2");
        [m handleEvent:WDEventDeviceLost generation:[m generation]
                detail:kInputLost];
        PASS([m state] == WDStateError &&
             [[m detail] isEqualToString:kInputLost],
             "the current take's DeviceLost shows why it stopped");
    }

    /* --- silence is a hint, never a stop --- */
    {
        WDictationMachine *m = machineIn(WDStateRecording);
        int i;
        for (i = 0; i < 100; i++)
            [m handleEvent:WDEventSilenceHeard generation:[m generation]
                    detail:nil];
        PASS([m state] == WDStateRecording && [m hearsSilence],
             "100 silent chunks keep recording and show the hint");
        [m handleEvent:WDEventSpeechHeard generation:[m generation] detail:nil];
        PASS([m state] == WDStateRecording && ![m hearsSilence],
             "speech clears the hint");
        [m handleEvent:WDEventSilenceHeard generation:[m generation] detail:nil];
        [m handleUserEvent:WDEventUserToggle];
        [m handleUserEvent:WDEventUserToggle];
        PASS(![m hearsSilence], "a new take starts without the hint");
    }

    /* --- ignored pairs report it and change nothing --- */
    {
        WDictationMachine *m = machineIn(WDStateFinishing);
        NSUInteger gen = [m generation];
        WDEffect fx = [m handleUserEvent:WDEventUserToggle];
        PASS([m state] == WDStateFinishing && fx == WDEffectNone &&
             [m lastOutcome] == WDOutcomeIgnored && [m generation] == gen,
             "a second press while finishing is ignored, not a new take");
    }

    /* --- the document can be printed from the table --- */
    {
        NSString *t = [WDictationMachine tableDescription];
        /* PRINT_TABLE=1 ./obj/t_WDictationMachine regenerates the matrix
           in docs/state-machine.md. */
        if (getenv("PRINT_TABLE"))
            printf("%s", [t UTF8String]);
        PASS([t rangeOfString:@"| Recording |"].location != NSNotFound &&
             [t rangeOfString:@"UserToggle"].location != NSNotFound,
             "tableDescription prints the matrix");
    }

    [arp release];
    return 0;
}
