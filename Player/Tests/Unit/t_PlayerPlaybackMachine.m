/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_PlayerPlaybackMachine.m - the playback state table, row by row: what
 * each state does with each event, which effects it asks for, that events
 * of an old generation are dropped, and that pending seeks and pauses land
 * where they belong.  Pure Foundation, no media player. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../../PlayerPlaybackMachine.m"

static NSArray *tracks(void)
{
  return @[@"/music/1.mp3", @"/music/2.mp3", @"/music/3.mp3"];
}

static PlayerTransition *command(PlayerPlaybackMachine *m, PlayerEventType type)
{
  return [m handle: PlayerEventMake(type)];
}

static PlayerTransition *media(PlayerPlaybackMachine *m, PlayerEventType type)
{
  return [m handle: PlayerEventFromMedia(type, [m generation])];
}

static NSError *failure(void)
{
  return [NSError errorWithDomain: @"Test" code: 1
                         userInfo: @{NSLocalizedDescriptionKey: @"cannot be decoded"}];
}

/* A machine playing the first of three tracks */
static PlayerPlaybackMachine *playing(void)
{
  PlayerPlaybackMachine *m = [[PlayerPlaybackMachine new] autorelease];
  [m handle: PlayerEventWithItems(PlayerEventOpen, tracks())];
  media(m, PlayerEventOpened);
  return m;
}

static BOOL ignoredInState(PlayerPlaybackMachine *m, PlayerEvent e, PlayerPlaybackState s)
{
  NSUInteger effects = [m effectGeneration];
  PlayerTransition *t = [m handle: e];
  return ![t handled] && [[t effects] count] == 0 && [m state] == s
    && [m effectGeneration] == effects;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("Empty")
    PlayerPlaybackMachine *m = [[PlayerPlaybackMachine new] autorelease];
    PASS([m state] == PlayerPlaybackEmpty, "a new machine is empty");
    PlayerEventType ignored[] = {PlayerEventPlay, PlayerEventPause, PlayerEventToggle,
      PlayerEventStop, PlayerEventNext, PlayerEventPrevious, PlayerEventSeek,
      PlayerEventClear};
    BOOL allIgnored = YES;
    unsigned i;
    for (i = 0; i < sizeof(ignored) / sizeof(ignored[0]); i++)
      {
        allIgnored = allIgnored
          && ignoredInState(m, PlayerEventMake(ignored[i]), PlayerPlaybackEmpty);
      }
    PASS(allIgnored, "commands other than open and add are ignored");
    PASS(ignoredInState(m, PlayerEventSelectIndex(0), PlayerPlaybackEmpty),
         "so is choosing an item");
    PASS(ignoredInState(m, PlayerEventFromMedia(PlayerEventOpened, 0), PlayerPlaybackEmpty),
         "and anything from the media");
    PASS(ignoredInState(m, PlayerEventWithItems(PlayerEventOpen, @[]), PlayerPlaybackEmpty),
         "opening nothing leaves it empty");

    NSUInteger gen = [m generation];
    PlayerTransition *t = [m handle: PlayerEventWithItems(PlayerEventOpen, tracks())];
    PASS([t state] == PlayerPlaybackOpening && [t committed], "open starts opening");
    PASS([m generation] == gen + 1, "with a new generation");
    PlayerEffect *open = [t effectOfType: PlayerEffectOpen];
    PASS(open != nil && [open index] == 0 && [[open item] isEqual: @"/music/1.mp3"]
         && [open generation] == [m generation], "the first item is opened, tagged");
    PASS(![open flag], "nothing cross-fades into the first item");
    PASS([t hasEffect: PlayerEffectTrackChanged], "and the track change is shown");

    PlayerPlaybackMachine *a = [[PlayerPlaybackMachine new] autorelease];
    t = [a handle: PlayerEventWithItems(PlayerEventAdd, tracks())];
    PASS([t state] == PlayerPlaybackOpening && [[a playlist] currentIndex] == 0,
         "adding to an empty player opens the first item added");
  END_SET("Empty")

  START_SET("Opening")
    PlayerPlaybackMachine *m = [[PlayerPlaybackMachine new] autorelease];
    [m handle: PlayerEventWithItems(PlayerEventOpen, tracks())];
    NSUInteger effects = [m effectGeneration];
    PlayerTransition *t = [m handle: PlayerEventFromMedia(PlayerEventOpened, [m generation] - 1)];
    PASS(![t handled] && [m state] == PlayerPlaybackOpening,
         "an opened of an old generation is dropped");

    t = [m handle: PlayerEventSeekTo(30, 0)];
    PASS([t handled] && [m state] == PlayerPlaybackOpening && [[t effects] count] == 0,
         "a seek while opening changes no state and touches no media");
    PASS([m pendingSeek] == 30, "it is kept as the pending seek");
    PASS([m effectGeneration] == effects, "and cancels nothing pending");

    t = command(m, PlayerEventToggle);
    PASS([m pendingPause] && [m state] == PlayerPlaybackOpening && [[t effects] count] == 0,
         "pause while opening is remembered, still opening");
    t = media(m, PlayerEventOpened);
    PASS([t state] == PlayerPlaybackPaused, "once open it lands paused");
    PlayerEffect *seek = [t effectOfType: PlayerEffectSeek];
    PASS(seek != nil && [seek time] == 30, "at the pending seek");
    PASS([t hasEffect: PlayerEffectPause] && ![t hasEffect: PlayerEffectFadeIn],
         "paused at once, without fading in");
    PASS(![m pendingPause] && [m pendingSeek] < 0, "nothing is pending any more");

    m = [[PlayerPlaybackMachine new] autorelease];
    [m handle: PlayerEventWithItems(PlayerEventOpen, tracks())];
    command(m, PlayerEventToggle);
    command(m, PlayerEventToggle);
    PASS(![m pendingPause], "a second press while opening takes the pause back");
    command(m, PlayerEventPause);
    command(m, PlayerEventPlay);
    PASS(![m pendingPause], "and so does play");
    effects = [m effectGeneration];
    t = media(m, PlayerEventOpened);
    PASS([t state] == PlayerPlaybackPlaying && [t hasEffect: PlayerEffectFadeIn],
         "opened without a pending pause plays, fading a stream in");
    PASS([m effectGeneration] == effects + 1, "a committed transition moves the effect generation");

    /* failures */
    m = [[PlayerPlaybackMachine new] autorelease];
    [m handle: PlayerEventWithItems(PlayerEventOpen, tracks())];
    NSUInteger gen = [m generation];
    t = [m handle: PlayerEventFailure(gen, failure())];
    PASS([t state] == PlayerPlaybackOpening && [[m playlist] currentIndex] == 1,
         "a failure while attempts remain opens the next item");
    PASS([m generation] == gen + 1, "with a new generation");
    PlayerEffect *report = [t effectOfType: PlayerEffectReportFailure];
    PASS(report != nil && [[report item] isEqual: @"/music/1.mp3"] && [report index] == 0,
         "the broken item is reported");
    PASS([[m lastError] isEqual: failure()] || [[[m lastError] localizedDescription]
         isEqual: @"cannot be decoded"], "and kept as the last error");
    [m handle: PlayerEventFailure([m generation], failure())];
    t = [m handle: PlayerEventFailure([m generation], failure())];
    PASS([t state] == PlayerPlaybackStopped && [t hasEffect: PlayerEffectClose],
         "when every item failed it stops");
    PASS([m lastError] != nil, "with the error kept as model data");

    m = [[PlayerPlaybackMachine new] autorelease];
    [m handle: PlayerEventWithItems(PlayerEventOpen, tracks())];
    media(m, PlayerEventOpened);
    [m handle: PlayerEventSelectIndex(2)];
    t = [m handle: PlayerEventFailure([m generation], failure())];
    PASS([t state] == PlayerPlaybackStopped && [[m playlist] currentIndex] == 2,
         "an item chosen by hand that fails is not skipped");

    /* stop and choosing another item */
    m = [[PlayerPlaybackMachine new] autorelease];
    [m handle: PlayerEventWithItems(PlayerEventOpen, tracks())];
    gen = [m generation];
    t = command(m, PlayerEventStop);
    PASS([t state] == PlayerPlaybackStopped && [t hasEffect: PlayerEffectClose],
         "stop gives up the attempt");
    PASS(ignoredInState(m, PlayerEventFromMedia(PlayerEventOpened, gen), PlayerPlaybackStopped),
         "and the attempt's late opened is dropped");

    m = [[PlayerPlaybackMachine new] autorelease];
    [m handle: PlayerEventWithItems(PlayerEventOpen, tracks())];
    [m handle: PlayerEventSeekTo(20, 0)];
    command(m, PlayerEventPause);
    gen = [m generation];
    t = command(m, PlayerEventNext);
    PASS([t state] == PlayerPlaybackOpening && [m generation] == gen + 1
         && [[t effectOfType: PlayerEffectOpen] index] == 1, "next while opening opens the next");
    PASS(![m pendingPause] && [m pendingSeek] < 0, "dropping what was pending");
    PASS(ignoredInState(m, PlayerEventSelectIndex(1), PlayerPlaybackOpening),
         "choosing the item that is opening changes nothing");
    t = [m handle: PlayerEventPreviousAt(0)];
    PASS([[t effectOfType: PlayerEffectOpen] index] == 0, "previous while opening opens the one before");
    t = [m handle: PlayerEventSelectIndex(2)];
    PASS([[t effectOfType: PlayerEffectOpen] index] == 2, "an item chosen while opening opens");
    t = [m handle: PlayerEventWithItems(PlayerEventOpen, @[@"/music/x.mp3"])];
    PASS([[t effectOfType: PlayerEffectOpen] index] == 0 && [[m playlist] count] == 1,
         "open while opening replaces the list");
  END_SET("Opening")

  START_SET("Playing")
    PlayerPlaybackMachine *m = playing();
    PASS([m state] == PlayerPlaybackPlaying, "the first track plays");
    NSUInteger effects = [m effectGeneration];
    PlayerTransition *t = command(m, PlayerEventToggle);
    PASS([t state] == PlayerPlaybackPaused && [t hasEffect: PlayerEffectFadeOutPause],
         "pause fades out, then pauses");
    PASS([m effectGeneration] == effects + 1, "tagged with a new effect generation");

    m = playing();
    effects = [m effectGeneration];
    t = [m handle: PlayerEventSeekTo(150, 100)];
    PASS([t state] == PlayerPlaybackPlaying && [[t effectOfType: PlayerEffectSeek] time] == 100,
         "a seek is clamped to the end");
    t = [m handle: PlayerEventSeekTo(-5, 100)];
    PASS([[t effectOfType: PlayerEffectSeek] time] == 0, "and to the start");
    PASS([m effectGeneration] == effects, "seeking cancels nothing pending");
    PASS(ignoredInState(m, PlayerEventSeekTo(10, 0), PlayerPlaybackPlaying),
         "a live stream without length cannot be sought");

    NSUInteger gen = [m generation];
    t = command(m, PlayerEventStop);
    PASS([t state] == PlayerPlaybackStopped && [t hasEffect: PlayerEffectFadeOutClose],
         "stop fades out, then closes");
    PASS(ignoredInState(m, PlayerEventFromMedia(PlayerEventEnded, gen), PlayerPlaybackStopped),
         "the end of the track stopped is dropped");

    m = playing();
    t = media(m, PlayerEventEnded);
    PlayerEffect *open = [t effectOfType: PlayerEffectOpen];
    PASS([t state] == PlayerPlaybackOpening && [open index] == 1 && ![open flag],
         "at its end the next track opens, without a cross-fade");
    media(m, PlayerEventOpened);
    [m handle: PlayerEventSelectIndex(2)];
    media(m, PlayerEventOpened);
    t = media(m, PlayerEventEnded);
    PASS([t state] == PlayerPlaybackStopped && [[m playlist] currentIndex] == 0
         && [t hasEffect: PlayerEffectClose] && [t hasEffect: PlayerEffectTrackChanged],
         "after the last track it stops on the first, ready to play the list again");

    m = playing();
    t = media(m, PlayerEventNearEnd);
    open = [t effectOfType: PlayerEffectOpen];
    PASS([t state] == PlayerPlaybackOpening && [open index] == 1 && [open flag],
         "near its end the next track opens and cross-fades");
    media(m, PlayerEventOpened);
    [m handle: PlayerEventSelectIndex(2)];
    media(m, PlayerEventOpened);
    PASS(ignoredInState(m, PlayerEventFromMedia(PlayerEventNearEnd, [m generation]),
                        PlayerPlaybackPlaying), "the last track plays out to its end");

    m = playing();
    t = [m handle: PlayerEventFailure([m generation], failure())];
    PASS([t hasEffect: PlayerEffectReportFailure] && [t state] == PlayerPlaybackOpening
         && [[t effectOfType: PlayerEffectOpen] index] == 1,
         "a track that breaks off is reported and the next follows");
    [m handle: PlayerEventSelectIndex(2)];
    media(m, PlayerEventOpened);
    t = [m handle: PlayerEventFailure([m generation], failure())];
    PASS([t state] == PlayerPlaybackStopped && [m lastError] != nil,
         "the last one breaking off stops, keeping the error");

    m = playing();
    t = [m handle: PlayerEventWithItems(PlayerEventOpen, @[@"http://radio/b"])];
    PASS([t state] == PlayerPlaybackOpening && [[t effectOfType: PlayerEffectOpen] flag],
         "opening something else while playing cross-fades into it (a radio station switch)");

    m = playing();
    t = command(m, PlayerEventNext);
    PASS([[t effectOfType: PlayerEffectOpen] flag], "next while playing cross-fades");
    media(m, PlayerEventOpened);
    t = [m handle: PlayerEventPreviousAt(10)];
    PASS([t state] == PlayerPlaybackPlaying && [[t effectOfType: PlayerEffectSeek] time] == 0
         && ![t committed], "previous a while into a track restarts it");
    t = [m handle: PlayerEventPreviousAt(1)];
    PASS([[t effectOfType: PlayerEffectOpen] index] == 0 && [[t effectOfType: PlayerEffectOpen] flag],
         "previous at its start goes to the one before");
    media(m, PlayerEventOpened);
    PASS(ignoredInState(m, PlayerEventSelectIndex(0), PlayerPlaybackPlaying),
         "choosing the playing track does not restart it");

    m = playing();
    t = media(m, PlayerEventDeviceLost);
    PASS([t state] == PlayerPlaybackPaused && [t hasEffect: PlayerEffectPause],
         "losing the audio output pauses");
    PASS([[[m lastError] localizedDescription] isEqual: @"Audio output is not available"],
         "saying why");
    t = command(m, PlayerEventPlay);
    PASS([t state] == PlayerPlaybackPlaying && [m lastError] == nil,
         "playing again forgets the error");

    m = playing();
    [m handle: PlayerEventBuffering([m generation], YES)];
    PASS([m buffering] && [m state] == PlayerPlaybackPlaying, "buffering is model data");
    [m handle: PlayerEventBuffering([m generation] - 1, NO)];
    PASS([m buffering], "of the current generation only");
    [m handle: PlayerEventBuffering([m generation], NO)];
    PASS(![m buffering], "and ends when the data is back");
  END_SET("Playing")

  START_SET("Paused")
    PlayerPlaybackMachine *m = playing();
    command(m, PlayerEventPause);
    PASS(ignoredInState(m, PlayerEventMake(PlayerEventPause), PlayerPlaybackPaused),
         "pause while paused changes nothing");
    PlayerTransition *t = [m handle: PlayerEventSeekTo(40, 100)];
    PASS([t state] == PlayerPlaybackPaused && [[t effectOfType: PlayerEffectSeek] time] == 40,
         "a seek while paused moves the position, still paused");
    t = command(m, PlayerEventToggle);
    PASS([t state] == PlayerPlaybackPlaying && [t hasEffect: PlayerEffectResume],
         "play resumes, fading in");

    m = playing();
    command(m, PlayerEventPause);
    NSUInteger opens = 0;
    t = media(m, PlayerEventEnded);
    for (PlayerEffect *e in [t effects])
      {
        if ([e type] == PlayerEffectOpen)
          opens++;
      }
    PASS([t state] == PlayerPlaybackStopped && [[m playlist] currentIndex] == 1 && opens == 0,
         "an end arriving after the pause stops on the next item without playing it");

    m = playing();
    [m handle: PlayerEventSelectIndex(2)];
    media(m, PlayerEventOpened);
    command(m, PlayerEventPause);
    media(m, PlayerEventEnded);
    PASS([m state] == PlayerPlaybackStopped && [[m playlist] currentIndex] == 0,
         "after the last item that is the first");

    m = playing();
    command(m, PlayerEventPause);
    t = command(m, PlayerEventStop);
    PASS([t state] == PlayerPlaybackStopped && [t hasEffect: PlayerEffectFadeOutClose],
         "stop while paused closes (what is still fading out fades on)");

    m = playing();
    command(m, PlayerEventPause);
    t = command(m, PlayerEventNext);
    PASS([t state] == PlayerPlaybackOpening && ![[t effectOfType: PlayerEffectOpen] flag],
         "next while paused opens the next track, with nothing to cross-fade");
  END_SET("Paused")

  START_SET("which failures ask for an alert")
    PlayerPlaybackMachine *m = [[PlayerPlaybackMachine new] autorelease];
    PlayerEvent open = PlayerEventWithItems(PlayerEventOpen, tracks());
    open.flag = YES;
    [m handle: open];
    PlayerTransition *t = [m handle: PlayerEventFailure([m generation], failure())];
    PASS([[t effectOfType: PlayerEffectReportFailure] flag],
         "the first failure of what the user opened asks for the alert");
    t = [m handle: PlayerEventFailure([m generation], failure())];
    PASS([t hasEffect: PlayerEffectReportFailure] && ![[t effectOfType: PlayerEffectReportFailure] flag],
         "one alert per opening: the next broken item only shows in the window");
    media(m, PlayerEventOpened);
    t = [m handle: PlayerEventFailure([m generation], failure())];
    PASS(![[t effectOfType: PlayerEffectReportFailure] flag], "as does one breaking off later");

    m = [[PlayerPlaybackMachine new] autorelease];
    [m handle: PlayerEventWithItems(PlayerEventOpen, tracks())];
    t = [m handle: PlayerEventFailure([m generation], failure())];
    PASS(![[t effectOfType: PlayerEffectReportFailure] flag],
         "a list not opened by the user asks for no alert");

    m = [[PlayerPlaybackMachine new] autorelease];
    [m handle: open];
    media(m, PlayerEventOpened);
    [m handle: PlayerEventSelectIndex(2)];
    t = [m handle: PlayerEventFailure([m generation], failure())];
    PASS(![[t effectOfType: PlayerEffectReportFailure] flag],
         "an item chosen in the playlist that fails is shown inline only");

    m = [[PlayerPlaybackMachine new] autorelease];
    PlayerEvent add = PlayerEventWithItems(PlayerEventAdd, tracks());
    add.flag = YES;
    [m handle: add];
    t = [m handle: PlayerEventFailure([m generation], failure())];
    PASS([[t effectOfType: PlayerEffectReportFailure] flag], "files dropped by the user do");
  END_SET("which failures ask for an alert")

  START_SET("Stopped")
    PlayerPlaybackMachine *m = playing();
    command(m, PlayerEventStop);
    PASS(ignoredInState(m, PlayerEventMake(PlayerEventPause), PlayerPlaybackStopped)
         && ignoredInState(m, PlayerEventMake(PlayerEventStop), PlayerPlaybackStopped),
         "pause and stop do nothing when stopped");
    PlayerTransition *t = [m handle: PlayerEventSeekTo(25, 0)];
    PASS([t handled] && [m state] == PlayerPlaybackStopped && [m pendingSeek] == 25,
         "a seek when stopped is kept for when it plays");
    t = command(m, PlayerEventPlay);
    PASS([t state] == PlayerPlaybackOpening && [[t effectOfType: PlayerEffectOpen] index] == 0,
         "play opens the chosen item");
    t = media(m, PlayerEventOpened);
    PASS([[t effectOfType: PlayerEffectSeek] time] == 25, "starting where it was sought to");

    m = playing();
    command(m, PlayerEventStop);
    [m handle: PlayerEventSeekTo(25, 0)];
    command(m, PlayerEventNext);
    PASS([m pendingSeek] < 0, "a seek belongs to the item it was asked for on");

    m = playing();
    [m handle: PlayerEventFailure([m generation], failure())];
    [m handle: PlayerEventSelectIndex(2)];
    [m handle: PlayerEventFailure([m generation], failure())];
    PASS([m state] == PlayerPlaybackStopped && [m lastError] != nil, "stopped with an error");
    command(m, PlayerEventPlay);
    PASS([m lastError] == nil, "play clears the error");

    m = playing();
    command(m, PlayerEventStop);
    t = [m handle: PlayerEventPreviousAt(0)];
    PASS([[t effectOfType: PlayerEffectOpen] index] == 0,
         "previous at the first item restarts it");
    command(m, PlayerEventStop);
    t = [m handle: PlayerEventSelectIndex(1)];
    PASS([[t effectOfType: PlayerEffectOpen] index] == 1, "an item can be chosen");
    command(m, PlayerEventStop);
    t = command(m, PlayerEventClear);
    PASS([t state] == PlayerPlaybackEmpty && [[m playlist] count] == 0, "clear empties it");

    m = [[PlayerPlaybackMachine new] autorelease];
    t = [m handle: PlayerEventLoadItems(tracks(), 1, 42)];
    PASS([t state] == PlayerPlaybackStopped && [[m playlist] currentIndex] == 1
         && [m pendingSeek] == 42 && ![t hasEffect: PlayerEffectOpen],
         "a remembered list comes back stopped, its item chosen, its position pending");
  END_SET("Stopped")

  [arp release];
  return 0;
}
