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
/* A ramp is taken as already on its way: the gain counts as its target,
 * so a fade towards silence is not audible any more for what follows */
- (void)fadeToGain:(float)g duration:(NSTimeInterval)d { fadeTarget = g; fadeDuration = d; gain = g; }
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
  NSMutableArray *alerts;     /* whether each failure asked for the alert */
}
@end

@implementation SessionWatcher
- (id)init { self = [super init]; failures = [NSMutableArray new]; alerts = [NSMutableArray new]; return self; }
- (void)playerSessionDidChangeState:(PlayerSession *)s { stateChanges++; }
- (void)playerSessionDidChangeTrack:(PlayerSession *)s { trackChanges++; }
- (void)playerSession:(PlayerSession *)s didFailToOpenItem:(NSString *)item error:(NSError *)e
           userOpened:(BOOL)userOpened
{
  [failures addObject: item];
  [alerts addObject: [NSNumber numberWithBool: userOpened]];
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
    PASS([s state] == PlayerPlaybackEmpty, "starts empty");
    PASS(![s canPlay] && ![s canStop] && ![s canGoNext] && ![s canGoPrevious]
         && ![s canSeek], "no transport control makes sense");
    [s togglePlayPause];
    PASS([s state] == PlayerPlaybackEmpty && m->opens == 0,
         "play without anything loaded does nothing");
    [s stop];
    [s next];
    [s previous];
    PASS([s state] == PlayerPlaybackEmpty && m->opens == 0,
         "and so do stop, next and previous");
  END_SET("nothing loaded")

  START_SET("opening files")
    FakeMedia *m = [[FakeMedia new] autorelease];
    SessionWatcher *w = [[SessionWatcher new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: m] autorelease];
    [s setDelegate: w];
    [s openItems: tracks()];
    PASS([[s playlist] count] == 3, "all files are in the playlist");
    PASS([s state] == PlayerPlaybackPlaying, "the first file plays");
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
    PASS([s state] == PlayerPlaybackPlaying, "dropping files on an idle player plays them");
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
    PASS([s state] == PlayerPlaybackPaused && m->paused, "play/pause pauses");
    PASS(w->stateChanges == changes + 1, "the pause is reported");
    [s togglePlayPause];
    PASS([s state] == PlayerPlaybackPlaying && !m->paused, "and resumes");
    PASS(m->position == 42 && m->opens == 1, "resuming keeps the position");

    [s stop];
    PASS([s state] == PlayerPlaybackStopped && !m->playing, "stop stops");
    PASS([[s playlist] count] == 3, "stopped, unlike empty, still has its list");
    PASS([s currentTime] == 0, "stop goes back to the start");
    PASS([[s playlist] currentIndex] == 0, "the track stays selected");
    PASS(![s canStop] && ![s canSeek], "stop and seeking are off while stopped");
    PASS([s canPlay], "play is available");
    [s togglePlayPause];
    PASS([s state] == PlayerPlaybackPlaying, "play after stop plays again");
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
    PASS([s state] == PlayerPlaybackPlaying, "and plays it");
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
    PASS([s state] == PlayerPlaybackPlaying, "and plays");
    [m finishTrack];
    [m finishTrack];
    PASS([s state] == PlayerPlaybackStopped, "after the last track playback stops");
    PASS([[s playlist] currentIndex] == 0,
         "and the first track is ready to play the list again");
    PASS([s currentTime] == 0, "from its start");

    [[s playlist] setRepeat: YES];
    [s togglePlayPause];
    [s next];
    [s next];
    [m finishTrack];
    PASS_EQUAL(m->openedURL, @"/music/1.mp3", "with repeat the list starts over");
    PASS([s state] == PlayerPlaybackPlaying, "and keeps playing");
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
    PASS(![[w->alerts lastObject] boolValue],
         "reaching it in the list asks for no alert, only the window shows it");
    PASS([s state] == PlayerPlaybackPlaying, "playback goes on");

    [m->unopenable addObject: @"/music/bad.mp3"];
    [s openItems: @[@"/music/bad.mp3"]];
    PASS([s state] == PlayerPlaybackStopped, "a single broken file leaves the player stopped");
    PASS([w->failures count] == 2, "and is reported");
    PASS([[w->alerts lastObject] boolValue], "with the alert, as the user opened it");
    PASS([[[s lastError] localizedDescription] isEqual: @"broken"], "the error is kept");
    [s playItemAtIndex: 0];
    PASS(![[w->alerts lastObject] boolValue] && [w->failures count] == 3,
         "choosing it again in the playlist shows the failure in the window only");
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
    PASS([s state] == PlayerPlaybackOpening,
         "opening is a state of its own, not playing yet");
    PASS([s canStop], "the attempt can be stopped");
    PASS([s currentTime] == 0 && [s duration] == 0 && ![s canSeek],
         "nothing is open yet that could have a position or be sought");
    int changes = w->stateChanges;
    [m finishConnecting];
    PASS(![s isConnecting], "once the stream plays it is no longer connecting");
    PASS([s state] == PlayerPlaybackPlaying, "and it plays");
    PASS(w->stateChanges > changes, "and the change is reported");

    [s openItems: @[@"http://radio.example/other"]];
    PASS([s isConnecting], "connecting again for the next stream");
    [s stop];
    PASS(![s isConnecting] && !m->connecting && [s state] == PlayerPlaybackStopped,
         "stop gives up the attempt");

    m->slow = NO;
    [s openItems: @[@"http://radio.example/live"]];
    [m failWhilePlaying];
    PASS([w->failures count] == 1, "a stream that breaks off is reported");
    PASS([s state] == PlayerPlaybackStopped, "and playback stops when nothing follows");

    [w->failures removeAllObjects];
    [s openItems: tracks()];
    [m failWhilePlaying];
    PASS([w->failures count] == 1, "a broken track in a list is reported");
    PASS_EQUAL(m->openedURL, @"/music/2.mp3", "and the next track follows");
  END_SET("streams that take time to connect")

  START_SET("pause and seek while opening")
    FakeMedia *m = [[FakeMedia new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: m] autorelease];
    [s setFadeDuration: 0];
    m->slow = YES;
    [s openItems: tracks()];
    PASS([s state] == PlayerPlaybackOpening, "a slow item is opening");
    [s seekToTime: 30];
    PASS(m->position == 0, "a seek while opening does not reach the player yet");
    [s togglePlayPause];
    PASS([s state] == PlayerPlaybackOpening, "pause while opening keeps opening");
    PASS([s isPausePending], "and remembers the pause");
    PASS(m->opens == 1 && m->connecting, "the attempt goes on");
    [m finishConnecting];
    PASS([s state] == PlayerPlaybackPaused, "once open it lands paused");
    PASS(m->paused, "the player is paused");
    PASS(m->position == 30, "at the position asked for while opening");
    PASS(![s isPausePending], "nothing is pending any more");
    [s togglePlayPause];
    PASS([s state] == PlayerPlaybackPlaying && !m->paused, "play resumes");

    [s next];
    [s togglePlayPause];
    [s togglePlayPause];
    PASS(![s isPausePending], "pressing play again while opening forgets the pause");
    [m finishConnecting];
    PASS([s state] == PlayerPlaybackPlaying && !m->paused, "and it plays once open");

    [s next];
    [s seekToTime: 20];
    [s togglePlayPause];
    [s previous];
    PASS_EQUAL(m->openedURL, @"/music/2.mp3", "previous while opening opens the item before");
    PASS(![s isPausePending], "choosing another item drops the pending pause");
    [m finishConnecting];
    PASS([s state] == PlayerPlaybackPlaying && m->position == 0,
         "and the pending seek, which belonged to the item given up");

    [s next];
    [s togglePlayPause];
    [s stop];
    PASS([s state] == PlayerPlaybackStopped && !m->connecting && ![s isPausePending],
         "stop while opening gives up the attempt and what was pending");
  END_SET("pause and seek while opening")

  START_SET("seeking while stopped")
    FakeMedia *m = [[FakeMedia new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: m] autorelease];
    [s setFadeDuration: 0];
    [s openItems: tracks()];
    [s stop];
    [s seekToTime: 25];
    PASS([s state] == PlayerPlaybackStopped && m->opens == 1,
         "seeking while stopped opens nothing");
    [s togglePlayPause];
    PASS([s state] == PlayerPlaybackPlaying && m->position == 25,
         "play starts where it was sought to");
  END_SET("seeking while stopped")

  START_SET("the end of a track racing a pause")
    FakeMedia *m = [[FakeMedia new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: m] autorelease];
    [s openItems: tracks()];
    /* The playback thread reached the end and no longer plays, but its
     * message saying so is still on its way to the main thread */
    m->playing = NO;
    [s togglePlayPause];
    PASS([s state] == PlayerPlaybackPaused, "a pause in that moment is taken");
    int opens = m->opens;
    [m finishTrack];
    PASS([s state] == PlayerPlaybackStopped,
         "the late end leaves the player stopped, not paused at the end");
    PASS([[s playlist] currentIndex] == 1, "on the next track");
    PASS(m->opens == opens, "without playing it behind the user's back");
  END_SET("the end of a track racing a pause")

  START_SET("a fade belongs to the state that started it")
    FakeMedia *m = [[FakeMedia new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: m] autorelease];
    [s openItems: tracks()];
    m->position = 42;
    [s togglePlayPause];
    [s seekToTime: 10];
    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 1.3]];
    PASS(m->paused && m->position == 10,
         "a seek while the pause fades out moves the position and keeps the pause");
    [s togglePlayPause];
    [s togglePlayPause];
    [s togglePlayPause];
    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 1.3]];
    PASS([s state] == PlayerPlaybackPlaying && !m->paused,
         "no pause of an earlier state comes in after playing again");
    int closes = m->closes;
    [s stop];
    [s next];
    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 1.3]];
    PASS([s state] == PlayerPlaybackPlaying && m->openedURL != nil && m->closes == closes + 1,
         "the close after stop's fade is void once the next track plays");
  END_SET("a fade belongs to the state that started it")

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
    PASS([s state] == PlayerPlaybackStopped, "stop takes effect at once");
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
    PASS([s state] == PlayerPlaybackPlaying && m->openedURL != nil,
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
    PASS([s state] == PlayerPlaybackPaused, "pause takes effect at once");
    PASS(m->fadeTarget == 0.0f && m->fadeDuration > 0.5, "the track fades out");
    PASS(!m->paused, "and is not cut off");
    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 1.3]];
    PASS(m->paused, "it pauses once faded out");

    [s togglePlayPause];
    PASS([s state] == PlayerPlaybackPlaying && !m->paused, "play resumes");
    PASS(m->fadeTarget == 1.0f && m->fadeDuration > 0.5, "fading in");

    [s togglePlayPause];
    [s togglePlayPause];
    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 1.3]];
    PASS(!m->paused && m->fadeTarget == 1.0f,
         "resuming during the fade-out is not paused by it later");

    int closes = m->closes;
    [s stop];
    PASS([s state] == PlayerPlaybackStopped, "stop takes effect at once");
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

  START_SET("the list is remembered")
    FakeMedia *m = [[FakeMedia new] autorelease];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: m] autorelease];
    [s setFadeDuration: 0];
    [s openItems: tracks()];
    [s next];
    m->position = 42;
    NSDictionary *playing = [s stateToRemember];
    PASS([NSPropertyListSerialization dataWithPropertyList: playing
                                                    format: NSPropertyListXMLFormat_v1_0
                                                   options: 0
                                                     error: NULL] != nil,
         "the state can be kept in the defaults");

    FakeMedia *m2 = [[FakeMedia new] autorelease];
    PlayerSession *s2 = [[[PlayerSession alloc] initWithMedia: m2] autorelease];
    [s2 setFadeDuration: 0];
    [s2 restoreState: playing];
    PASS([[[s2 playlist] items] isEqual: tracks()], "the list comes back");
    PASS([[s2 playlist] currentIndex] == 1, "with the same track current");
    PASS([s2 state] == PlayerPlaybackPlaying && [m2->openedURL isEqual: @"/music/2.mp3"],
         "playing again, as it played when it was kept");
    PASS(m2->position == 42, "from where it was");

    [s togglePlayPause];
    NSDictionary *paused = [s stateToRemember];
    FakeMedia *m3 = [[FakeMedia new] autorelease];
    PlayerSession *s3 = [[[PlayerSession alloc] initWithMedia: m3] autorelease];
    [s3 setFadeDuration: 0];
    [s3 restoreState: paused];
    PASS([s3 state] == PlayerPlaybackStopped && m3->opens == 0,
         "a paused track comes back without playing");
    PASS([[s3 playlist] currentIndex] == 1, "but chosen");
    [s3 togglePlayPause];
    PASS([m3->openedURL isEqual: @"/music/2.mp3"] && m3->position == 42,
         "and Play continues where it was paused");
    [s3 next];
    [s3 previous];
    PASS([m3->openedURL isEqual: @"/music/2.mp3"] && m3->position == 0,
         "going back to it later starts it at its beginning, like any track");

    [s stop];
    FakeMedia *m4 = [[FakeMedia new] autorelease];
    PlayerSession *s4 = [[[PlayerSession alloc] initWithMedia: m4] autorelease];
    [s4 restoreState: [s stateToRemember]];
    [s4 togglePlayPause];
    PASS([m4->openedURL isEqual: @"/music/2.mp3"] && m4->position == 0,
         "a stopped track plays from its beginning");

    FakeMedia *m5 = [[FakeMedia new] autorelease];
    PlayerSession *s5 = [[[PlayerSession alloc] initWithMedia: m5] autorelease];
    [s5 restoreState: nil];
    [s5 restoreState: @{@"items": @"not a list"}];
    PASS([[s5 playlist] count] == 0 && [s5 state] == PlayerPlaybackEmpty,
         "nothing or something unreadable leaves the list empty");
  END_SET("the list is remembered")

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
