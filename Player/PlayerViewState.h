/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef PlayerViewState_h
#define PlayerViewState_h

#import <Foundation/Foundation.h>
#import "PlayerPlaybackMachine.h"

/// What the window is for: local files, Internet radio or podcasts.  The
/// raw values are kept in the defaults.
typedef NS_ENUM(NSInteger, PlayerMode) {
    PlayerModeLocal,
    PlayerModeRadio,
    PlayerModePodcast
};

/// What the user chose that decides the mode
typedef NS_ENUM(NSInteger, PlayerModeRequest) {
    PlayerModeRequestLocalItems,      // files opened or dropped, an address opened
    PlayerModeRequestStation,         // a radio station chosen
    PlayerModeRequestShow,            // a podcast show chosen
    PlayerModeRequestToggleRadio,     // Radio > Internet Radio
    PlayerModeRequestTogglePodcasts   // Podcasts > Browse Podcasts
};

/// The mode a request leads to, from the current one.
PlayerMode PlayerModeAfterRequest(PlayerMode current, PlayerModeRequest request);

/// The screens of the window: a mode, and for podcasts its sub-screen
typedef NS_ENUM(NSInteger, PlayerViewScreen) {
    PlayerViewScreenLocal,
    PlayerViewScreenRadio,
    PlayerViewScreenPodcastShows,
    PlayerViewScreenPodcastEpisodes
};

/// Which groups of views a screen shows
typedef struct {
    BOOL carousel;        // cover art, stations or shows
    BOOL video;
    BOOL trackInfo;       // title, artist, album, details
    BOOL positionSlider;  // with the time labels
    BOOL timeline;        // podcast chapters, with the time labels
    BOOL radioSearch;
    BOOL radioText;
    BOOL status;
    BOOL podcastSearch;   // with Subscribe
    BOOL episodes;        // Back, the episode table and the show notes
    BOOL topBar;
    BOOL transport;
    BOOL volume;
} PlayerViewVisibility;

/// What the window shows besides the playback state.
typedef struct {
    PlayerMode mode;
    NSString *itemName;        // the current item as shown; nil: none
    BOOL hasNext;
    BOOL hasPrevious;
    NSTimeInterval duration;   // 0: unknown, or a live stream
    NSTimeInterval position;
    NSError *lastError;        // the playback machine's last failure
    BOOL pendingPause;         // pause was pressed while opening
    BOOL resolving;            // a web page is being looked up for its media
    BOOL dragHover;            // files are dragged over the window
    BOOL buffering;
    // Radio and podcasts: something to tune in, open or play
    BOOL hasItems;
    // Podcasts: the shows are shown, where Play opens the chosen one
    BOOL browsingShows;
    BOOL fullscreen;
    BOOL showsVideo;           // the local item has a picture
} PlayerViewInputs;

/// Everything the window and the Playback menu show for a state.
typedef struct {
    BOOL playShowsPause;       // the button's image: pause rather than play
    BOOL playShowsStop;        // ... or stop, for a live stream
    NSString *playTitle;       // also the Playback menu item's title
    NSString *playToolTip;
    BOOL playEnabled;
    BOOL stopEnabled;
    BOOL nextEnabled;
    BOOL previousEnabled;
    BOOL sliderEnabled;
    double sliderMax;
    double sliderValue;
    NSString *currentTime;
    NSString *totalTime;
    NSString *windowTitle;
    BOOL spinning;
    NSString *errorText;       // why it stopped or paused; nil: no error
    PlayerViewScreen screen;
    PlayerViewVisibility visible;
} PlayerViewState;

PlayerViewInputs PlayerViewInputsMake(PlayerMode mode);

/// The view of a playback state: a pure function, so every row of the
/// table is unit tested without a window.
PlayerViewState PlayerViewStateMake(PlayerPlaybackState state, PlayerViewInputs inputs);

/// "1:05", or "1:02:03" from an hour on.
NSString *PlayerFormatTime(NSTimeInterval seconds);

#endif /* PlayerViewState_h */
