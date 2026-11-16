/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WDictationMachine.h"

typedef enum { WDUndecided = 0, WDTransition, WDIgnore } WDCellKind;

typedef struct {
    WDCellKind kind;
    WDState target;
    WDEffect effects;
    const char *reason;   // why an ignore is right
} WDCell;

static WDCell table[WDStateCount][WDEventCount];

static void row(WDState s, WDEvent e, WDState t, WDEffect fx)
{
    /* A pair defined twice is a mistake in the table, not something to
       resolve by order, so fail loudly at start-up. */
    if (table[s][e].kind != WDUndecided)
        [NSException raise:NSInternalInconsistencyException
                    format:@"WDictationMachine: pair %d x %d defined twice",
                           (int)s, (int)e];
    table[s][e].kind = WDTransition;
    table[s][e].target = t;
    table[s][e].effects = fx;
}

static void ignore(WDState s, WDEvent e, const char *reason)
{
    if (table[s][e].kind != WDUndecided)
        [NSException raise:NSInternalInconsistencyException
                    format:@"WDictationMachine: pair %d x %d defined twice",
                           (int)s, (int)e];
    table[s][e].kind = WDIgnore;
    table[s][e].target = s;
    table[s][e].reason = reason;
}

static void ignoreMany(WDState s, const WDEvent *events, int n,
                       const char *reason)
{
    int i;
    for (i = 0; i < n; i++) ignore(s, events[i], reason);
}

#define COUNT(a) ((int)(sizeof(a) / sizeof((a)[0])))

static void buildTable(void)
{
    static const WDEvent captureReports[] = {
        WDEventCaptureFailed, WDEventDeviceLost,
        WDEventSilenceHeard, WDEventSpeechHeard };
    static const WDEvent finishReports[] = {
        WDEventFinishDone, WDEventFinishFailed };
    static const WDEvent fileReports[] = {
        WDEventFileDone, WDEventFileFailed };
    static const WDEvent downloadReports[] = {
        WDEventDownloadDone, WDEventDownloadFailed };
    static const WDEvent downloadRequests[] = {
        WDEventUserDownloadModel, WDEventLaunchDownloadModel };
    WDState idle[2] = { WDStateReady, WDStateError };
    int i;

    /* Ready and Error behave alike; Error only keeps the reason on show. */
    for (i = 0; i < 2; i++) {
        WDState s = idle[i];
        row(s, WDEventUserToggle, WDStateRecording, WDEffectStartCapture);
        row(s, WDEventUserTranscribeFile, WDStateTranscribing,
            WDEffectStartFileTranscription);
        row(s, WDEventUserDownloadModel, WDStateDownloading,
            WDEffectStartDownload);
        row(s, WDEventLaunchDownloadModel, WDStateDownloading,
            WDEffectStartDownload);
        ignoreMany(s, captureReports, COUNT(captureReports),
                   "no capture is running");
        ignoreMany(s, finishReports, COUNT(finishReports),
                   "no take is being finished");
        ignoreMany(s, fileReports, COUNT(fileReports),
                   "no file is being transcribed");
        ignoreMany(s, downloadReports, COUNT(downloadReports),
                   "no download is running");
    }

    /* Downloading: without a model there is nothing to record with. */
    ignore(WDStateDownloading, WDEventUserToggle,
           "no model yet; the record control is disabled");
    ignore(WDStateDownloading, WDEventUserTranscribeFile,
           "no model yet; the menu item is disabled");
    ignoreMany(WDStateDownloading, downloadRequests, COUNT(downloadRequests),
               "a download is already running; the Model menu is disabled");
    ignoreMany(WDStateDownloading, captureReports, COUNT(captureReports),
               "no capture is running");
    ignoreMany(WDStateDownloading, finishReports, COUNT(finishReports),
               "no take is being finished");
    ignoreMany(WDStateDownloading, fileReports, COUNT(fileReports),
               "no file is being transcribed");
    row(WDStateDownloading, WDEventDownloadDone, WDStateReady, WDEffectNone);
    row(WDStateDownloading, WDEventDownloadFailed, WDStateError, WDEffectNone);

    /* Recording: only the user's toggle ends it normally; a failed start
       or a lost input ends it into Error, which says so.  Silence is a
       hint and never stops it. */
    row(WDStateRecording, WDEventUserToggle, WDStateFinishing,
        WDEffectStopCaptureAndFinish);
    ignore(WDStateRecording, WDEventUserTranscribeFile,
           "recording; the menu item is disabled");
    ignoreMany(WDStateRecording, downloadRequests, COUNT(downloadRequests),
               "recording; the Model menu is disabled");
    row(WDStateRecording, WDEventCaptureFailed, WDStateError,
        WDEffectCancelCapture);
    row(WDStateRecording, WDEventDeviceLost, WDStateError,
        WDEffectCancelCapture);
    row(WDStateRecording, WDEventSilenceHeard, WDStateRecording, WDEffectNone);
    row(WDStateRecording, WDEventSpeechHeard, WDStateRecording, WDEffectNone);
    ignoreMany(WDStateRecording, finishReports, COUNT(finishReports),
               "the take is not finished yet");
    ignoreMany(WDStateRecording, fileReports, COUNT(fileReports),
               "no file is being transcribed");
    ignoreMany(WDStateRecording, downloadReports, COUNT(downloadReports),
               "no download is running");

    /* Finishing: the microphone is already closed. */
    ignore(WDStateFinishing, WDEventUserToggle,
           "the take is still being transcribed; the record control is "
           "disabled");
    ignore(WDStateFinishing, WDEventUserTranscribeFile,
           "busy; the menu item is disabled");
    ignoreMany(WDStateFinishing, downloadRequests, COUNT(downloadRequests),
               "busy; the Model menu is disabled");
    ignoreMany(WDStateFinishing, captureReports, COUNT(captureReports),
               "the capture is already closed");
    row(WDStateFinishing, WDEventFinishDone, WDStateReady,
        WDEffectDeliverText);
    row(WDStateFinishing, WDEventFinishFailed, WDStateError, WDEffectNone);
    ignoreMany(WDStateFinishing, fileReports, COUNT(fileReports),
               "no file is being transcribed");
    ignoreMany(WDStateFinishing, downloadReports, COUNT(downloadReports),
               "no download is running");

    /* Transcribing a file. */
    ignore(WDStateTranscribing, WDEventUserToggle,
           "a file is being transcribed; the record control is disabled");
    ignore(WDStateTranscribing, WDEventUserTranscribeFile,
           "busy; the menu item is disabled");
    ignoreMany(WDStateTranscribing, downloadRequests, COUNT(downloadRequests),
               "busy; the Model menu is disabled");
    ignoreMany(WDStateTranscribing, captureReports, COUNT(captureReports),
               "no capture is running");
    ignoreMany(WDStateTranscribing, finishReports, COUNT(finishReports),
               "no take is being finished");
    row(WDStateTranscribing, WDEventFileDone, WDStateReady,
        WDEffectDeliverText);
    row(WDStateTranscribing, WDEventFileFailed, WDStateError, WDEffectNone);
    ignoreMany(WDStateTranscribing, downloadReports, COUNT(downloadReports),
               "no download is running");
}

static NSString *stateNames[WDStateCount] = {
    @"Ready", @"Downloading", @"Recording", @"Finishing", @"Transcribing",
    @"Error"
};

static NSString *eventNames[WDEventCount] = {
    @"UserToggle", @"UserTranscribeFile", @"UserDownloadModel",
    @"LaunchDownloadModel", @"CaptureFailed", @"DeviceLost",
    @"SilenceHeard", @"SpeechHeard", @"FinishDone", @"FinishFailed",
    @"FileDone", @"FileFailed", @"DownloadDone", @"DownloadFailed"
};

static BOOL validPair(WDEvent e, WDState s)
{
    return s >= 0 && s < WDStateCount && e >= 0 && e < WDEventCount;
}

@implementation WDictationMachine

+ (void)initialize
{
    if (self == [WDictationMachine class])
        buildTable();
}

- (id)init
{
    if ((self = [super init])) {
        state = WDStateReady;
        lastOutcome = WDOutcomeIgnored;
    }
    return self;
}

- (void)dealloc
{
    [detail release];
    [super dealloc];
}

- (WDState)state { return state; }
- (NSUInteger)generation { return generation; }
- (NSString *)detail { return detail; }
- (BOOL)hearsSilence { return hearsSilence; }
- (WDOutcome)lastOutcome { return lastOutcome; }

- (void)setDetail:(NSString *)text
{
    if (text == detail) return;
    [detail release];
    detail = [text copy];
}

- (WDEffect)handleUserEvent:(WDEvent)event
{
    return [self handleEvent:event generation:generation detail:nil];
}

- (WDEffect)handleEvent:(WDEvent)event
             generation:(NSUInteger)gen
                 detail:(NSString *)text
{
    /* Every state change happens on the main thread, so a worker's report
       can never interleave with the user's click. */
    NSAssert([NSThread isMainThread],
             @"WDictationMachine: events must arrive on the main thread");
    if (!validPair(event, state))
        [NSException raise:NSInvalidArgumentException
                    format:@"WDictationMachine: bad event %d", (int)event];

    if (![WDictationMachine isUserEvent:event] && gen != generation) {
        lastOutcome = WDOutcomeStale;
        return WDEffectNone;
    }

    WDCell c = table[state][event];
    if (c.kind != WDTransition) {
        lastOutcome = WDOutcomeIgnored;
        return WDEffectNone;
    }

    WDState from = state;
    state = c.target;
    lastOutcome = WDOutcomeTransitioned;

    if (from == state) {
        /* Internal: only data of the state changes. */
        if (event == WDEventSilenceHeard) hearsSilence = YES;
        if (event == WDEventSpeechHeard) hearsSilence = NO;
        return c.effects;
    }

    /* A new job owns a new generation, so every report still in flight
       from the previous one is recognised as stale. */
    if (state == WDStateRecording || state == WDStateTranscribing ||
        state == WDStateDownloading)
        generation++;
    hearsSilence = NO;
    [self setDetail:text];
    return c.effects;
}

+ (BOOL)isUserEvent:(WDEvent)event
{
    return event == WDEventUserToggle || event == WDEventUserTranscribeFile ||
           event == WDEventUserDownloadModel;
}

+ (BOOL)isDecidedEvent:(WDEvent)event inState:(WDState)s
{
    return validPair(event, s) && table[s][event].kind != WDUndecided;
}

+ (BOOL)isIgnoredEvent:(WDEvent)event inState:(WDState)s
{
    return validPair(event, s) && table[s][event].kind == WDIgnore;
}

+ (WDState)targetOfEvent:(WDEvent)event inState:(WDState)s
{
    if (!validPair(event, s) || table[s][event].kind != WDTransition)
        return s;
    return table[s][event].target;
}

+ (WDEffect)effectsOfEvent:(WDEvent)event inState:(WDState)s
{
    if (!validPair(event, s)) return WDEffectNone;
    return table[s][event].effects;
}

+ (NSString *)ignoreReasonOfEvent:(WDEvent)event inState:(WDState)s
{
    if (![self isIgnoredEvent:event inState:s]) return nil;
    return [NSString stringWithUTF8String:table[s][event].reason];
}

+ (NSString *)nameOfState:(WDState)s
{
    return (s >= 0 && s < WDStateCount) ? stateNames[s] : @"?";
}

+ (NSString *)nameOfEvent:(WDEvent)event
{
    return (event >= 0 && event < WDEventCount) ? eventNames[event] : @"?";
}

static NSString *effectNames(WDEffect fx)
{
    NSMutableArray *a = [NSMutableArray array];
    if (fx & WDEffectStartCapture) [a addObject:@"start capture"];
    if (fx & WDEffectStopCaptureAndFinish) [a addObject:@"stop and finish"];
    if (fx & WDEffectCancelCapture) [a addObject:@"cancel capture"];
    if (fx & WDEffectStartFileTranscription) [a addObject:@"transcribe file"];
    if (fx & WDEffectStartDownload) [a addObject:@"download"];
    if (fx & WDEffectDeliverText) [a addObject:@"deliver text"];
    return [a componentsJoinedByString:@", "];
}

+ (NSString *)tableDescription
{
    NSMutableString *t = [NSMutableString string];
    int s, e;

    [t appendString:@"| State \\ Event |"];
    for (e = 0; e < WDEventCount; e++)
        [t appendFormat:@" %@ |", eventNames[e]];
    [t appendString:@"\n|---|"];
    for (e = 0; e < WDEventCount; e++)
        [t appendString:@"---|"];
    [t appendString:@"\n"];
    for (s = 0; s < WDStateCount; s++) {
        [t appendFormat:@"| %@ |", stateNames[s]];
        for (e = 0; e < WDEventCount; e++) {
            WDCell c = table[s][e];
            if (c.kind == WDTransition) {
                NSString *fx = effectNames(c.effects);
                [t appendFormat:@" %@%@ |", stateNames[c.target],
                    [fx length] ? [NSString stringWithFormat:@" (%@)", fx]
                                : @""];
            } else if (c.kind == WDIgnore) {
                [t appendString:@" - |"];
            } else {
                [t appendString:@" ?? |"];
            }
        }
        [t appendString:@"\n"];
    }
    return t;
}

@end
