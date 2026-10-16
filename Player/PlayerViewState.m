/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PlayerViewState.h"

PlayerViewInputs PlayerViewInputsMake(PlayerViewMode mode)
{
    PlayerViewInputs inputs;
    memset(&inputs, 0, sizeof(inputs));
    inputs.mode = mode;
    return inputs;
}

NSString *PlayerFormatTime(NSTimeInterval seconds)
{
    if (seconds < 0 || isnan(seconds) || isinf(seconds)) {
        seconds = 0;
    }
    long total = lround(seconds);
    if (total >= 3600) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld",
                total / 3600, (total % 3600) / 60, total % 60];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", total / 60, total % 60];
}

static NSString *titleOfMode(PlayerViewMode mode)
{
    switch (mode) {
    case PlayerViewModeRadio: return @"Player - Internet Radio";
    case PlayerViewModePodcast: return @"Player - Podcasts";
    case PlayerViewModeLocal: break;
    }
    return @"Player";
}

static NSString *titleWithName(PlayerViewMode mode, NSString *name, NSString *suffix)
{
    if (!name) {
        return titleOfMode(mode);
    }
    return suffix ? [NSString stringWithFormat:@"Player - %@ - %@", name, suffix]
                  : [NSString stringWithFormat:@"Player - %@", name];
}

static NSString *windowTitle(PlayerPlaybackState state, PlayerViewInputs in)
{
    // What the user is doing right now says more than what plays
    if (in.dragHover) {
        return @"Player - Add to Playlist";
    }
    if (in.resolving) {
        return @"Player - Finding media...";
    }
    switch (state) {
    case PlayerPlaybackEmpty:
        return titleOfMode(in.mode);
    case PlayerPlaybackOpening:
        return titleWithName(in.mode, in.itemName, @"Loading...");
    case PlayerPlaybackPlaying:
        return titleWithName(in.mode, in.itemName, in.buffering ? @"Buffering..." : nil);
    case PlayerPlaybackPaused:
        return titleWithName(in.mode, in.itemName, @"Paused");
    case PlayerPlaybackStopped:
        break;
    }
    if (in.lastError && in.itemName) {
        return [NSString stringWithFormat:@"Player - %@ (Cannot Be Played)", in.itemName];
    }
    return titleWithName(in.mode, in.itemName, nil);
}

// A live stream cannot pause and go on where it was: the button stops it.
// Radio stations are live; a podcast episode is unless it has a length.
static BOOL stopsInsteadOfPausing(PlayerPlaybackState state, PlayerViewInputs in)
{
    if (in.mode == PlayerViewModeRadio) {
        return state == PlayerPlaybackOpening || state == PlayerPlaybackPlaying;
    }
    if (in.mode == PlayerViewModePodcast) {
        return state == PlayerPlaybackPlaying && in.duration <= 0;
    }
    return NO;
}

PlayerViewState PlayerViewStateMake(PlayerPlaybackState state, PlayerViewInputs in)
{
    PlayerViewState view;
    memset(&view, 0, sizeof(view));
    BOOL empty = state == PlayerPlaybackEmpty;
    BOOL open = state == PlayerPlaybackPlaying || state == PlayerPlaybackPaused;

    BOOL active = open || state == PlayerPlaybackOpening;

    // The button pauses what plays and what is about to play, unless a
    // pause pressed while opening is pending already
    view.playShowsStop = stopsInsteadOfPausing(state, in);
    view.playShowsPause = !view.playShowsStop && (state == PlayerPlaybackPlaying
        || (state == PlayerPlaybackOpening && !in.pendingPause));
    if (view.playShowsStop) {
        view.playTitle = @"Stop";
    } else if (view.playShowsPause) {
        view.playTitle = @"Pause";
    } else if (in.browsingShows && !active) {
        view.playTitle = @"Open";   // opens the chosen show; makes no sound
    } else {
        view.playTitle = @"Play";
    }
    view.playToolTip = (state == PlayerPlaybackOpening && view.playShowsPause)
        ? @"Stop Loading" : view.playTitle;
    // Radio and podcasts always have something to choose from once loaded
    view.playEnabled = in.mode == PlayerViewModeLocal ? !empty : (active || in.hasItems);
    view.stopEnabled = !empty && state != PlayerPlaybackStopped;
    BOOL choosable = in.mode == PlayerViewModeLocal ? !empty : YES;
    view.nextEnabled = choosable && in.hasNext;
    view.previousEnabled = choosable && in.hasPrevious;

    // Only something open has a position; a live stream has no end
    NSTimeInterval position = open ? in.position : 0;
    view.sliderEnabled = open && in.duration > 0;
    view.sliderMax = MAX(open ? in.duration : 0, 1.0);
    view.sliderValue = MIN(position, view.sliderMax);
    view.currentTime = PlayerFormatTime(position);
    switch (state) {
    case PlayerPlaybackEmpty:
        view.totalTime = PlayerFormatTime(0);
        break;
    case PlayerPlaybackStopped:
        view.totalTime = @"--";
        break;
    case PlayerPlaybackOpening:
        // A file or a live stream: not known until it is open
        view.totalTime = @"--:--";
        break;
    case PlayerPlaybackPlaying:
    case PlayerPlaybackPaused:
        view.totalTime = in.duration > 0 ? PlayerFormatTime(in.duration) : @"Live";
        break;
    }

    view.windowTitle = windowTitle(state, in);
    // An error matters where it left the player: stopped after a failure,
    // or paused because the audio output went away
    if (state == PlayerPlaybackStopped || state == PlayerPlaybackPaused) {
        view.errorText = [in.lastError localizedDescription];
    }
    view.spinning = in.resolving || state == PlayerPlaybackOpening
        || (state == PlayerPlaybackPlaying && in.buffering);
    return view;
}
