/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* ALSABackend must not destroy what the JACK mode keeps next to its own
   data: the JACK keys of sound-defaults.plist and the managed block of
   ~/.asoundrc.  Everything runs in a temporary HOME. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Sound/ALSABackend.h"
#import "Sound/JackSupport.h"

static NSString *home;

static NSString *plistPath(void)
{
  return [home stringByAppendingPathComponent: @".config/gershwin/sound-defaults.plist"];
}

static NSString *rcPath(void)
{
  return [home stringByAppendingPathComponent: @".asoundrc"];
}

static NSString *readRc(void)
{
  return [NSString stringWithContentsOfFile: rcPath() encoding: NSUTF8StringEncoding error: NULL];
}

static void writePlist(NSDictionary *d)
{
  [[NSFileManager defaultManager] createDirectoryAtPath: [plistPath() stringByDeletingLastPathComponent]
                            withIntermediateDirectories: YES attributes: nil error: NULL];
  [d writeToFile: plistPath() atomically: YES];
}

static NSDate *mtime(NSString *path)
{
  return [[[NSFileManager defaultManager] attributesOfItemAtPath: path error: NULL]
    fileModificationDate];
}

static void testPreferencesMerge(void)
{
  writePlist([NSDictionary dictionaryWithObjectsAndKeys:
    @YES, @"UseJack", @256, @"JackBufferFrames", @"Audio_1", @"JackOutputCard",
    @"keepme", @"SomethingElse", nil]);
  ALSABackend *b = [[ALSABackend alloc] initWithHomeDirectory: home];
  PASS([b savePreferences], "savePreferences succeeds");
  NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile: plistPath()];
  PASS_EQUAL([d objectForKey: @"UseJack"], @YES, "UseJack survives");
  PASS_EQUAL([d objectForKey: @"JackBufferFrames"], @256, "JackBufferFrames survives");
  PASS_EQUAL([d objectForKey: @"JackOutputCard"], @"Audio_1", "JackOutputCard survives");
  PASS_EQUAL([d objectForKey: @"SomethingElse"], @"keepme", "unknown keys survive");
  PASS([d objectForKey: @"alertVolume"] != nil, "own keys are written");

  NSDate *before = mtime(plistPath());
  [NSThread sleepForTimeInterval: 1.1];
  PASS([b savePreferences], "second save succeeds");
  PASS([before isEqualToDate: mtime(plistPath())], "nothing changed: file not rewritten");
  [b release];

  /* an unreadable file is refused, not replaced */
  [@"garbage" writeToFile: plistPath() atomically: YES encoding: NSUTF8StringEncoding error: NULL];
  b = [[ALSABackend alloc] initWithHomeDirectory: home];
  PASS(![b savePreferences], "unreadable plist: save fails hard");
  PASS_EQUAL([NSString stringWithContentsOfFile: plistPath() encoding: NSUTF8StringEncoding error: NULL],
             @"garbage", "and the file is untouched");
  [b release];
}

static void testAsoundrcBlock(void)
{
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm removeItemAtPath: plistPath() error: NULL];
  ALSABackend *b = [[ALSABackend alloc] initWithHomeDirectory: home];
  AudioDevice *dev = [[b outputDevices] firstObject];
  if (dev == nil)
    {
      printf("SKIPPED: no ALSA output device on this machine\n");
      [b release];
      return;
    }

  /* a file with the managed block is written back with the block */
  NSString *err = nil;
  NSString *withBlock = [JackSupport asoundrcByApplyingJackBlockTo:
    @"pcm.!default { type hw card 9 }\n" error: &err];
  [withBlock writeToFile: rcPath() atomically: YES encoding: NSUTF8StringEncoding error: NULL];
  PASS([b saveDefaultDevice: dev isOutput: YES], "save with a block in the file");
  NSString *rc = readRc();
  PASS([JackSupport asoundrcHasJackBlock: rc], "the managed block is still there");
  PASS([rc hasPrefix: @"# ALSA configuration"], "the backend text comes first");
  PASS([rc rangeOfString: @"card 9"].location == NSNotFound, "the old backend text is replaced");
  NSRange first = [rc rangeOfString: @"pcm.!default"];
  PASS(first.location != NSNotFound
       && first.location < [rc rangeOfString: @"# BEGIN gershwin jack"].location,
       "the backend's own pcm.!default is the first one");
  PASS([rc rangeOfString: @"# BEGIN gershwin jack"].location
       == [rc rangeOfString: @"# BEGIN gershwin jack" options: NSBackwardsSearch].location,
       "exactly one block");

  /* no block in the file: none appears */
  [@"pcm.!default { type hw card 9 }\n" writeToFile: rcPath() atomically: YES
                                           encoding: NSUTF8StringEncoding error: NULL];
  PASS([b saveDefaultDevice: dev isOutput: YES], "save without a block");
  PASS(![JackSupport asoundrcHasJackBlock: readRc()], "no block is invented");

  /* a damaged block is not guessed at: nothing is written */
  NSString *damaged = @"pcm.!default { type hw card 9 }\n# BEGIN gershwin jack\nfoo\n";
  [damaged writeToFile: rcPath() atomically: YES encoding: NSUTF8StringEncoding error: NULL];
  PASS(![b saveDefaultDevice: dev isOutput: YES], "damaged block: save fails hard");
  PASS_EQUAL(readRc(), damaged, "and the file is untouched");

  /* JACK mode: the choice goes to the settings, ~/.asoundrc is not touched */
  NSString *untouched = @"# mine\n";
  [untouched writeToFile: rcPath() atomically: YES encoding: NSUTF8StringEncoding error: NULL];
  writePlist([NSDictionary dictionaryWithObjectsAndKeys:
    @YES, @"UseJack",
    @"Old.0", @"defaultOutput", nil]);
  PASS([b jackModeEnabled], "JACK mode reads UseJack");
  PASS([b setDefaultOutputDevice: dev], "select an output in JACK mode");
  PASS_EQUAL(readRc(), untouched, "~/.asoundrc is not rewritten in JACK mode");
  NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile: plistPath()];
  NSString *card = [d objectForKey: @"JackOutputCard"];
  PASS(card != nil && [card length] > 0, "JackOutputCard written");
  PASS_EQUAL([d objectForKey: @"defaultOutput"], @"Old.0", "the ALSA default is left alone");
  PASS([d objectForKey: @"JackClockDevice"] == nil, "no clock device is invented");
  PASS([b savePreferences], "savePreferences in JACK mode");
  PASS_EQUAL([[NSDictionary dictionaryWithContentsOfFile: plistPath()] objectForKey: @"defaultOutput"],
             @"Old.0", "and it keeps the ALSA default too");
  PASS([b forceImmediateOutputDeviceSwitch: dev], "immediate switch in JACK mode");
  PASS_EQUAL(readRc(), untouched, "still no asoundrc rewrite");

  /* back to ALSA: the ALSA default of the file is selected again */
  writePlist([NSDictionary dictionaryWithObjectsAndKeys:
    @NO, @"UseJack", [dev stableDeviceId], @"defaultOutput", nil]);
  [b syncSelectionWithJackMode];
  PASS_EQUAL([[b defaultOutputDevice] stableDeviceId], [dev stableDeviceId],
             "JACK off: the ALSA default is back");
  [b release];
}

static void testAlertRouting(void)
{
  NSString *statusPath = [home stringByAppendingPathComponent: @".cache/gershwin/jack-status.plist"];
  [[NSFileManager defaultManager] createDirectoryAtPath: [statusPath stringByDeletingLastPathComponent]
                            withIntermediateDirectories: YES attributes: nil error: NULL];
  ALSABackend *b = [[ALSABackend alloc] initWithHomeDirectory: home];

  /* JACK off: the card path, as before */
  writePlist([NSDictionary dictionaryWithObject: @NO forKey: @"UseJack"]);
  [[NSDictionary dictionaryWithObject: @"running" forKey: @"state"]
    writeToFile: statusPath atomically: YES];
  PASS(![[b alertPlaybackDevice] isEqualToString: @"default"] || [[b outputDevices] count] == 0,
       "JACK off: the alert is aimed at the card");
  PASS([b jackAlertActionForElapsed: 0 timeout: 3] == SoundJackAlertPlayOnCard,
       "JACK off: no waiting");

  /* JACK on, server running: the default PCM, and waiting for the routing */
  writePlist([NSDictionary dictionaryWithObjectsAndKeys:
    @YES, @"UseJack", @"Audio_1", @"JackOutputCard", nil]);
  [[NSDictionary dictionaryWithObjectsAndKeys: @"running", @"state",
    @"Other", @"routedOutputCard", nil] writeToFile: statusPath atomically: YES];
  PASS_EQUAL([b alertPlaybackDevice], @"default", "JACK on and running: default PCM");
  PASS([b jackAlertActionForElapsed: 1 timeout: 3] == SoundJackAlertKeepWaiting,
       "not routed yet: keep waiting");
  PASS([b jackAlertActionForElapsed: 3 timeout: 3] == SoundJackAlertPlayDefaultUnconfirmed,
       "timeout: play anyway");
  [[NSDictionary dictionaryWithObjectsAndKeys: @"running", @"state",
    @"Audio_1", @"routedOutputCard", nil] writeToFile: statusPath atomically: YES];
  PASS([b jackAlertActionForElapsed: 0 timeout: 3] == SoundJackAlertPlayDefault,
       "routed to the selected card: play now");

  /* JACK on, server gone: the card again */
  [[NSDictionary dictionaryWithObject: @"failed" forKey: @"state"]
    writeToFile: statusPath atomically: YES];
  PASS(![[b alertPlaybackDevice] isEqualToString: @"default"] || [[b outputDevices] count] == 0,
       "server not running: the card");
  [b release];
}

static void testUnsetSelectionFollowsAlsaDefault(void)
{
  ALSABackend *b = [[ALSABackend alloc] initWithHomeDirectory: home];
  NSArray *outs = [b outputDevices];
  if ([outs count] == 0)
    {
      printf("SKIPPED: no ALSA output device on this machine\n");
      [b release];
      return;
    }
  AudioDevice *last = [outs lastObject];
  writePlist([NSDictionary dictionaryWithObjectsAndKeys:
    @YES, @"UseJack", [last stableDeviceId], @"defaultOutput", nil]);
  [b syncSelectionWithJackMode];
  PASS_EQUAL([[b defaultOutputDevice] stableDeviceId], [last stableDeviceId],
             "JACK on, no JackOutputCard: the ALSA default is the selection");
  writePlist([NSDictionary dictionaryWithObject: @YES forKey: @"UseJack"]);
  [b syncSelectionWithJackMode];
  PASS_EQUAL([[b defaultOutputDevice] stableDeviceId], [[outs objectAtIndex: 0] stableDeviceId],
             "nothing set: the first present device");
  [b release];
}

/* The volume is the first percentage in the amixer text.  A control with a
   switch line before its volume lines ("Mono: Playback [on]", as on the
   Samson Q2U microphone) used to read as 0: the bracket search took the
   "[on]" as the start of the number and the next "%]" far below as its end,
   so the input volume of the pane was always 0. */
@interface ALSABackend (ParseAccess)
- (float)parseVolumeFromMixerOutput:(NSString *)output;
@end

static void testVolumeParsing(void)
{
  ALSABackend *b = [[ALSABackend alloc] initWithHomeDirectory: home];
  NSString *samson =
    @"Simple mixer control 'Mic',0\n"
    @"  Capabilities: cvolume pswitch pswitch-joined cswitch cswitch-joined\n"
    @"  Playback channels: Mono\n"
    @"  Capture channels: Front Left - Front Right\n"
    @"  Limits: Capture 0 - 36\n"
    @"  Mono: Playback [on]\n"
    @"  Front Left: Capture 31 [86%] [17.00dB] [on]\n"
    @"  Front Right: Capture 31 [86%] [17.00dB] [on]\n";
  PASS(fabs([b parseVolumeFromMixerOutput: samson] - 0.86) < 0.001,
       "a switch line with [on] before the volume lines does not hide the volume");
  NSString *speaker =
    @"Simple mixer control 'Speaker',0\n"
    @"  Capabilities: pvolume pswitch pswitch-joined\n"
    @"  Limits: Playback 0 - 62\n"
    @"  Front Left: Playback 41 [66%] [-21.00dB] [on]\n";
  PASS(fabs([b parseVolumeFromMixerOutput: speaker] - 0.66) < 0.001,
       "the usual output still reads 66 percent");
  PASS([b parseVolumeFromMixerOutput: @"  Mono: Playback [on]\n"] == 0.0,
       "a control without any percentage reads 0");
  PASS(fabs([b parseVolumeFromMixerOutput: @"x [off] [100%] y"] - 1.0) < 0.001,
       "a bracket that is not a percentage is skipped");
  [b release];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  home = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat: @"alsajack-%d", (int)getpid()]];
  [[NSFileManager defaultManager] createDirectoryAtPath: home
                            withIntermediateDirectories: YES attributes: nil error: NULL];
  testPreferencesMerge();
  testAsoundrcBlock();
  testAlertRouting();
  testUnsetSelectionFollowsAlsaDefault();
  testVolumeParsing();
  [[NSFileManager defaultManager] removeItemAtPath: home error: NULL];
  [arp release];
  return 0;
}
