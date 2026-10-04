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
#import "PlayerMediaRemote.h"

#import "PodcastManager.h"

@class RadioStation;
@class Podcast;
@class PodcastEpisode;

typedef NS_ENUM(NSInteger, PlayerMode) {
    PlayerModeLocal,
    PlayerModeRadio,
    PlayerModePodcast
};

/**
 * The player window: shows what the PlayerSession (local files and stream
 * URLs) or the RadioManager (Internet radio mode) is doing and forwards the
 * user's commands to them.
 */
@interface PlayerController : NSObject <NSWindowDelegate, ItemFlowViewDataSource,
    ItemFlowViewDelegate, RadioManagerDelegate, YTDLPBackendDelegate,
    PlayerSessionDelegate, PlayerContentViewController, PlayerMediaRemoteTarget,
    PodcastManagerDelegate, NSTableViewDataSource, NSTableViewDelegate>
{
    PlayerWindow *mainWindow;
    PlayerContentView *contentView;

    // Cover art carousel and video
    ItemFlowView *flowView;
    // The toolbar-like gradient strip behind Radio/Podcast's search row,
    // above the carousel; hidden in Local mode, which has no such row
    PlayerBarView *topBarView;
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

    // Podcasts: search/subscriptions carousel (shares flowView above) and,
    // once a show is drilled into, an episode table in its place
    NSSearchField *podcastSearchField;
    NSButton *subscribeButton;
    NSButton *backButton;
    NSScrollView *episodeScrollView;
    NSTableView *episodeTableView;
    NSScrollView *showNotesScrollView;
    NSTextView *showNotesTextView;
    PlayerTimelineView *podcastTimelineView;
    PodcastEpisode *currentPlayingEpisode;
    // The show currentPlayingEpisode belongs to; kept apart from
    // PodcastManager's currentShow because Back returns to the Shows
    // screen (clearing currentShow) without stopping playback
    Podcast *currentPlayingPodcast;
    // Set once at launch from the defaults saved at the last quit; consumed
    // (seeked to, then cleared) the first time any episode starts playing
    NSString *pendingResumeEpisodeIdentifier;
    NSTimeInterval pendingResumePosition;
    BOOL pendingResumeShouldPlay;

    // Streaming sites
    YTDLPBackend *ytdlpBackend;
    PreferencesController *preferencesController;

    // Quit-time fade-out of running sound
    BOOL quittingAfterFade;
    NSTimer *fadeTimer;
    NSDate *fadeStartDate;
    float fadeStartVolume;

    // Remote control for other programs in this session (GSMediaPlayer2,
    // MediaRemote/PROTOCOL.md): Whisper pauses us while its mic is open
    PlayerMediaRemote *mediaRemote;
    NSConnection *mediaRemoteConnection;
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

/// Podcast search/subscribe/stream mode, in PlayerController+Podcast.m
@interface PlayerController (Podcast)
- (IBAction)toggleBrowsePodcasts:(id)sender;
- (void)createPodcastViews;
- (void)enterPodcastMode;
/// Podcast mode as it was left: the last search and show, resuming the
/// episode and position saved at quit when `resume` and it was playing.
- (void)enterPodcastModeResuming:(BOOL)resume;
- (void)exitPodcastMode;
- (void)layoutPodcastMode;
- (void)updatePodcastControls;
- (void)podcastPlayPause;
- (void)podcastStop;
- (void)podcastNextEpisode;
- (void)podcastPreviousEpisode;
- (void)rebuildPodcastSubscriptionMenu;
- (BOOL)validatePodcastMenuItem:(NSMenuItem *)item;
/// Search results while the podcast search field has a query, else the
/// subscriptions - whichever the Shows screen (the flowView) is showing.
- (NSArray *)podcastShowsList;
/// Browsing (arrow keys) rested on this show; drills into its episodes
/// shortly, unless the selection moves on first.
- (void)podcastBrowseToShowAtIndex:(NSUInteger)index;
- (void)podcastDidStartPlayingEpisode;
- (void)podcastDidStop;
- (void)podcastDidFailWithError:(NSString *)errorMessage;
- (void)updatePodcastPosition;
/// Called from -applicationShouldTerminate: before playback stops, so
/// the next launch can resume it.
- (void)savePodcastPlaybackStateForQuit;
@end

#endif /* PlayerController_h */
