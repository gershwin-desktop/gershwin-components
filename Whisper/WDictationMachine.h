/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef WDICTATION_MACHINE_H
#define WDICTATION_MACHINE_H

#import <Foundation/Foundation.h>

/* The one state of Whisper's dictation, so that the record button, the
   menu, the status line and the microphone can never disagree.  The table
   is written down in docs/state-machine.md; Tests/Unit/t_WDictationMachine
   enumerates every pair.

   The rule the table enforces: the microphone opens and closes only on a
   user event.  A system report (the input went away, the capture could not
   start) may end a recording, but only into Error, and nothing but the
   user's toggle ever enters Recording. */

typedef NS_ENUM(NSInteger, WDState) {
    WDStateReady = 0,     // nothing running, microphone closed
    WDStateDownloading,   // a model is being downloaded
    WDStateRecording,     // microphone open, started by the user
    WDStateFinishing,     // stopped by the user, final transcription running
    WDStateTranscribing,  // an audio file is being transcribed
    WDStateError,         // the last job failed; microphone closed
    WDStateCount
};

typedef NS_ENUM(NSInteger, WDEvent) {
    /* user events */
    WDEventUserToggle = 0,       // record button, menu item or its shortcut
    WDEventUserTranscribeFile,   // a file was chosen to transcribe
    WDEventUserDownloadModel,    // a model not on disk was chosen
    /* system events, each tagged with the generation of its job */
    WDEventLaunchDownloadModel,  // launch found the chosen model missing
    WDEventCaptureFailed,        // the microphone or the model did not open
    WDEventDeviceLost,           // the audio input ended without the user
    WDEventSilenceHeard,         // a chunk of the take held no speech
    WDEventSpeechHeard,          // a chunk of the take held speech
    WDEventFinishDone,
    WDEventFinishFailed,
    WDEventFileDone,
    WDEventFileFailed,
    WDEventDownloadDone,         // downloaded and loaded
    WDEventDownloadFailed,
    WDEventCount
};

/* What the owner has to do after a transition; the machine itself touches
   neither the microphone nor a thread, so it can be walked headless. */
typedef NS_OPTIONS(NSUInteger, WDEffect) {
    WDEffectNone                   = 0,
    WDEffectStartCapture           = 1 << 0,
    WDEffectStopCaptureAndFinish   = 1 << 1,
    WDEffectCancelCapture          = 1 << 2,
    WDEffectStartFileTranscription = 1 << 3,
    WDEffectStartDownload          = 1 << 4,
    WDEffectDeliverText            = 1 << 5
};

typedef NS_ENUM(NSInteger, WDOutcome) {
    WDOutcomeTransitioned = 0,  // includes internal transitions to itself
    WDOutcomeIgnored,           // declared ignore in this state
    WDOutcomeStale              // event of an older job generation, dropped
};

@interface WDictationMachine : NSObject
{
    WDState state;
    NSUInteger generation;
    NSString *detail;
    BOOL hearsSilence;
    WDOutcome lastOutcome;
}

- (WDState)state;
/// Bumped whenever a new asynchronous job starts (a take, a file, a
/// download); system events must carry it, older ones are dropped.
- (NSUInteger)generation;
/// Why the machine is where it is ("Done", the error), or nil.
- (NSString *)detail;
/// Informational text for Ready/Error that is not the result of a
/// transition (e.g. the name of an opened file).
- (void)setDetail:(NSString *)text;
/// YES while the latest chunk of the running take held no speech: a hint
/// for the user, never a reason to stop.
- (BOOL)hearsSilence;
- (WDOutcome)lastOutcome;

/// Must only be called on the main thread.  generation is ignored for user
/// events.  detail becomes -detail on a transition (nil clears it).
- (WDEffect)handleEvent:(WDEvent)event
             generation:(NSUInteger)gen
                 detail:(NSString *)text;
- (WDEffect)handleUserEvent:(WDEvent)event;

+ (BOOL)isUserEvent:(WDEvent)event;
+ (BOOL)isDecidedEvent:(WDEvent)event inState:(WDState)s;
+ (BOOL)isIgnoredEvent:(WDEvent)event inState:(WDState)s;
/// The state a pair leads to; s itself for an ignore or internal move.
+ (WDState)targetOfEvent:(WDEvent)event inState:(WDState)s;
+ (WDEffect)effectsOfEvent:(WDEvent)event inState:(WDState)s;
+ (NSString *)ignoreReasonOfEvent:(WDEvent)event inState:(WDState)s;
+ (NSString *)nameOfState:(WDState)s;
+ (NSString *)nameOfEvent:(WDEvent)event;
/// The state x event matrix as Markdown, for docs/state-machine.md.
+ (NSString *)tableDescription;

@end

#endif
