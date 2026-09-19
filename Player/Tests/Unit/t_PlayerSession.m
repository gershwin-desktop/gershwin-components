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
  BOOL slow;          /* playURL: stays connecting until -finishConnecting */
  BOOL connecting;
  float gain;         /* fade gain and the last fade asked for */
  float fadeTarget;
  NSTimeInterval fadeDuration;
  int closes;
}
- (void)finishTrack;
- (void)finishConnecting;
- (void)failWhilePlaying;
@end

@implementation FakeMedia
- (id)init
{
  self = [super init];
  unopenable = [NSMutableSet new];
  length = 100;
  gain = 1.0f;
  return self;
}
- (void)setDelegate:(id<StreamPlayerDelegate>)d { delegate = d; }
- (id<StreamPlayerDelegate>)delegate { return delegate; }
/* Like StreamPlayer, reports the outcome through the delegate; a fast
 * fake reports before returning, which the session must cope with too. */
- (void)playURL:(NSString *)url
{
  [self close];
  if ([unopenable containsObject: url])
    {
      [delegate streamPlayer: (StreamPlayer *)self didFailWithError:
        [NSError errorWithDomain: @"Fake" code: 1
                        userInfo: @{NSLocalizedDescriptionKey: @"broken"}]];
      return;
    }
  ASSIGN(openedURL, url);
  opens++;
  if (slow)
    {
      connecting = YES;
      return;
    }
  playing = YES;
  [delegate streamPlayerDidStartPlaying: (StreamPlayer *)self];
}
- (BOOL)isConnecting { return connecting; }
- (void)finishConnecting
{
  connecting = NO;
  playing = YES;
  [delegate streamPlayerDidStartPlaying: (StreamPlayer *)self];
}
- (void)failWhilePlaying
{
  playing = NO;
  [delegate streamPlayer: (StreamPlayer *)self didFailWithError:
    [NSError errorWithDomain: @"Fake" code: 2
                    userInfo: @{NSLocalizedDescriptionKey: @"connection lost"}]];
}
- (void)play { if (openedURL) { playing = YES; paused = NO; } }
- (void)pause { if (playing) paused = YES; }
- (void)stop { playing = NO; paused = NO; }
- (void)close { [self stop]; connecting = NO; DESTROY(openedURL); position = 0; closes++; }
- (float)fadeGain { return gain; }
- (void)setFadeGain:(float)g { gain = g; fadeTarget = g; fadeDuration = 0; }
- (void)fadeToGain:(float)g duration:(NSTimeInterval)d { fadeTarget = g; fadeDuration = d; if (d == 0) gain = g; }
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
    [s setFadeDuration: 0];
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

  START_SET("streams that take time to connect")
    FakeMedia *m = [[FakeMedia new] autorelease];
    SessionWatcher *w = [[SessionWatcher new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: m] autorelease];
    [s setDelegate: w];
    m->slow = YES;
    [s openItems: @[@"http://radio.example/live"]];
    PASS([s isConnecting], "the session says it is connecting");
    PASS([s state] == PlayerSessionPlaying, "playback is under way");
    PASS([s canStop], "the attempt can be stopped");
    int changes = w->stateChanges;
    [m finishConnecting];
    PASS(![s isConnecting], "once the stream plays it is no longer connecting");
    PASS(w->stateChanges > changes, "and the change is reported");

    [s openItems: @[@"http://radio.example/other"]];
    PASS([s isConnecting], "connecting again for the next stream");
    [s stop];
    PASS(![s isConnecting] && !m->connecting && [s state] == PlayerSessionStopped,
         "stop gives up the attempt");

    m->slow = NO;
    [s openItems: @[@"http://radio.example/live"]];
    [m failWhilePlaying];
    PASS([w->failures count] == 1, "a stream that breaks off is reported");
    PASS([s state] == PlayerSessionStopped, "and playback stops when nothing follows");

    [w->failures removeAllObjects];
    [s openItems: tracks()];
    [m failWhilePlaying];
    PASS([w->failures count] == 1, "a broken track in a list is reported");
    PASS_EQUAL(m->openedURL, @"/music/2.mp3", "and the next track follows");
  END_SET("streams that take time to connect")

  START_SET("streams fade in and out")
    FakeMedia *m = [[FakeMedia new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: m] autorelease];
    m->slow = YES;
    [s openItems: @[@"http://radio.example/live"]];
    PASS(m->gain == 0.0f, "a stream starts silent");
    [m finishConnecting];
    PASS(m->fadeTarget == 1.0f && m->fadeDuration > 0.5,
         "and fades in once it plays");

    int closes = m->closes;
    [s stop];
    PASS([s state] == PlayerSessionStopped, "stop takes effect at once");
    PASS(m->fadeTarget == 0.0f && m->fadeDuration > 0.5, "the stream fades out");
    PASS(m->closes == closes, "and is not cut off");
    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 1.3]];
    PASS(m->closes == closes + 1, "it is closed once faded out");

    [s openItems: @[@"http://radio.example/live"]];
    [m finishConnecting];
    [s stop];
    [s openItems: @[@"http://radio.example/other"]];
    [m finishConnecting];
    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 1.3]];
    PASS([s state] == PlayerSessionPlaying && m->openedURL != nil,
         "playing again during the fade is not cut off by the pending close");

    m->slow = NO;
    [s openItems: tracks()];
    PASS(m->gain == 1.0f && m->fadeDuration == 0,
         "local files start at full volume, without a ramp");
  END_SET("streams fade in and out")

  START_SET("pause, stop and play fade")
    FakeMedia *m = [[FakeMedia new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: m] autorelease];
    [s openItems: tracks()];
    m->position = 42;
    [s togglePlayPause];
    PASS([s state] == PlayerSessionPaused, "pause takes effect at once");
    PASS(m->fadeTarget == 0.0f && m->fadeDuration > 0.5, "the track fades out");
    PASS(!m->paused, "and is not cut off");
    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 1.3]];
    PASS(m->paused, "it pauses once faded out");

    [s togglePlayPause];
    PASS([s state] == PlayerSessionPlaying && !m->paused, "play resumes");
    PASS(m->fadeTarget == 1.0f && m->fadeDuration > 0.5, "fading in");

    [s togglePlayPause];
    [s togglePlayPause];
    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 1.3]];
    PASS(!m->paused && m->fadeTarget == 1.0f,
         "resuming during the fade-out is not paused by it later");

    int closes = m->closes;
    [s stop];
    PASS([s state] == PlayerSessionStopped, "stop takes effect at once");
    PASS(m->fadeTarget == 0.0f && m->fadeDuration > 0.5, "the track fades out");
    PASS(m->closes == closes, "and is not cut off");
    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 1.3]];
    PASS(m->closes == closes + 1, "it is closed once faded out");

    [s togglePlayPause];
    PASS(m->gain == 1.0f && m->fadeDuration == 0,
         "play after stop starts the track without a ramp");

    m->position = 0;
    [s togglePlayPause];
    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 1.3]];
    [s togglePlayPause];
    PASS(m->gain == 1.0f && m->fadeDuration == 0,
         "resuming at the very start of a track has no ramp either");

    [s setFadeDuration: 0];
    [s togglePlayPause];
    PASS(m->paused, "with fading off pause is immediate");
    [s togglePlayPause];
    PASS(m->gain == 1.0f, "and so is resuming");
    closes = m->closes;
    [s stop];
    PASS(m->closes == closes + 1, "and stop");
  END_SET("pause, stop and play fade")

  START_SET("tracks cross-fade")
    NSMutableArray *made = [NSMutableArray array];
    FakeMedia *first = [[FakeMedia new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: first] autorelease];
    [s setMediaFactory: ^id<MediaPlayback>(void) {
      FakeMedia *m = [[FakeMedia new] autorelease];
      [made addObject: m];
      return m;
    }];
    [s openItems: tracks()];
    PASS(first->gain == 1.0f, "the first track starts at full volume");

    [s next];
    PASS([made count] == 1, "the next track gets a player of its own");
    FakeMedia *second = [made lastObject];
    PASS_EQUAL(second->openedURL, @"/music/2.mp3", "and plays the next track");
    PASS(first->fadeTarget == 0.0f && first->fadeDuration > 0.5,
         "the old track fades out");
    PASS(first->openedURL != nil, "without being cut off");
    PASS(second->gain == 1.0f && second->fadeDuration == 0,
         "while the new one starts at full volume, as every track start does");
    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 1.3]];
    PASS(first->openedURL == nil, "the old track is closed once faded out");

    /* Near its end a track hands over to the next one early */
    second->position = second->length - 0.5;
    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.5]];
    PASS([made count] == 2, "the next track starts before the old one ends");
    FakeMedia *third = [made lastObject];
    PASS_EQUAL(third->openedURL, @"/music/3.mp3", "it is the next track");
    PASS(second->fadeTarget == 0.0f, "the ending track fades out");
    PASS([[s playlist] currentIndex] == 2, "the playlist moves on");

    /* Paused: nothing is audible to fade */
    [s togglePlayPause];
    [s previous];
    PASS([made count] == 2, "from pause the track changes without a second player");

    [s stop];
    [s setFadeDuration: 0];
    [s openItems: tracks()];
    NSUInteger count = [made count];
    [s next];
    PASS([made count] == count, "with fading off tracks change at once");
  END_SET("tracks cross-fade")

  START_SET("fading switched off")
    FakeMedia *m = [[FakeMedia new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: m] autorelease];
    PASS([s fadeDuration] > 0.5, "streams fade by default");
    [s setFadeDuration: 0];
    m->slow = YES;
    [s openItems: @[@"http://radio.example/live"]];
    PASS(m->gain == 1.0f, "a stream starts at full volume");
    [m finishConnecting];
    PASS(m->gain == 1.0f, "and stays there");
    int closes = m->closes;
    [s stop];
    PASS(m->closes == closes + 1, "stop cuts it off at once");
  END_SET("fading switched off")

  [arp release];
  return 0;
}
