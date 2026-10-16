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

static NSString *titleWithName(NSString *name, NSString *suffix)
{
    if (!name) {
        return @"Player";
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
        return @"Player";
    case PlayerPlaybackOpening:
        return titleWithName(in.itemName, @"Loading...");
    case PlayerPlaybackPlaying:
        return titleWithName(in.itemName, in.buffering ? @"Buffering..." : nil);
    case PlayerPlaybackPaused:
        return titleWithName(in.itemName, @"Paused");
    case PlayerPlaybackStopped:
        break;
    }
    if (in.lastError && in.itemName) {
        return [NSString stringWithFormat:@"Player - %@ (Cannot Be Played)", in.itemName];
    }
    return titleWithName(in.itemName, nil);
}

PlayerViewState PlayerViewStateMake(PlayerPlaybackState state, PlayerViewInputs in)
{
    PlayerViewState view;
    memset(&view, 0, sizeof(view));
    BOOL empty = state == PlayerPlaybackEmpty;
    BOOL open = state == PlayerPlaybackPlaying || state == PlayerPlaybackPaused;

    // The button pauses what plays and what is about to play, unless a
    // pause pressed while opening is pending already
    view.playShowsPause = state == PlayerPlaybackPlaying
        || (state == PlayerPlaybackOpening && !in.pendingPause);
    view.playTitle = view.playShowsPause ? @"Pause" : @"Play";
    view.playToolTip = (state == PlayerPlaybackOpening && view.playShowsPause)
        ? @"Stop Loading" : view.playTitle;
    view.playEnabled = !empty;
    view.stopEnabled = !empty && state != PlayerPlaybackStopped;
    view.nextEnabled = !empty && in.hasNext;
    view.previousEnabled = !empty && in.hasPrevious;

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
