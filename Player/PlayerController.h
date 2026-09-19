/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef PlayerController_h
#define PlayerController_h

#import <AppKit/AppKit.h>
#import "ItemFlowView.h"
#import "RadioManager.h"
#import "YTDLPBackend.h"
#import "PreferencesController.h"
#import "PlayerSession.h"
#import "PlayerViews.h"

@class RadioStation;

typedef NS_ENUM(NSInteger, PlayerMode) {
    PlayerModeLocal,
    PlayerModeRadio
};

/**
 * The player window: shows what the PlayerSession (local files and stream
 * URLs) or the RadioManager (Internet radio mode) is doing and forwards the
 * user's commands to them.
 */
@interface PlayerController : NSObject <NSWindowDelegate, ItemFlowViewDataSource,
    ItemFlowViewDelegate, RadioManagerDelegate, YTDLPBackendDelegate,
    PlayerSessionDelegate, PlayerContentViewController>
{
    PlayerWindow *mainWindow;
    PlayerContentView *contentView;

    // Cover art carousel and video
    ItemFlowView *flowView;
    NSView *videoView;
    VideoRenderView *videoRenderView;
    NSProgressIndicator *progressIndicator;

    // Track information
    NSTextField *titleLabel;
    NSTextField *artistLabel;
    NSTextField *albumLabel;
    NSTextField *detailsLabel;

    // Position
    NSTextField *currentTimeLabel;
    NSSlider *timeSlider;
    NSTextField *totalTimeLabel;

    // Transport
    NSButton *previousButton;
    NSButton *playButton;
    NSButton *stopButton;
    NSButton *nextButton;
    NSImage *playImage;
    NSImage *pauseImage;

    // Bottom row
    NSTextField *volumeLabel;
    NSSlider *volumeSlider;
    NSButton *muteCheckbox;

    // Full screen
    BOOL isFullscreen;

    // Local playback
    PlayerSession *session;
    NSMutableDictionary *coverImages;     // playlist item -> NSImage
    NSMutableDictionary *streamTitles;    // stream URL -> title from yt-dlp
    NSTimer *positionTimer;
    NSUInteger pendingFlowIndex;
    BOOL suppressFlowSelection;
    BOOL errorAlertShown;

    // Internet radio
    PlayerMode playerMode;
    NSTextField *searchField;
    NSTextField *statusLabel;
    NSTextField *radioTextLabel;
    RadioStation *pendingRadioStation;
    // The station of the last run, selected (and played, if it played at
    // quit) once the stations are there
    RadioStation *restoredRadioStation;
    BOOL resumeRadioPlayback;

    // Streaming sites
    YTDLPBackend *ytdlpBackend;
    PreferencesController *preferencesController;

    // Quit-time fade-out of running sound
    BOOL quittingAfterFade;
    NSTimer *fadeTimer;
    NSDate *fadeStartDate;
    float fadeStartVolume;
}

@property (nonatomic, readonly) NSWindow *mainWindow;

// Player commands (menu items and buttons)
- (IBAction)openFile:(id)sender;
- (IBAction)openURL:(id)sender;
- (IBAction)openPreferences:(id)sender;
- (IBAction)playPause:(id)sender;
- (IBAction)stop:(id)sender;
- (IBAction)nextTrack:(id)sender;
- (IBAction)previousTrack:(id)sender;
- (IBAction)seekToTime:(id)sender;
- (IBAction)increaseVolume:(id)sender;
- (IBAction)decreaseVolume:(id)sender;
- (IBAction)volumeChanged:(id)sender;
- (IBAction)toggleMute:(id)sender;
- (IBAction)toggleRepeat:(id)sender;
- (IBAction)toggleShuffle:(id)sender;
- (IBAction)toggleFullscreen:(id)sender;
/// Replaces the playlist with these files (folders are searched) and plays.
- (BOOL)openPaths:(NSArray *)paths;

@end

/// Internet radio mode, in PlayerController+Radio.m
@interface PlayerController (Radio)
- (IBAction)toggleRadioMode:(id)sender;
- (void)createRadioViews;
- (void)enterRadioMode;
/// Radio mode as it was left: the last search and station, playing again
/// when `resume` and it played when the app quit.
- (void)enterRadioModeResuming:(BOOL)resume;
- (void)exitRadioMode;
- (void)layoutRadioMode;
- (void)updateRadioControls;
- (void)radioPlayPause;
- (void)radioStop;
- (void)radioNextStation;
- (void)radioPreviousStation;
- (void)radioSelectStationAtIndex:(NSUInteger)index;
- (void)rebuildRadioStationMenu;
- (BOOL)validateRadioMenuItem:(NSMenuItem *)item;
@end

#endif /* PlayerController_h */
