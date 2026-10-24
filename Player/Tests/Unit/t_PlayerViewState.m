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
  PlayerViewInputs in = PlayerViewInputsMake(PlayerModeLocal);
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
                                            PlayerViewInputsMake(PlayerModeLocal));
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

  START_SET("Internet radio")
    PlayerViewInputs in = PlayerViewInputsMake(PlayerModeRadio);
    PlayerViewState v = PlayerViewStateMake(PlayerPlaybackEmpty, in);
    PASS([v.windowTitle isEqual: @"Player - Internet Radio"] && !v.playEnabled,
         "nothing to tune in yet");
    in.hasItems = YES;
    in.hasNext = YES;
    in.hasPrevious = YES;
    v = PlayerViewStateMake(PlayerPlaybackEmpty, in);
    PASS(v.playEnabled && [v.playTitle isEqual: @"Play"], "with stations, Play tunes one in");
    in.itemName = @"Jazz FM";
    v = PlayerViewStateMake(PlayerPlaybackOpening, in);
    PASS(v.playShowsStop && !v.playShowsPause && [v.playTitle isEqual: @"Stop"],
         "a station tuning in offers Stop: a live stream does not pause");
    PASS([v.windowTitle isEqual: @"Player - Jazz FM - Loading..."] && v.spinning, "loading");
    v = PlayerViewStateMake(PlayerPlaybackPlaying, in);
    PASS(v.playShowsStop && [v.playTitle isEqual: @"Stop"] && [v.playToolTip isEqual: @"Stop"],
         "a playing station offers Stop");
    PASS([v.totalTime isEqual: @"Live"] && [v.windowTitle isEqual: @"Player - Jazz FM"], "live");
    PASS(v.nextEnabled && v.previousEnabled, "and the other stations");
  END_SET("Internet radio")

  START_SET("Podcasts")
    PlayerViewInputs in = PlayerViewInputsMake(PlayerModePodcast);
    in.browsingShows = YES;
    in.hasItems = YES;
    PlayerViewState v = PlayerViewStateMake(PlayerPlaybackEmpty, in);
    PASS([v.playTitle isEqual: @"Open"] && v.playEnabled && !v.nextEnabled,
         "on the shows screen Play opens the show");
    PASS([v.windowTitle isEqual: @"Player - Podcasts"], "Player - Podcasts");
    in.browsingShows = NO;
    in.itemName = @"Episode 12";
    in.hasNext = YES;
    v = PlayerViewStateMake(PlayerPlaybackStopped, in);
    PASS([v.playTitle isEqual: @"Play"] && v.playEnabled && v.nextEnabled, "an episode can be played");
    v = PlayerViewStateMake(PlayerPlaybackOpening, in);
    PASS(v.playShowsPause && [v.playTitle isEqual: @"Pause"], "an episode opening offers Pause");
    in.duration = 1800;
    in.position = 60;
    v = PlayerViewStateMake(PlayerPlaybackPlaying, in);
    PASS(v.playShowsPause && !v.playShowsStop && [v.playTitle isEqual: @"Pause"],
         "a playing episode pauses");
    PASS(v.sliderEnabled && [v.totalTime isEqual: @"30:00"], "and can be sought");
    v = PlayerViewStateMake(PlayerPlaybackPaused, in);
    PASS([v.playTitle isEqual: @"Play"] && [v.windowTitle isEqual: @"Player - Episode 12 - Paused"],
         "a paused episode plays on");
    in.duration = 0;
    v = PlayerViewStateMake(PlayerPlaybackPlaying, in);
    PASS(v.playShowsStop && [v.playTitle isEqual: @"Stop"], "a live episode stream stops instead");
    in.browsingShows = YES;
    in.duration = 1800;
    v = PlayerViewStateMake(PlayerPlaybackPlaying, in);
    PASS([v.playTitle isEqual: @"Pause"], "on the shows screen an episode playing still pauses");
  END_SET("Podcasts")

  START_SET("the mode follows what is chosen")
    PASS(PlayerModeAfterRequest(PlayerModePodcast, PlayerModeRequestStation) == PlayerModeRadio,
         "a station chosen while podcasts show switches to the radio");
    PASS(PlayerModeAfterRequest(PlayerModeLocal, PlayerModeRequestStation) == PlayerModeRadio,
         "and while local files play");
    PASS(PlayerModeAfterRequest(PlayerModeRadio, PlayerModeRequestShow) == PlayerModePodcast
         && PlayerModeAfterRequest(PlayerModeLocal, PlayerModeRequestShow) == PlayerModePodcast,
         "a show chosen switches to podcasts");
    PASS(PlayerModeAfterRequest(PlayerModePodcast, PlayerModeRequestLocalItems) == PlayerModeLocal
         && PlayerModeAfterRequest(PlayerModeRadio, PlayerModeRequestLocalItems) == PlayerModeLocal,
         "files opened, dropped or an address opened switch to local playback");
    PASS(PlayerModeAfterRequest(PlayerModeRadio, PlayerModeRequestToggleRadio) == PlayerModeLocal
         && PlayerModeAfterRequest(PlayerModePodcast, PlayerModeRequestToggleRadio) == PlayerModeRadio,
         "the radio menu item toggles the radio, from any mode");
    PASS(PlayerModeAfterRequest(PlayerModePodcast, PlayerModeRequestTogglePodcasts) == PlayerModeLocal
         && PlayerModeAfterRequest(PlayerModeRadio, PlayerModeRequestTogglePodcasts) == PlayerModePodcast,
         "and the podcasts one podcasts");
  END_SET("the mode follows what is chosen")

  START_SET("the views follow the mode")
    PlayerViewInputs in = PlayerViewInputsMake(PlayerModeLocal);
    PlayerViewState v = PlayerViewStateMake(PlayerPlaybackPlaying, in);
    PASS(v.screen == PlayerViewScreenLocal && v.visible.trackInfo && v.visible.positionSlider
         && v.visible.carousel && !v.visible.video, "local: track info, slider and covers");
    PASS(!v.visible.radioSearch && !v.visible.status && !v.visible.podcastSearch
         && !v.visible.episodes && !v.visible.timeline && !v.visible.topBar,
         "and nothing of the radio or podcasts");
    in.showsVideo = YES;
    v = PlayerViewStateMake(PlayerPlaybackPlaying, in);
    PASS(v.visible.video && !v.visible.carousel, "a video replaces the covers");

    in = PlayerViewInputsMake(PlayerModeRadio);
    in.showsVideo = YES;
    v = PlayerViewStateMake(PlayerPlaybackOpening, in);
    PASS(v.screen == PlayerViewScreenRadio && v.visible.radioSearch && v.visible.status
         && v.visible.radioText && v.visible.topBar && v.visible.carousel,
         "radio: search, status, station covers");
    PASS(!v.visible.trackInfo && !v.visible.positionSlider && !v.visible.episodes
         && !v.visible.podcastSearch && !v.visible.timeline && !v.visible.video,
         "and no episode list, track info or picture of an earlier video");

    in = PlayerViewInputsMake(PlayerModePodcast);
    in.browsingShows = YES;
    v = PlayerViewStateMake(PlayerPlaybackPaused, in);
    PASS(v.screen == PlayerViewScreenPodcastShows && v.visible.podcastSearch && v.visible.carousel
         && !v.visible.episodes && !v.visible.radioSearch && !v.visible.radioText,
         "podcast shows: search and show covers");
    in.browsingShows = NO;
    v = PlayerViewStateMake(PlayerPlaybackPlaying, in);
    PASS(v.screen == PlayerViewScreenPodcastEpisodes && v.visible.episodes && v.visible.timeline
         && !v.visible.carousel && !v.visible.podcastSearch && !v.visible.positionSlider,
         "podcast episodes: the episode list and timeline instead of covers");

    in.fullscreen = YES;
    v = PlayerViewStateMake(PlayerPlaybackPlaying, in);
    PASS(v.visible.carousel && !v.visible.episodes && !v.visible.status && !v.visible.volume
         && v.visible.transport, "full screen: the picture and the transport only");
  END_SET("the views follow the mode")

  START_SET("spinner and titles outside a state")
    PlayerViewInputs in = PlayerViewInputsMake(PlayerModeLocal);
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
