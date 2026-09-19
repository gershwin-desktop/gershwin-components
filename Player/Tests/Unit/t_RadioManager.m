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
#import "RadioStation.h"

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
    /* An address that never answers keeps the new station connecting */
    [rm playURL: @"http://10.255.255.1:8000/stream"];
    PASS([rm player] != old, "the new station has a player of its own");
    spin(0.5);
    PASS([old isPlaying] && [old fadeGain] == 1.0f,
         "the old station plays on at full volume while the new one connects");

    [rm playURL: b];
    spin(0.3);
    PASS([rm isPlaying], "the new station plays");
    PASS([old isPlaying] && [old fadeGain] < 1.0f && [old fadeGain] > 0.0f,
         "and only now the old one fades out (%f)", [old fadeGain]);
    PASS([[rm player] fadeGain] > 0.0f && [[rm player] fadeGain] < 1.0f,
         "while the new one fades in (%f)", [[rm player] fadeGain]);
    spin(1.3);
    PASS(![old isPlaying], "the old station stops once it has faded out");
    PASS([rm isPlaying] && [[rm player] fadeGain] == 1.0f,
         "the new station plays at full volume");
  END_SET("switching stations crossfades")

  START_SET("a station that fails")
    StreamPlayer *old = [[[rm player] retain] autorelease];
    [rm playURL: @"/nonexistent/station.mp3"];
    spin(0.3);
    PASS(![rm isPlaying], "the station that cannot be played does not play");
    PASS([old fadeGain] < 1.0f, "the old station fades out, as it was switched away from");
    spin(1.3);
    PASS(![old isPlaying], "and stops");
    [rm playURL: a];
    spin(1.5);
  END_SET("a station that fails")

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

  START_SET("fading switched off")
    PASS([rm fadeDuration] > 0.5, "stations fade by default");
    [rm setFadeDuration: 0];
    [rm playURL: a];
    spin(0.3);
    PASS([rm isPlaying] && [[rm player] fadeGain] == 1.0f,
         "a station starts at full volume");
    StreamPlayer *old = [[[rm player] retain] autorelease];
    [rm playURL: b];
    spin(0.3);
    PASS(![old isPlaying], "switching stops the old station at once");
    PASS([rm isPlaying] && [[rm player] fadeGain] == 1.0f,
         "and the new one plays at full volume");
    StreamPlayer *current = [[[rm player] retain] autorelease];
    [rm stop];
    PASS(![current isPlaying], "stop cuts it off at once");
  END_SET("fading switched off")

  [rm release];
  [[NSFileManager defaultManager] removeItemAtPath: a error: NULL];
  [[NSFileManager defaultManager] removeItemAtPath: b error: NULL];
  START_SET("a station is remembered")
    RadioStation *station = [[[RadioStation alloc] initWithDictionary:
      @{@"text": @"Jazz FM", @"subtext": @"Jazz", @"image": @"http://x/logo.png",
        @"URL": @"http://tune/jazz", @"guide_id": @"s123"}] autorelease];
    [station setStreamURL: @"http://stream/jazz.mp3"];
    NSData *xml = [NSPropertyListSerialization dataWithPropertyList: [station propertyList]
                                                             format: NSPropertyListXMLFormat_v1_0
                                                            options: 0
                                                              error: NULL];
    NSDictionary *saved = xml ? [NSPropertyListSerialization propertyListWithData: xml
                                                                          options: 0
                                                                           format: NULL
                                                                            error: NULL] : nil;
    PASS(saved != nil, "it can be kept in the defaults");
    RadioStation *back = [RadioStation stationWithPropertyList: saved];
    PASS_EQUAL([back name], @"Jazz FM", "its name comes back");
    PASS_EQUAL([back stationId], @"s123", "and its id");
    PASS_EQUAL([back tuneURL], @"http://tune/jazz", "and where to tune it in");
    PASS_EQUAL([back streamURL], @"http://stream/jazz.mp3", "and its stream");
    PASS_EQUAL([back imageURL], @"http://x/logo.png", "and its logo");
    PASS([back isSameStationAs: station], "it is the same station");
    PASS([RadioStation stationWithPropertyList: @{@"name": @"Nowhere"}] == nil,
         "a station without anything to tune in is not brought back");
    PASS([RadioStation stationWithPropertyList: nil] == nil, "nor is nothing");
  END_SET("a station is remembered")

  [arp release];
  return 0;
}
