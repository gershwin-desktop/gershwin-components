/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Which PCM the alert sound of the Sound pane plays through while JACK is
   in use, and when the pane stops waiting for the routing to move. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Sound/SoundJackAlertPolicy.h"

static NSDictionary *status(NSString *state, NSString *routed)
{
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  if (state) [d setObject: state forKey: @"state"];
  if (routed) [d setObject: routed forKey: @"routedOutputCard"];
  return d;
}

static NSDictionary *useJack(BOOL on)
{
  return [NSDictionary dictionaryWithObject: [NSNumber numberWithBool: on] forKey: @"UseJack"];
}

static void testDevice(void)
{
  NSDictionary *run = status(@"running", nil);
  PASS_EQUAL([SoundJackAlertPolicy playbackDeviceForSettings: useJack(YES) status: run
                                                  cardDevice: @"plughw:1"],
             @"default", "JACK on and running: the default PCM");
  PASS_EQUAL([SoundJackAlertPolicy playbackDeviceForSettings: useJack(NO) status: run
                                                  cardDevice: @"plughw:1"],
             @"plughw:1", "JACK off: the card");
  PASS_EQUAL([SoundJackAlertPolicy playbackDeviceForSettings: nil status: run
                                                  cardDevice: @"plughw:1"],
             @"plughw:1", "no settings: the card");
  PASS_EQUAL([SoundJackAlertPolicy playbackDeviceForSettings: useJack(YES) status: nil
                                                  cardDevice: @"plughw:1"],
             @"plughw:1", "JACK on, no status: the card");
  for (NSString *s in [NSArray arrayWithObjects: @"starting", @"failed", @"unavailable",
                       @"disabled", nil])
    PASS_EQUAL([SoundJackAlertPolicy playbackDeviceForSettings: useJack(YES) status: status(s, nil)
                                                    cardDevice: @"plughw:1"],
               @"plughw:1", "JACK on but not running: the card");
  PASS_EQUAL([SoundJackAlertPolicy playbackDeviceForSettings: useJack(YES) status: run
                                                  cardDevice: nil],
             @"default", "no card at all still plays on the default PCM");
}

static SoundJackAlertAction act(NSDictionary *st, NSString *selected, NSString *clock,
                                NSTimeInterval elapsed)
{
  NSMutableDictionary *s = [NSMutableDictionary dictionaryWithDictionary: st];
  if (clock) [s setObject: clock forKey: @"clockDevice"];
  return [SoundJackAlertPolicy actionForStatus: s selectedCard: selected
                                       elapsed: elapsed timeout: 3.0];
}

static void testAction(void)
{
  PASS(act(status(@"running", @"Audio_1"), @"Audio_1", nil, 0.0) == SoundJackAlertPlayDefault,
       "routed to the selected card: play now");
  PASS(act(status(@"running", @"sofhdadsp_31"), @"Audio_1", nil, 0.5) == SoundJackAlertKeepWaiting,
       "routed elsewhere: wait");
  PASS(act(status(@"running", nil), @"Audio_1", nil, 0.5) == SoundJackAlertKeepWaiting,
       "nothing routed yet: wait");
  PASS(act(status(@"running", @"sofhdadsp_31"), @"Audio_1", nil, 3.0)
       == SoundJackAlertPlayDefaultUnconfirmed, "timeout reached: play anyway");
  PASS(act(status(@"running", @"sofhdadsp_31"), @"Audio_1", nil, 2.99) == SoundJackAlertKeepWaiting,
       "just before the timeout: still waiting");
  PASS(act(status(@"running", @"Audio_1"), @"Audio_1", nil, 9.0) == SoundJackAlertPlayDefault,
       "confirmed late is still confirmed");

  /* the clock device is reported as "clock" */
  PASS(act(status(@"running", @"clock"), @"Audio", @"hw:CARD=Audio,DEV=0", 0.1)
       == SoundJackAlertPlayDefault, "clock routed, selected is the clock card (hw:CARD=)");
  PASS(act(status(@"running", @"clock"), @"Audio", @"hw:Audio", 0.1)
       == SoundJackAlertPlayDefault, "clock routed, selected is the clock card (hw:Audio)");
  PASS(act(status(@"running", @"clock"), @"Audio_1", @"hw:CARD=Audio,DEV=1", 0.1)
       == SoundJackAlertPlayDefault, "clock routed, selected names the clock device number");
  PASS(act(status(@"running", @"clock"), @"Audio_1", @"hw:CARD=Audio,DEV=0", 0.1)
       == SoundJackAlertKeepWaiting, "other device of the clock card: not it");
  PASS(act(status(@"running", @"clock"), @"HDMI", @"hw:CARD=Audio,DEV=0", 0.1)
       == SoundJackAlertKeepWaiting, "clock routed, selected is another card: wait");
  PASS(act(status(@"running", @"clock"), nil, nil, 0.1) == SoundJackAlertPlayDefault,
       "no card selected means the clock device");
  PASS(act(status(@"running", @"Audio"), nil, nil, 0.1) == SoundJackAlertKeepWaiting,
       "no card selected but a card routed: wait");

  /* the server is not (yet) there */
  PASS(act(status(@"starting", nil), @"Audio", nil, 1.0) == SoundJackAlertKeepWaiting,
       "server starting: wait");
  PASS(act(status(@"starting", nil), @"Audio", nil, 3.0) == SoundJackAlertPlayOnCard,
       "server still starting at the timeout: the card");
  PASS(act(status(@"failed", nil), @"Audio", nil, 0.0) == SoundJackAlertPlayOnCard,
       "failed: the card");
  PASS(act(status(@"disabled", nil), @"Audio", nil, 0.0) == SoundJackAlertPlayOnCard,
       "disabled: the card");
  PASS(act(nil, @"Audio", nil, 0.0) == SoundJackAlertPlayOnCard, "no status: the card");
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  testDevice();
  testAction();
  [arp release];
  return 0;
}
