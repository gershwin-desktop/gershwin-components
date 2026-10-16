/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_PlayerViewState.m - what the window shows in each playback state: the
 * Play button, Stop, Next/Previous, the position slider, the time labels,
 * the window title and the spinner.  A pure function, so no window. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../../PlayerViewState.m"

static PlayerViewInputs named(NSString *name)
{
  PlayerViewInputs in = PlayerViewInputsMake(PlayerViewModeLocal);
  in.itemName = name;
  in.hasNext = YES;
  in.hasPrevious = YES;
  return in;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("Empty")
    PlayerViewState v = PlayerViewStateMake(PlayerPlaybackEmpty,
                                            PlayerViewInputsMake(PlayerViewModeLocal));
    PASS(!v.playShowsPause && [v.playTitle isEqual: @"Play"] && !v.playEnabled,
         "Play, disabled");
    PASS(!v.stopEnabled && !v.nextEnabled && !v.previousEnabled, "no transport");
    PASS(!v.sliderEnabled && v.sliderValue == 0, "the slider is off, at 0");
    PASS([v.currentTime isEqual: @"0:00"] && [v.totalTime isEqual: @"0:00"], "0:00 / 0:00");
    PASS([v.windowTitle isEqual: @"Player"], "the window is just Player");
    PASS(!v.spinning, "nothing spins");
  END_SET("Empty")

  START_SET("Stopped")
    PlayerViewInputs in = named(@"Track Two");
    in.hasNext = NO;
    PlayerViewState v = PlayerViewStateMake(PlayerPlaybackStopped, in);
    PASS([v.playTitle isEqual: @"Play"] && v.playEnabled && !v.playShowsPause, "Play");
    PASS(!v.stopEnabled, "nothing to stop");
    PASS(!v.nextEnabled && v.previousEnabled, "next and previous follow the playlist");
    PASS(!v.sliderEnabled, "no slider");
    PASS([v.currentTime isEqual: @"0:00"] && [v.totalTime isEqual: @"--"], "0:00 / --");
    PASS([v.windowTitle isEqual: @"Player - Track Two"], "Player - Name");
    PASS(!v.spinning, "no spinner");
  END_SET("Stopped")

  START_SET("Opening")
    PlayerViewInputs in = named(@"Url Tone");
    in.duration = 0;
    PlayerViewState v = PlayerViewStateMake(PlayerPlaybackOpening, in);
    PASS(v.playShowsPause && [v.playTitle isEqual: @"Pause"], "Pause");
    PASS([v.playToolTip isEqual: @"Stop Loading"], "with the tooltip Stop Loading");
    PASS(v.stopEnabled && v.nextEnabled && v.previousEnabled, "stop, next and previous");
    PASS(!v.sliderEnabled, "no slider while opening");
    PASS([v.currentTime isEqual: @"0:00"] && [v.totalTime isEqual: @"--:--"],
         "0:00 / --:--, never Live: what is opening is not known yet");
    PASS([v.windowTitle isEqual: @"Player - Url Tone - Loading..."], "Loading...");
    PASS(v.spinning, "the spinner turns");
    in.pendingPause = YES;
    v = PlayerViewStateMake(PlayerPlaybackOpening, in);
    PASS(!v.playShowsPause && [v.playTitle isEqual: @"Play"] && [v.playToolTip isEqual: @"Play"],
         "with a pause pending the button offers Play");
    in.pendingPause = NO;
    in.resolving = YES;
    v = PlayerViewStateMake(PlayerPlaybackOpening, in);
    PASS([v.windowTitle isEqual: @"Player - Finding media..."], "a web page being looked up says so");
  END_SET("Opening")

  START_SET("Playing")
    PlayerViewInputs in = named(@"Track One");
    in.duration = 125;
    in.position = 65;
    PlayerViewState v = PlayerViewStateMake(PlayerPlaybackPlaying, in);
    PASS(v.playShowsPause && [v.playTitle isEqual: @"Pause"] && v.playEnabled, "Pause");
    PASS(v.stopEnabled, "stop");
    PASS(v.sliderEnabled && v.sliderMax == 125 && v.sliderValue == 65, "the slider follows");
    PASS([v.currentTime isEqual: @"1:05"] && [v.totalTime isEqual: @"2:05"], "pos / dur");
    PASS([v.windowTitle isEqual: @"Player - Track One"], "Player - Name");
    PASS(!v.spinning, "no spinner");
    in.buffering = YES;
    v = PlayerViewStateMake(PlayerPlaybackPlaying, in);
    PASS([v.windowTitle isEqual: @"Player - Track One - Buffering..."] && v.spinning,
         "buffering shows in the title and spins");
    in.buffering = NO;
    in.duration = 0;
    v = PlayerViewStateMake(PlayerPlaybackPlaying, in);
    PASS([v.totalTime isEqual: @"Live"] && !v.sliderEnabled, "a live stream: Live, no slider");
    in.dragHover = YES;
    v = PlayerViewStateMake(PlayerPlaybackPlaying, in);
    PASS([v.windowTitle isEqual: @"Player - Add to Playlist"], "files dragged over say what a drop does");
  END_SET("Playing")

  START_SET("Paused")
    PlayerViewInputs in = named(@"Track Two");
    in.duration = 3700;
    in.position = 3723;
    PlayerViewState v = PlayerViewStateMake(PlayerPlaybackPaused, in);
    PASS(!v.playShowsPause && [v.playTitle isEqual: @"Play"], "Play");
    PASS(v.stopEnabled && v.sliderEnabled, "stop and slider");
    PASS(v.sliderValue == 3700, "the slider never goes past the end");
    PASS([v.currentTime isEqual: @"1:02:03"] && [v.totalTime isEqual: @"1:01:40"],
         "hours are shown from an hour on");
    PASS([v.windowTitle isEqual: @"Player - Track Two - Paused"], "Player - Name - Paused");
    PASS(!v.spinning, "no spinner");
  END_SET("Paused")

  START_SET("errors are shown in the window")
    NSError *error = [NSError errorWithDomain: @"Test" code: 1
      userInfo: @{NSLocalizedDescriptionKey: @"Invalid data found when processing input"}];
    PlayerViewInputs in = named(@"Broken");
    in.lastError = error;
    PlayerViewState v = PlayerViewStateMake(PlayerPlaybackStopped, in);
    PASS([v.windowTitle isEqual: @"Player - Broken (Cannot Be Played)"],
         "a stopped item that failed says so in the title");
    PASS([v.errorText isEqual: @"Invalid data found when processing input"],
         "and why, in the window");
    v = PlayerViewStateMake(PlayerPlaybackPaused, in);
    PASS([v.errorText isEqual: @"Invalid data found when processing input"],
         "paused because the audio output went away says why");
    PASS([v.windowTitle isEqual: @"Player - Broken - Paused"], "still paused in the title");
    v = PlayerViewStateMake(PlayerPlaybackOpening, in);
    PASS(v.errorText == nil && [v.windowTitle isEqual: @"Player - Broken - Loading..."],
         "opening the next item shows no old error");
    v = PlayerViewStateMake(PlayerPlaybackPlaying, in);
    PASS(v.errorText == nil, "nor does playing");
    in.lastError = nil;
    v = PlayerViewStateMake(PlayerPlaybackStopped, in);
    PASS(v.errorText == nil && [v.windowTitle isEqual: @"Player - Broken"], "without an error, none");
  END_SET("errors are shown in the window")

  START_SET("spinner and titles outside a state")
    PlayerViewInputs in = PlayerViewInputsMake(PlayerViewModeLocal);
    in.resolving = YES;
    PlayerViewState v = PlayerViewStateMake(PlayerPlaybackEmpty, in);
    PASS(v.spinning && [v.windowTitle isEqual: @"Player - Finding media..."],
         "looking up a web page spins and says so, whatever plays");
    in.dragHover = YES;
    v = PlayerViewStateMake(PlayerPlaybackEmpty, in);
    PASS([v.windowTitle isEqual: @"Player - Add to Playlist"], "a drag says what a drop does");
  END_SET("spinner and titles outside a state")

  [arp release];
  return 0;
}
