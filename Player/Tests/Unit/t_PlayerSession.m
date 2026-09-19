/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_PlayerSession.m - what Play/Pause, Stop, Next, Previous, seeking and the
 * end of a track do to playback.  Uses a fake media player, so it is fast
 * and headless; t_PlayerSessionMedia covers the real one. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "PlayerPlaylist.h"
#include "../../PlayerSession.m"

/* Records what the session asks of the media player. */
@interface FakeMedia : NSObject <MediaPlayback>
{
@public
  id<StreamPlayerDelegate> delegate;
  NSString *openedURL;
  NSMutableSet *unopenable;
  BOOL playing;
  BOOL paused;
  NSTimeInterval position;
  NSTimeInterval length;
  float volume;
  BOOL muted;
  int opens;
}
- (void)finishTrack;
@end

@implementation FakeMedia
- (id)init
{
  self = [super init];
  unopenable = [NSMutableSet new];
  length = 100;
  return self;
}
- (void)setDelegate:(id<StreamPlayerDelegate>)d { delegate = d; }
- (id<StreamPlayerDelegate>)delegate { return delegate; }
- (BOOL)openURL:(NSString *)url error:(NSError **)error
{
  [self close];
  if ([unopenable containsObject: url])
    {
      if (error) *error = [NSError errorWithDomain: @"Fake" code: 1
        userInfo: @{NSLocalizedDescriptionKey: @"broken"}];
      return NO;
    }
  ASSIGN(openedURL, url);
  opens++;
  return YES;
}
- (void)play { if (openedURL) { playing = YES; paused = NO; } }
- (void)pause { if (playing) paused = YES; }
- (void)stop { playing = NO; paused = NO; }
- (void)close { [self stop]; DESTROY(openedURL); position = 0; }
- (void)seekToTime:(NSTimeInterval)t { position = t; }
- (NSTimeInterval)currentTime { return position; }
- (NSTimeInterval)duration { return openedURL ? length : 0; }
- (BOOL)isPlaying { return playing; }
- (BOOL)hasVideo { return NO; }
- (float)volume { return volume; }
- (void)setVolume:(float)v { volume = v; }
- (BOOL)muted { return muted; }
- (void)setMuted:(BOOL)m { muted = m; }
- (void)finishTrack
{
  playing = NO;
  position = length;
  [delegate streamPlayerDidStop: (StreamPlayer *)self];
}
@end

/* Counts the session's notifications. */
@interface SessionWatcher : NSObject <PlayerSessionDelegate>
{
@public
  int stateChanges;
  int trackChanges;
  NSMutableArray *failures;
}
@end

@implementation SessionWatcher
- (id)init { self = [super init]; failures = [NSMutableArray new]; return self; }
- (void)playerSessionDidChangeState:(PlayerSession *)s { stateChanges++; }
- (void)playerSessionDidChangeTrack:(PlayerSession *)s { trackChanges++; }
- (void)playerSession:(PlayerSession *)s didFailToOpenItem:(NSString *)item error:(NSError *)e
{
  [failures addObject: item];
}
@end

static NSArray *tracks(void)
{
  return @[@"/music/1.mp3", @"/music/2.mp3", @"/music/3.mp3"];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("nothing loaded")
    FakeMedia *m = [[FakeMedia new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: m] autorelease];
    PASS([m delegate] == (id)s, "the session listens to its media player");
    PASS([s state] == PlayerSessionStopped, "starts stopped");
    PASS(![s canPlay] && ![s canStop] && ![s canGoNext] && ![s canGoPrevious]
         && ![s canSeek], "no transport control makes sense");
    [s togglePlayPause];
    PASS([s state] == PlayerSessionStopped && m->opens == 0,
         "play without anything loaded does nothing");
  END_SET("nothing loaded")

  START_SET("opening files")
    FakeMedia *m = [[FakeMedia new] autorelease];
    SessionWatcher *w = [[SessionWatcher new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: m] autorelease];
    [s setDelegate: w];
    [s openItems: tracks()];
    PASS([[s playlist] count] == 3, "all files are in the playlist");
    PASS([s state] == PlayerSessionPlaying, "the first file plays");
    PASS_EQUAL(m->openedURL, @"/music/1.mp3", "the first file is the one opened");
    PASS(m->opens == 1, "opened exactly once");
    PASS(w->trackChanges == 1, "one track change is reported");
    PASS([s canStop] && [s canGoNext] && [s canGoPrevious] && [s canSeek],
         "transport controls are available");

    [s openItems: @[@"/music/other.mp3"]];
    PASS([[s playlist] count] == 1, "opening again replaces the playlist");
    PASS_EQUAL(m->openedURL, @"/music/other.mp3", "and plays the new file");
    PASS(![s canGoNext], "a single file has nothing after it");

    [s addItems: @[@"/music/1.mp3", @"/music/2.mp3"]];
    PASS([[s playlist] count] == 3, "adding appends to the playlist");
    PASS_EQUAL(m->openedURL, @"/music/other.mp3",
               "adding does not interrupt the playing track");
  END_SET("opening files")

  START_SET("adding while stopped starts playback")
    FakeMedia *m = [[FakeMedia new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: m] autorelease];
    [s addItems: tracks()];
    PASS([s state] == PlayerSessionPlaying, "dropping files on an idle player plays them");
    PASS_EQUAL(m->openedURL, @"/music/1.mp3", "starting with the first");
  END_SET("adding while stopped starts playback")

  START_SET("play, pause, stop")
    FakeMedia *m = [[FakeMedia new] autorelease];
    SessionWatcher *w = [[SessionWatcher new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: m] autorelease];
    [s setDelegate: w];
    [s openItems: tracks()];
    int changes = w->stateChanges;
    m->position = 42;
    [s togglePlayPause];
    PASS([s state] == PlayerSessionPaused && m->paused, "play/pause pauses");
    PASS(w->stateChanges == changes + 1, "the pause is reported");
    [s togglePlayPause];
    PASS([s state] == PlayerSessionPlaying && !m->paused, "and resumes");
    PASS(m->position == 42 && m->opens == 1, "resuming keeps the position");

    [s stop];
    PASS([s state] == PlayerSessionStopped && !m->playing, "stop stops");
    PASS([s currentTime] == 0, "stop goes back to the start");
    PASS([[s playlist] currentIndex] == 0, "the track stays selected");
    PASS(![s canStop] && ![s canSeek], "stop and seeking are off while stopped");
    PASS([s canPlay], "play is available");
    [s togglePlayPause];
    PASS([s state] == PlayerSessionPlaying, "play after stop plays again");
    PASS_EQUAL(m->openedURL, @"/music/1.mp3", "the same track");
  END_SET("play, pause, stop")

  START_SET("next and previous")
    FakeMedia *m = [[FakeMedia new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: m] autorelease];
    [s openItems: tracks()];
    [s next];
    PASS_EQUAL(m->openedURL, @"/music/2.mp3", "next plays the second track");
    [s togglePlayPause];
    [s next];
    PASS_EQUAL(m->openedURL, @"/music/3.mp3", "next from pause goes on too");
    PASS([s state] == PlayerSessionPlaying, "and plays it");
    PASS(![s canGoNext], "no next after the last track");
    [s next];
    PASS_EQUAL(m->openedURL, @"/music/3.mp3", "next at the end changes nothing");

    m->position = 10;
    [s previous];
    PASS_EQUAL(m->openedURL, @"/music/3.mp3",
               "previous a while into a track restarts it");
    PASS(m->position == 0, "from the start");
    m->position = 1;
    [s previous];
    PASS_EQUAL(m->openedURL, @"/music/2.mp3",
               "previous right at the start goes to the track before");
    [s previous];
    [s previous];
    PASS_EQUAL(m->openedURL, @"/music/1.mp3", "the first track stays at the start");
    PASS(m->position == 0, "restarted");

    [[s playlist] setRepeat: YES];
    [s previous];
    PASS_EQUAL(m->openedURL, @"/music/3.mp3", "with repeat previous wraps to the last");
    PASS([s canGoNext], "with repeat there is always a next track");
  END_SET("next and previous")

  START_SET("end of a track")
    FakeMedia *m = [[FakeMedia new] autorelease];
    SessionWatcher *w = [[SessionWatcher new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: m] autorelease];
    [s setDelegate: w];
    [s openItems: tracks()];
    [m finishTrack];
    PASS_EQUAL(m->openedURL, @"/music/2.mp3", "the next track follows");
    PASS([s state] == PlayerSessionPlaying, "and plays");
    [m finishTrack];
    [m finishTrack];
    PASS([s state] == PlayerSessionStopped, "after the last track playback stops");
    PASS([[s playlist] currentIndex] == 0,
         "and the first track is ready to play the list again");
    PASS([s currentTime] == 0, "from its start");

    [[s playlist] setRepeat: YES];
    [s togglePlayPause];
    [s next];
    [s next];
    [m finishTrack];
    PASS_EQUAL(m->openedURL, @"/music/1.mp3", "with repeat the list starts over");
    PASS([s state] == PlayerSessionPlaying, "and keeps playing");
  END_SET("end of a track")

  START_SET("files that cannot be played")
    FakeMedia *m = [[FakeMedia new] autorelease];
    SessionWatcher *w = [[SessionWatcher new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: m] autorelease];
    [s setDelegate: w];
    [m->unopenable addObject: @"/music/2.mp3"];
    [s openItems: tracks()];
    [m finishTrack];
    PASS_EQUAL(m->openedURL, @"/music/3.mp3", "a broken file is skipped");
    PASS([w->failures count] == 1, "and reported once");
    PASS([s state] == PlayerSessionPlaying, "playback goes on");

    [m->unopenable addObject: @"/music/bad.mp3"];
    [s openItems: @[@"/music/bad.mp3"]];
    PASS([s state] == PlayerSessionStopped, "a single broken file leaves the player stopped");
    PASS([w->failures count] == 2, "and is reported");
  END_SET("files that cannot be played")

  START_SET("seeking, volume and mute")
    FakeMedia *m = [[FakeMedia new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: m] autorelease];
    [s setVolume: 0.3];
    [s setMuted: YES];
    [s openItems: tracks()];
    PASS(fabs(m->volume - 0.3) < 0.001 && m->muted,
         "volume and mute set before playing apply to the player");
    [s seekToTime: 30];
    PASS(m->position == 30, "seeking moves the player");
    [s skipBy: 5];
    PASS(m->position == 35, "skipping forward");
    [s skipBy: -60];
    PASS(m->position == 0, "skipping back stops at the start");
    [s skipBy: 500];
    PASS(m->position == 100, "skipping forward stops at the end");
    PASS([s duration] == 100, "the duration is the player's");
    [s setMuted: NO];
    PASS(!m->muted, "unmuting reaches the player");
  END_SET("seeking, volume and mute")

  START_SET("picking a track")
    FakeMedia *m = [[FakeMedia new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: m] autorelease];
    [s openItems: tracks()];
    PASS([s playItemAtIndex: 2], "a track can be picked");
    PASS_EQUAL(m->openedURL, @"/music/3.mp3", "and plays");
    int opens = m->opens;
    [s playItemAtIndex: 2];
    PASS(m->opens == opens, "picking the playing track does not restart it");
    PASS(![s playItemAtIndex: 7], "a track that is not there cannot be picked");
  END_SET("picking a track")

  [arp release];
  return 0;
}
