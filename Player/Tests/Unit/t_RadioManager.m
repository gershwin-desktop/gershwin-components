/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_RadioManager.m - switching stations fades the old one out while the
 * new one fades in, and stopping fades out.  Local WAV files stand in for
 * stations; the players play silently, so it is headless. */

#import <AppKit/AppKit.h>
#import "Testing.h"
#import "RadioManager.h"
#import "TestMedia.h"

@interface SilentRadioManager : RadioManager
@end

@implementation SilentRadioManager
- (StreamPlayer *)makePlayer
{
  StreamPlayer *player = [super makePlayer];
  [player setUsesAudioDevice: NO];
  return player;
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
  NSString *a = TestMediaWriteSilentWAV(@"radioA", 6.0);
  NSString *b = TestMediaWriteSilentWAV(@"radioB", 6.0);
  RadioManager *rm = [[SilentRadioManager alloc] init];

  START_SET("tuning in fades in")
    [rm playURL: a];
    spin(0.3);
    PASS([rm isPlaying], "the station plays");
    float g = [[rm player] fadeGain];
    PASS(g > 0.0f && g < 1.0f, "it starts quiet and gets louder (%f)", g);
    spin(1.2);
    PASS([[rm player] fadeGain] == 1.0f, "then plays at full volume");
  END_SET("tuning in fades in")

  START_SET("switching stations crossfades")
    StreamPlayer *old = [[[rm player] retain] autorelease];
    [rm playURL: b];
    PASS([rm player] != old, "the new station has a player of its own");
    spin(0.3);
    PASS([old isPlaying], "the old station goes on playing for a moment");
    PASS([old fadeGain] < 1.0f, "while it fades out (%f)", [old fadeGain]);
    PASS([rm isPlaying], "and the new one already plays");
    spin(1.3);
    PASS(![old isPlaying], "the old station stops once it has faded out");
    PASS([rm isPlaying] && [[rm player] fadeGain] == 1.0f,
         "the new station plays at full volume");
  END_SET("switching stations crossfades")

  START_SET("stopping fades out")
    StreamPlayer *current = [[[rm player] retain] autorelease];
    [rm stop];
    PASS(![rm isPlaying] && ![rm isConnecting], "the radio counts as stopped at once");
    spin(0.3);
    PASS([current isPlaying] && [current fadeGain] < 1.0f,
         "while the sound fades out");
    spin(1.3);
    PASS(![current isPlaying], "and then it is silent");
  END_SET("stopping fades out")

  [rm release];
  [[NSFileManager defaultManager] removeItemAtPath: a error: NULL];
  [[NSFileManager defaultManager] removeItemAtPath: b error: NULL];
  [arp release];
  return 0;
}
