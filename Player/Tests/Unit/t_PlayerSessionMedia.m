/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_PlayerSessionMedia.m - a playlist of real files plays through with the
 * FFmpeg player: one track after the other, then it stops.  Silent. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "PlayerSession.h"
#import "TestMedia.h"

static void spin(NSTimeInterval seconds)
{
  [[NSRunLoop currentRunLoop] runUntilDate:
    [NSDate dateWithTimeIntervalSinceNow: seconds]];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSString *a = TestMediaWriteSilentWAV(@"sessA", 0.6);
  NSString *b = TestMediaWriteSilentWAV(@"sessB", 0.6);
  NSArray *files = @[a, b];

  START_SET("a playlist plays through")
    StreamPlayer *sp = [[[StreamPlayer alloc] init] autorelease];
    [sp setUsesAudioDevice: NO];
    PlayerSession *s = [[[PlayerSession alloc] initWithMedia: sp] autorelease];
    [s openItems: files];
    spin(0.3);
    PASS([s state] == PlayerSessionPlaying, "the first file plays");
    PASS([[s playlist] currentIndex] == 0, "it is the first");
    PASS(fabs([s duration] - 0.6) < 0.05, "its duration is shown (%f)", [s duration]);
    spin(0.6);
    PASS([[s playlist] currentIndex] == 1, "the second follows by itself");
    PASS([s state] == PlayerSessionPlaying, "and plays");
    spin(0.8);
    PASS([s state] == PlayerSessionStopped, "after the last file playback stops");
    PASS([[s playlist] currentIndex] == 0, "ready to start over");

    [s togglePlayPause];
    spin(0.2);
    [s togglePlayPause];
    NSTimeInterval t = [s currentTime];
    spin(0.3);
    PASS([s state] == PlayerSessionPaused && fabs([s currentTime] - t) < 0.02,
         "pause holds the position");
    [s stop];
    PASS([s currentTime] == 0.0, "stop returns to the start");
  END_SET("a playlist plays through")

  [[NSFileManager defaultManager] removeItemAtPath: a error: NULL];
  [[NSFileManager defaultManager] removeItemAtPath: b error: NULL];
  [arp release];
  return 0;
}
