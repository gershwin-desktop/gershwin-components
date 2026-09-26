/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_StreamPlayer.m - the FFmpeg player that plays local files: timing,
 * pause, seeking and the end-of-track callback.  Plays without the sound
 * device, so it is silent and works headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "StreamPlayer.h"
#import "TestMedia.h"
#include <unistd.h>

@interface StopRecorder : NSObject <StreamPlayerDelegate>
{
@public
  int stops;
  int starts;
  int failures;
  BOOL onMainThread;
  BOOL startOnMainThread;
}
@end

@implementation StopRecorder
- (void)streamPlayerDidStop:(StreamPlayer *)player
{
  stops++;
  onMainThread = [NSThread isMainThread];
}
- (void)streamPlayerDidStartPlaying:(StreamPlayer *)player
{
  starts++;
  startOnMainThread = [NSThread isMainThread];
}
- (void)streamPlayer:(StreamPlayer *)player didFailWithError:(NSError *)error
{
  failures++;
}
@end

static void spin(NSTimeInterval seconds)
{
  [[NSRunLoop currentRunLoop] runUntilDate:
    [NSDate dateWithTimeIntervalSinceNow: seconds]];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSString *wav = TestMediaWriteSilentWAV(@"sp", 2.0);
  NSString *shortWav = TestMediaWriteSilentWAV(@"spshort", 0.6);

  START_SET("opening")
    StreamPlayer *sp = [[[StreamPlayer alloc] init] autorelease];
    NSError *err = nil;
    PASS(![sp openURL: @"/nonexistent/file.mp3" error: &err] && err != nil,
         "a missing file fails with an error");
    PASS([sp openURL: wav error: &err], "a WAV file opens");
    PASS(fabs([sp duration] - 2.0) < 0.05, "its duration is known (%f)", [sp duration]);
    PASS(![sp hasVideo], "it has no video");
    [sp close];
  END_SET("opening")

  START_SET("playing without the sound device keeps real time")
    StreamPlayer *sp = [[[StreamPlayer alloc] init] autorelease];
    [sp setUsesAudioDevice: NO];
    [sp openURL: wav error: NULL];
    [sp play];
    spin(0.5);
    NSTimeInterval t = [sp currentTime];
    PASS(t > 0.25 && t < 0.8, "after half a second about half a second played (%f)", t);
    PASS([sp isPlaying], "still playing");

    [sp pause];
    spin(0.1);
    NSTimeInterval paused = [sp currentTime];
    spin(0.4);
    PASS(fabs([sp currentTime] - paused) < 0.05, "time stands still while paused");

    [sp seekToTime: 1.5];
    spin(0.2);
    PASS(fabs([sp currentTime] - 1.5) < 0.1,
         "seeking while paused moves the position (%f)", [sp currentTime]);

    [sp play];
    spin(0.25);
    t = [sp currentTime];
    PASS(t > 1.55 && t < 2.0, "playing resumes from the new position (%f)", t);

    [sp seekToTime: 0.2];
    spin(0.2);
    t = [sp currentTime];
    PASS(t > 0.15 && t < 0.7, "seeking back while playing works (%f)", t);
    [sp close];
  END_SET("playing without the sound device keeps real time")

  START_SET("seeking before playing")
    StreamPlayer *sp = [[[StreamPlayer alloc] init] autorelease];
    [sp setUsesAudioDevice: NO];
    [sp openURL: wav error: NULL];
    [sp seekToTime: 1.0];
    PASS(fabs([sp currentTime] - 1.0) < 0.1, "position is where it was sought to");
    [sp play];
    spin(0.3);
    PASS([sp currentTime] > 1.1, "playback starts there (%f)", [sp currentTime]);
    [sp close];
  END_SET("seeking before playing")

  START_SET("end of track")
    StreamPlayer *sp = [[[StreamPlayer alloc] init] autorelease];
    StopRecorder *rec = [[StopRecorder new] autorelease];
    [sp setUsesAudioDevice: NO];
    [sp setDelegate: rec];
    [sp openURL: shortWav error: NULL];
    [sp play];
    spin(0.3);
    PASS(rec->stops == 0, "the track does not end early");
    spin(0.8);
    PASS(rec->stops == 1, "the delegate hears once that the track ended");
    PASS(rec->onMainThread, "on the main thread");
    PASS(![sp isPlaying], "the player is no longer playing");

    rec->stops = 0;
    [sp openURL: shortWav error: NULL];
    [sp play];
    spin(0.1);
    [sp stop];
    spin(0.8);
    PASS(rec->stops == 0, "stopping by hand is not reported as the track ending");
    [sp setDelegate: nil];
    [sp close];
  END_SET("end of track")

  START_SET("opening in the background")
    StreamPlayer *sp = [[[StreamPlayer alloc] init] autorelease];
    StopRecorder *rec = [[StopRecorder new] autorelease];
    [sp setUsesAudioDevice: NO];
    [sp setDelegate: rec];
    [sp playURL: wav];
    PASS(rec->starts == 0, "playURL: returns before the stream is open");
    spin(0.5);
    PASS(rec->starts == 1 && rec->startOnMainThread,
         "the delegate hears on the main thread when playback starts");
    PASS([sp isPlaying] && [sp currentTime] > 0.1, "and it plays (%f)", [sp currentTime]);
    PASS(fabs([sp duration] - 2.0) < 0.05, "the duration is known once open");
    [sp close];

    rec->starts = 0;
    [sp playURL: @"/nonexistent/stream.mp3"];
    spin(0.5);
    PASS(rec->failures == 1 && rec->starts == 0, "a stream that cannot be opened is reported");
    PASS(![sp isPlaying], "and does not play");

    /* An address that never answers: connecting would hang for seconds */
    rec->failures = 0;
    NSDate *before = [NSDate date];
    [sp playURL: @"http://10.255.255.1:8000/stream"];
    NSTimeInterval callTime = -[before timeIntervalSinceNow];
    PASS(callTime < 0.1, "connecting does not block the caller (%f s)", callTime);
    PASS([sp isConnecting], "the player says it is connecting");
    spin(0.3);
    before = [NSDate date];
    [sp close];
    NSTimeInterval closeTime = -[before timeIntervalSinceNow];
    PASS(closeTime < 1.0, "closing gives up the connection attempt at once (%f s)", closeTime);
    PASS(![sp isConnecting], "and the player is no longer connecting");
    spin(0.3);
    PASS(rec->starts == 0 && rec->failures == 0,
         "an abandoned attempt reports nothing");

    /* Opens, but holds nothing to play: a subtitle file */
    NSString *srt = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat: @"player-sub-%d.srt", (int)getpid()]];
    [@"1\n00:00:01,000 --> 00:00:02,000\nHello\n\n" writeToFile: srt atomically: YES
      encoding: NSUTF8StringEncoding error: NULL];
    rec->failures = 0;
    [sp playURL: srt];
    spin(0.5);
    PASS(rec->failures == 1, "a file without audio or video is reported");
    before = [NSDate date];
    [sp close];
    PASS(-[before timeIntervalSinceNow] < 0.5, "and the player can still be closed");
    [[NSFileManager defaultManager] removeItemAtPath: srt error: NULL];

    rec->failures = 0;
    [sp playURL: @"http://10.255.255.1:8000/stream"];
    spin(0.2);
    [sp playURL: shortWav];
    spin(0.4);
    PASS(rec->starts == 1 && rec->failures == 0,
         "a new stream replaces one that is still connecting");
    [sp setDelegate: nil];
    [sp close];
  END_SET("opening in the background")

  START_SET("fading")
    StreamPlayer *sp = [[[StreamPlayer alloc] init] autorelease];
    PASS([sp fadeGain] == 1.0f, "a new player is not faded");
    [sp setFadeGain: 0.0f];
    PASS([sp fadeGain] == 0.0f, "the gain can be set at once");
    [sp fadeToGain: 1.0f duration: 0.4];
    spin(0.2);
    float mid = [sp fadeGain];
    PASS(mid > 0.25f && mid < 0.75f, "half way through a fade the gain is in between (%f)", mid);
    spin(0.3);
    PASS([sp fadeGain] == 1.0f, "a fade ends at its target");
    [sp fadeToGain: 0.0f duration: 0.0];
    PASS([sp fadeGain] == 0.0f, "a fade without duration is immediate");
    [sp setVolume: 0.7f];
    PASS(fabsf([sp volume] - 0.7f) < 0.001f, "fading leaves the volume alone");
  END_SET("fading")

  [[NSFileManager defaultManager] removeItemAtPath: wav error: NULL];
  [[NSFileManager defaultManager] removeItemAtPath: shortWav error: NULL];
  [arp release];
  return 0;
}
