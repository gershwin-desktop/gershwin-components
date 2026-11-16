/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef WHISPER_CONTROLLER_H
#define WHISPER_CONTROLLER_H

#import <AppKit/AppKit.h>
#import "WRecordButton.h"
#import "WDictationMachine.h"
#import "WDictationViewState.h"


@interface WhisperController : NSObject <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
{
    // Main window
    NSWindow *mainWindow;

    // File selection
    NSString *currentFilePath;

    // Recording: one button that both starts and stops
    WRecordButton *recordButton;
    NSProgressIndicator *recordSpinner;

    // Model management
    NSString *modelDir;
    NSProgressIndicator *downloadProgress;
    NSArray *availableModels;

    // Settings
    // NSButton *translateCheckbox;
    int currentThreads;

    // Action
    NSProgressIndicator *progressBar;
    NSTextField *statusLabel;

    // Results
    NSTextView *resultTextView;
    NSScrollView *resultScrollView;

    // Export
    NSButton *copyTextButton;
    NSButton *showTimestampsCheckbox;
    BOOL showTimestamps;
    BOOL copyDefaultConsumed;
    NSString *typedText;
    unsigned long targetWindowID;
    NSString *vocabularyPrompt;

    // Whisper state
    void *whisperLib;
    struct whisper_context *whisperCtx;
    // The one owner of what Whisper is doing (docs/state-machine.md)
    WDictationMachine *machine;
    WDViewState *viewState;
    // Events fired while effects run wait here, so each transition and its
    // effects complete before the next one starts.
    NSMutableArray *pendingEvents;
    BOOL dispatching;
    // whisper.cpp allows one whisper_full per context at a time; a serial
    // queue makes that a property of the queue instead of a racy flag.
    NSOperationQueue *whisperQueue;
    NSString *loadedModelName;
    double jobProgress;
    NSMenuItem *recordMenuItem;
    NSMutableArray *segments;

    // Timing
    NSTimeInterval transcriptionStartTime;

    // Recording state
    void *captureHandle;
    // YES while Player is paused because this recording needs the sound
    BOOL playerPausedForRecording;
    NSString *currentLangCode;
    NSTimer *recordTimer;
    NSTimer *streamTimer;
    NSTimeInterval recordStartTime;

    // Vocabulary editor
    NSPanel *vocabPanel;
    NSTextView *vocabTextView;

    // Model download
    BOOL firstRealProgress;
    NSTask *downloadTask;
    NSString *downloadingModel;
    NSMutableData *downloadData;
    NSFileHandle *downloadFH;
}

@property (retain) NSWindow *mainWindow;
@property (retain) NSArray *availableModels;
@property (retain) NSMutableArray *segments;
@property (retain) NSString *currentFilePath;

// UI creation
- (void)createUI;
- (void)createMenu;

// Layout
- (void)layoutSubviews;

// Window delegate
- (void)windowDidResize:(NSNotification *)notification;

// App delegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (void)applicationWillTerminate:(NSNotification *)notification;
- (BOOL)application:(NSApplication *)application openFile:(NSString *)filename;

// Actions
/// The one record button: starts a recording, or stops the one that is
/// running, whichever applies when it is pressed.
- (IBAction)toggleRecording:(id)sender;
/// Gives Player back the pause -pausePlayerForRecording took, if it is
/// still ours to give (never resumes a pause the user took themselves).
- (void)resumePlayerIfPaused;
- (IBAction)openFile:(id)sender;
- (IBAction)modelSelected:(id)sender;
- (IBAction)languageChanged:(id)sender;
- (IBAction)threadSelected:(id)sender;
- (IBAction)saveAsTxt:(id)sender;
- (IBAction)saveAsSrt:(id)sender;
- (IBAction)saveAsVtt:(id)sender;
- (IBAction)copyText:(id)sender;
- (IBAction)timestampsToggled:(id)sender;
- (IBAction)editVocabulary:(id)sender;

// Transcription
- (IBAction)transcribe:(id)sender;

// Model management
- (void)populateModelList;
- (NSString *)modelPathForName:(NSString *)name;
- (void)downloadModelWithName:(NSString *)name;

// Export
- (NSString *)formatTimestamp:(int64_t)t;
- (NSString *)formatTimestampSrt:(int64_t)t;
- (NSString *)formatTimestampVtt:(int64_t)t;
- (void)saveTranscriptionWithFormat:(NSString *)format;

// Audio loading
- (float *)loadAudio:(NSString *)path outSamples:(int *)outNSamples outSampleRate:(int *)outSampleRate;

// State: every change goes through the machine, the UI follows -render
- (void)fireEvent:(WDEvent)event generation:(NSUInteger)gen
           detail:(NSString *)detail;
- (void)fireUserEvent:(WDEvent)event;
- (void)render;

// Display
- (NSString *)displayTextFromSegments;
- (void)rebuildTextView;

// Auto-type
- (NSString *)plainTextFromSegments;
- (void)syncTypedText;
- (void)typeTextToApp:(NSString *)text;
- (void)typeBackspaces:(int)count;

@end
#endif
