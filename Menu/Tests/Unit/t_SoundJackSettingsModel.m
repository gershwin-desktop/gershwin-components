/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The view-free half of the JACK box in the Sound pane: popup choices and
   texts, what the state of the server allows, card naming, what a device
   choice writes, and the status file reader. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Sound/SoundJackSettingsModel.h"

static NSDictionary *dev(NSString *cardId, int card, int devno)
{
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  if (cardId) [d setObject: cardId forKey: SoundJackDeviceCardId];
  [d setObject: [NSNumber numberWithInt: card] forKey: SoundJackDeviceCardIndex];
  [d setObject: [NSNumber numberWithInt: devno] forKey: SoundJackDeviceDeviceIndex];
  return d;
}

static NSArray *cards(void)
{
  /* Audio has two devices, sofhdadsp three, vc4hdmi0 one */
  return [NSArray arrayWithObjects:
    dev(@"sofhdadsp", 0, 0), dev(@"sofhdadsp", 0, 3), dev(@"Audio", 1, 0),
    dev(@"Audio", 1, 1), dev(@"vc4hdmi0", 2, 0), nil];
}

static NSDictionary *st(NSString *state, NSString *owner, NSNumber *rate,
                        NSNumber *frames, NSString *message)
{
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  if (state) [d setObject: state forKey: @"state"];
  if (owner) [d setObject: owner forKey: @"owner"];
  if (rate) [d setObject: rate forKey: @"sampleRate"];
  if (frames) [d setObject: frames forKey: @"bufferFrames"];
  if (message) [d setObject: message forKey: @"message"];
  return d;
}

static void testChoices(void)
{
  NSArray *b = [SoundJackSettingsModel bufferSizes];
  PASS_EQUAL(b, ([NSArray arrayWithObjects: @64, @128, @256, @512, @1024, @2048, @4096, nil]),
             "buffer sizes 64 to 4096");
  PASS_EQUAL([SoundJackSettingsModel sampleRates],
             ([NSArray arrayWithObjects: @44100, @48000, @88200, @96000, nil]), "sample rates");
  PASS_EQUAL([SoundJackSettingsModel titleForBufferFrames: 1024 sampleRate: 48000],
             @"1024 frames (21 ms)", "1024 at 48 kHz");
  PASS_EQUAL([SoundJackSettingsModel titleForBufferFrames: 64 sampleRate: 48000],
             @"64 frames (1.3 ms)", "short buffers show one decimal");
  PASS_EQUAL([SoundJackSettingsModel titleForBufferFrames: 4096 sampleRate: 44100],
             @"4096 frames (93 ms)", "4096 at 44.1 kHz");
  PASS_EQUAL([SoundJackSettingsModel titleForBufferFrames: 512 sampleRate: 96000],
             @"512 frames (5.3 ms)", "latency follows the rate");
  PASS_EQUAL([SoundJackSettingsModel titleForSampleRate: 48000], @"48 kHz", "48 kHz");
  PASS_EQUAL([SoundJackSettingsModel titleForSampleRate: 44100], @"44.1 kHz", "44.1 kHz");
}

static NSDictionary *stDriven(NSString *drivenDevice, NSNumber *bridged)
{
  NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:
    st(@"running", @"own", @48000, @1024, nil)];
  if (drivenDevice) [d setObject: drivenDevice forKey: @"drivenDevice"];
  if (bridged) [d setObject: bridged forKey: @"outputBridged"];
  return d;
}

static void testStatusText(void)
{
  Class m = [SoundJackSettingsModel class];
  PASS_EQUAL([m statusTextForStatus: stDriven(@"Built-in Audio", @NO)
                 selectedDeviceName: @"Built-in Audio"],
             @"JACK is running: 48 kHz, 1024 frames, driving Built-in Audio", "running on the selected device");
  PASS_EQUAL([m statusTextForStatus: stDriven(@"Built-in Audio", nil)
                 selectedDeviceName: @"Built-in Audio"],
             @"JACK is running: 48 kHz, 1024 frames, driving Built-in Audio", "no bridge flag: same name");
  PASS_EQUAL([m statusTextForStatus: stDriven(@"Built-in Audio", nil) selectedDeviceName: nil],
             @"JACK is running: 48 kHz, 1024 frames, driving Built-in Audio", "no selection: driven device");
  PASS_EQUAL([m statusTextForStatus: stDriven(@"Built-in Audio", @YES)
                 selectedDeviceName: @"USB Audio"],
             @"JACK is running: 48 kHz, 1024 frames (USB Audio plays through a bridge)", "bridged");
  PASS_EQUAL([m statusTextForStatus: stDriven(@"Built-in Audio", nil)
                 selectedDeviceName: @"USB Audio"],
             @"JACK is running: 48 kHz, 1024 frames (USB Audio plays through a bridge)",
             "different names without the flag: bridged");
  PASS_EQUAL([m statusTextForStatus: stDriven(nil, @YES) selectedDeviceName: @"USB Audio"],
             @"JACK is running: 48 kHz, 1024 frames (USB Audio plays through a bridge)",
             "bridge flag without a driven name");
  PASS_EQUAL([m statusTextForStatus: stDriven(nil, @YES) selectedDeviceName: nil],
             @"JACK is running: 48 kHz, 1024 frames", "bridge flag, nothing selected");
  PASS_EQUAL([m statusTextForStatus: stDriven(@"Built-in Audio", @NO)
                 selectedDeviceName: @"USB Audio"],
             @"JACK is running: 48 kHz, 1024 frames, driving Built-in Audio",
             "flag says no bridge: driven device");
  PASS_EQUAL([m statusTextForStatus: stDriven(nil, nil) selectedDeviceName: @"Built-in Audio"],
             @"JACK is running: 48 kHz, 1024 frames", "running without a driven device");
  PASS_EQUAL([m statusTextForStatus: st(@"starting", @"own", nil, nil, nil) selectedDeviceName: nil],
             @"Starting JACK...", "starting");
  PASS_EQUAL([m statusTextForStatus: st(@"failed", @"own", nil, nil, @"device busy") selectedDeviceName: nil],
             @"JACK could not start: device busy", "failed carries the message");
  PASS_EQUAL([m statusTextForStatus: st(@"failed", nil, nil, nil, nil) selectedDeviceName: nil],
             @"JACK could not start: unknown error", "failed without a message");
  PASS_EQUAL([m statusTextForStatus: st(@"unavailable", nil, nil, nil, @"jackd is not installed")
                 selectedDeviceName: nil],
             @"JACK could not start: jackd is not installed", "unavailable");
  PASS_EQUAL([m statusTextForStatus: st(@"running", @"adopted", @44100, @256, nil)
                 selectedDeviceName: @"x"],
             @"Using the JACK server that is already running (change its settings there)", "adopted");
  PASS_EQUAL([m statusTextForStatus: st(@"disabled", nil, nil, nil, nil) selectedDeviceName: nil],
             @"JACK is off", "disabled");
  NSDictionary *textual = [NSDictionary dictionaryWithObjectsAndKeys: @"running", @"state",
    @"own", @"owner", @"44100", @"sampleRate", @"256", @"bufferFrames", nil];
  PASS_EQUAL([m statusTextForStatus: textual selectedDeviceName: nil],
             @"JACK is running: 44.1 kHz, 256 frames", "numbers given as strings (text plist)");
  PASS([[m statusTextForStatus: nil selectedDeviceName: nil] length] > 0, "no status file: some text");
}

static void testAllowances(void)
{
  Class m = [SoundJackSettingsModel class];
  NSDictionary *own = st(@"running", @"own", @48000, @1024, nil);
  NSDictionary *adopted = st(@"running", @"adopted", @48000, @1024, nil);
  PASS([m statusAllowsChangingRate: own],
       "own server: rate editable");
  PASS(![m statusAllowsChangingRate: adopted],
       "adopted server: rate locked");
  PASS([m statusAllowsChangingBufferSize: adopted] && [m statusAllowsChangingBufferSize: own],
       "buffer size always editable");
  PASS([m statusAllowsChangingRate: nil],
       "no status yet: nothing is locked");
  PASS([m statusIsAdopted: adopted] && ![m statusIsAdopted: own], "adopted flag");
}

static void testCards(void)
{
  Class m = [SoundJackSettingsModel class];
  NSArray *c = cards();
  PASS_EQUAL([m cardKeyForDevice: [c objectAtIndex: 4] amongDevices: c], @"vc4hdmi0",
             "single device: card id alone");
  PASS_EQUAL([m cardKeyForDevice: [c objectAtIndex: 1] amongDevices: c], @"sofhdadsp_3",
             "several devices: card id_device");
  PASS_EQUAL([m cardKeyForDevice: [c objectAtIndex: 2] amongDevices: c], @"Audio_0", "Audio_0");
  PASS([m cardKeyForDevice: dev(nil, 5, 0) amongDevices: c] == nil, "no card id: no key");
  NSDictionary *fromId = [m deviceDictionaryForStableId: @"vc4hdmi0.0" cardIndex: 2 deviceIndex: 0];
  PASS_EQUAL([fromId objectForKey: SoundJackDeviceCardId], @"vc4hdmi0", "card id from a stable id");
  fromId = [m deviceDictionaryForStableId: @"my.card.3" cardIndex: 1 deviceIndex: 3];
  PASS_EQUAL([fromId objectForKey: SoundJackDeviceCardId], @"my.card", "last dot separates the device");
  fromId = [m deviceDictionaryForStableId: @"hw:1,0" cardIndex: 1 deviceIndex: 0];
  PASS([fromId objectForKey: SoundJackDeviceCardId] == nil, "numeric id: no card id");
  PASS([m cardKeyForDevice: fromId amongDevices: [NSArray arrayWithObject: fromId]] == nil,
       "and so no key");

  PASS([m indexOfDeviceNamed: @"vc4hdmi0" inDevices: c] == 4, "key of a single-device card");
  PASS([m indexOfDeviceNamed: @"Audio_1" inDevices: c] == 3, "key with device");
  PASS([m indexOfDeviceNamed: @"hw:CARD=Audio,DEV=1" inDevices: c] == 3, "hw:CARD=,DEV=");
  PASS([m indexOfDeviceNamed: @"hw:1" inDevices: c] == 2, "hw:N is device 0 of card N");
  PASS([m indexOfDeviceNamed: @"hw:1,1" inDevices: c] == 3, "hw:N,M");
  PASS([m indexOfDeviceNamed: @"hw:sofhdadsp,3" inDevices: c] == 1, "hw:id,M");
  PASS([m indexOfDeviceNamed: @"hw:vc4hdmi0" inDevices: c] == 4, "hw:id");
  PASS([m indexOfDeviceNamed: @"plughw:2" inDevices: c] == 4, "plughw");
  PASS([m indexOfDeviceNamed: @"Gone" inDevices: c] == NSNotFound, "unknown key");
  PASS([m indexOfDeviceNamed: @"hw:9" inDevices: c] == NSNotFound, "unknown card number");
  PASS([m indexOfDeviceNamed: nil inDevices: c] == NSNotFound, "nil name");
  PASS([m indexOfDeviceNamed: @"Audio_1" inDevices: [NSArray array]] == NSNotFound, "no devices");

  PASS_EQUAL([m settingsForSelectingDevice: [c objectAtIndex: 4] amongDevices: c isOutput: YES],
             [NSDictionary dictionaryWithObject: @"vc4hdmi0" forKey: @"JackOutputCard"],
             "an output selection writes JackOutputCard only");
  PASS_EQUAL([m settingsForSelectingDevice: [c objectAtIndex: 3] amongDevices: c isOutput: NO],
             [NSDictionary dictionaryWithObject: @"Audio_1" forKey: @"JackInputCard"],
             "an input selection writes JackInputCard only");
  PASS([m settingsForSelectingDevice: dev(nil, 5, 0) amongDevices: c isOutput: YES] == nil,
       "nothing to write without a card id");
}

static void testWrite(void)
{
  NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat: @"sjm-%d", (int)getpid()]];
  NSString *path = [dir stringByAppendingPathComponent: @"sub/s.plist"];
  NSString *err = nil;
  Class m = [SoundJackSettingsModel class];
  PASS([m writeSettings: [NSDictionary dictionaryWithObject: @"Audio" forKey: @"JackOutputCard"]
                 atPath: path error: &err], "write creates the file and folder");
  NSMutableDictionary *raw = [NSMutableDictionary dictionaryWithContentsOfFile: path];
  [raw setObject: @"x" forKey: @"defaultOutput"];
  [raw setObject: @YES forKey: @"UseJack"];
  [raw writeToFile: path atomically: YES];
  PASS([m writeSettings: [NSDictionary dictionaryWithObject: @"Audio_1" forKey: @"JackInputCard"]
                 atPath: path error: &err], "second write merges");
  raw = [NSMutableDictionary dictionaryWithContentsOfFile: path];
  PASS_EQUAL([raw objectForKey: @"JackOutputCard"], @"Audio", "earlier key kept");
  PASS_EQUAL([raw objectForKey: @"JackInputCard"], @"Audio_1", "new key written");
  PASS_EQUAL([raw objectForKey: @"defaultOutput"], @"x", "foreign key kept");
  PASS_EQUAL([raw objectForKey: @"UseJack"], @YES, "UseJack kept");

  NSDate *before = [[[NSFileManager defaultManager] attributesOfItemAtPath: path error: NULL]
    fileModificationDate];
  [NSThread sleepForTimeInterval: 1.1];
  PASS([m writeSettings: [NSDictionary dictionaryWithObject: @"Audio_1" forKey: @"JackInputCard"]
                 atPath: path error: &err], "unchanged write succeeds");
  NSDate *after = [[[NSFileManager defaultManager] attributesOfItemAtPath: path error: NULL]
    fileModificationDate];
  PASS([before isEqualToDate: after], "an unchanged value does not rewrite the file");

  PASS(![m writeSettings: [NSDictionary dictionaryWithObject: @"" forKey: @"JackInputCard"]
                  atPath: path error: &err] && err, "empty value is refused");
  [@"not a plist" writeToFile: path atomically: YES encoding: NSUTF8StringEncoding error: NULL];
  err = nil;
  PASS(![m writeSettings: [NSDictionary dictionaryWithObject: @"Audio" forKey: @"JackOutputCard"]
                  atPath: path error: &err] && err, "unreadable file is not replaced");
  PASS_EQUAL([NSString stringWithContentsOfFile: path encoding: NSUTF8StringEncoding error: NULL],
             @"not a plist", "and stays as it was");
  [[NSFileManager defaultManager] removeItemAtPath: dir error: NULL];
}

static void testReader(void)
{
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat: @"sjr-%d.plist", (int)getpid()]];
  [[NSFileManager defaultManager] removeItemAtPath: path error: NULL];
  SoundJackStatusReader *r = [[SoundJackStatusReader alloc] initWithPath: path];
  PASS([r refresh] && [r status] == nil, "first refresh with no file reports the (empty) state once");
  PASS(![r refresh], "missing file again: unchanged");
  [st(@"starting", @"own", nil, nil, nil) writeToFile: path atomically: YES];
  PASS([r refresh] && [[[r status] objectForKey: @"state"] isEqual: @"starting"], "file appears");
  PASS(![r refresh], "same mtime: no re-read");
  /* overwrite behind its back, keeping the mtime: proves no re-read */
  NSDate *mtime = [[[NSFileManager defaultManager] attributesOfItemAtPath: path error: NULL]
    fileModificationDate];
  [st(@"running", @"own", @48000, @1024, nil) writeToFile: path atomically: YES];
  [[NSFileManager defaultManager] setAttributes:
    [NSDictionary dictionaryWithObject: mtime forKey: NSFileModificationDate]
                                   ofItemAtPath: path error: NULL];
  PASS(![r refresh] && [[[r status] objectForKey: @"state"] isEqual: @"starting"],
       "unchanged mtime is not read again");
  [NSThread sleepForTimeInterval: 1.1];
  [st(@"running", @"own", @48000, @1024, nil) writeToFile: path atomically: YES];
  PASS([r refresh] && [[[r status] objectForKey: @"state"] isEqual: @"running"], "new mtime is read");
  [[NSFileManager defaultManager] removeItemAtPath: path error: NULL];
  PASS([r refresh] && [r status] == nil, "file removed: status cleared");
  [r release];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  testChoices();
  testStatusText();
  testAllowances();
  testCards();
  testWrite();
  testReader();
  [arp release];
  return 0;
}
