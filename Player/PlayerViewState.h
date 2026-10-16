/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef PlayerViewState_h
#define PlayerViewState_h

#import <Foundation/Foundation.h>
#import "PlayerPlaybackMachine.h"

typedef NS_ENUM(NSInteger, PlayerViewMode) {
    PlayerViewModeLocal,
    PlayerViewModeRadio,
    PlayerViewModePodcast
};

/// What the window shows besides the playback state.
typedef struct {
    PlayerViewMode mode;
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
} PlayerViewInputs;

/// Everything the window and the Playback menu show for a state.
typedef struct {
    BOOL playShowsPause;       // the button's image: pause rather than play
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
} PlayerViewState;

PlayerViewInputs PlayerViewInputsMake(PlayerViewMode mode);

/// The view of a playback state: a pure function, so every row of the
/// table is unit tested without a window.
PlayerViewState PlayerViewStateMake(PlayerPlaybackState state, PlayerViewInputs inputs);

/// "1:05", or "1:02:03" from an hour on.
NSString *PlayerFormatTime(NSTimeInterval seconds);

#endif /* PlayerViewState_h */
