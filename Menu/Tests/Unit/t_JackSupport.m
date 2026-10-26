/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The pure half of JackSupport: the jackd command line, the bridge and
   patchbay planners, the managed ~/.asoundrc block, detection filters and
   the settings.  Nothing here needs libjack or a server (t_JackSupportLive
   covers those). */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Sound/JackSupport.h"

#pragma mark Fixtures

static NSDictionary *port(NSString *name, int flags, NSArray *conns)
{
  NSRange r = [name rangeOfString: @":"];
  return [NSDictionary dictionaryWithObjectsAndKeys:
    name, @"name",
    [name substringToIndex: r.location], @"client",
    [NSNumber numberWithInt: flags], @"flags",
    [NSNumber numberWithBool: (flags & 1) != 0], @"isInput",
    [NSNumber numberWithBool: (flags & 2) != 0], @"isOutput",
    [NSNumber numberWithBool: (flags & 4) != 0], @"isPhysical",
    conns ? conns : [NSArray array], @"connections", nil];
}

/* system: capture_1/2 are physical outputs, playback_1/2 physical inputs */
static NSArray *systemPorts(void)
{
  return [NSArray arrayWithObjects:
    port(@"system:capture_1", 2 | 4 | 0x10, nil),
    port(@"system:capture_2", 2 | 4 | 0x10, nil),
    port(@"system:playback_1", 1 | 4 | 0x10, nil),
    port(@"system:playback_2", 1 | 4 | 0x10, nil), nil];
}

static NSArray *bridgePorts(NSString *cardId)
{
  return [NSArray arrayWithObjects:
    port([NSString stringWithFormat: @"gsout-%@:playback_1", cardId], 1, nil),
    port([NSString stringWithFormat: @"gsout-%@:playback_2", cardId], 1, nil),
    port([NSString stringWithFormat: @"gsin-%@:capture_1", cardId], 2, nil),
    port([NSString stringWithFormat: @"gsin-%@:capture_2", cardId], 2, nil), nil];
}

static NSArray *appOut(NSString *client, int n)
{
  NSMutableArray *a = [NSMutableArray array];
  for (int i = 1; i <= n; i++)
    [a addObject: port([NSString stringWithFormat: @"%@:out_%d", client, i], 2, nil)];
  return a;
}

static NSArray *appIn(NSString *client, int n)
{
  NSMutableArray *a = [NSMutableArray array];
  for (int i = 1; i <= n; i++)
    [a addObject: port([NSString stringWithFormat: @"%@:in_%d", client, i], 1, nil)];
  return a;
}

static NSArray *cat(NSArray *a, NSArray *b)
{
  return [a arrayByAddingObjectsFromArray: b];
}

/* Applies a plan to a port list the way JACK would. */
static NSArray *applyPlan(NSArray *ports, NSDictionary *plan)
{
  NSMutableDictionary *conn = [NSMutableDictionary dictionary];
  for (NSDictionary *p in ports)
    [conn setObject: [NSMutableSet setWithArray: [p objectForKey: @"connections"]]
             forKey: [p objectForKey: @"name"]];
  for (NSArray *op in [plan objectForKey: @"disconnect"])
    {
      [[conn objectForKey: [op objectAtIndex: 0]] removeObject: [op objectAtIndex: 1]];
      [[conn objectForKey: [op objectAtIndex: 1]] removeObject: [op objectAtIndex: 0]];
    }
  for (NSArray *op in [plan objectForKey: @"connect"])
    {
      [[conn objectForKey: [op objectAtIndex: 0]] addObject: [op objectAtIndex: 1]];
      [[conn objectForKey: [op objectAtIndex: 1]] addObject: [op objectAtIndex: 0]];
    }
  NSMutableArray *out = [NSMutableArray array];
  for (NSDictionary *p in ports)
    {
      NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary: p];
      [d setObject: [[conn objectForKey: [p objectForKey: @"name"]] allObjects]
            forKey: @"connections"];
      [out addObject: d];
    }
  return out;
}

static NSSet *pairs(NSArray *ops)
{
  NSMutableSet *s = [NSMutableSet set];
  for (NSArray *op in ops)
    [s addObject: [NSString stringWithFormat: @"%@>%@",
      [op objectAtIndex: 0], [op objectAtIndex: 1]]];
  return s;
}

static NSSet *setOf(NSString *first, ...)
{
  NSMutableSet *s = [NSMutableSet set];
  va_list ap;
  va_start(ap, first);
  for (NSString *p = first; p; p = va_arg(ap, NSString *))
    [s addObject: p];
  va_end(ap);
  return s;
}

static NSArray *strs(NSString *first, ...)
{
  NSMutableArray *a = [NSMutableArray array];
  va_list ap;
  va_start(ap, first);
  for (NSString *p = first; p; p = va_arg(ap, NSString *))
    [a addObject: p];
  va_end(ap);
  return a;
}

static NSDictionary *dev(NSString *card, NSString *hw, NSString *dir)
{
  return [NSDictionary dictionaryWithObjectsAndKeys:
    card, JackDeviceCardId, hw, JackDeviceHW, dir, JackDeviceDirection,
    card, JackDeviceDisplayName, nil];
}

static NSDictionary *plan(NSArray *ports, NSString *out, NSString *in)
{
  return [JackSupport patchbayPlanForPorts: ports outputClient: out inputClient: in];
}

#pragma mark Tests

static void testJackdArguments(void)
{
  NSString *err = nil;
  NSArray *a = [JackSupport jackdArgumentsForSettings:
    [NSDictionary dictionaryWithObject: @"hw:0" forKey: JackdDevice] error: &err];
  NSArray *want = strs(@"-d", @"alsa", @"-d", @"hw:0", @"-r", @"48000",
                       @"-p", @"1024", @"-n", @"3", nil);
  PASS_EQUAL(a, want, "defaults: rate 48000, 1024 frames, 3 periods");

  NSDictionary *s = [NSDictionary dictionaryWithObjectsAndKeys:
    @"hw:CARD=Audio,DEV=0", JackdDevice, [NSNumber numberWithInt: 44100], JackdSampleRate,
    [NSNumber numberWithInt: 256], JackdBufferFrames, [NSNumber numberWithInt: 2], JackdPeriods,
    @"gstest42", JackdServerName, nil];
  a = [JackSupport jackdArgumentsForSettings: s error: &err];
  want = strs(@"-n", @"gstest42", @"-d", @"alsa", @"-d", @"hw:CARD=Audio,DEV=0",
              @"-r", @"44100", @"-p", @"256", @"-n", @"2", nil);
  PASS_EQUAL(a, want, "server name goes before the driver, all fields honoured");

  err = nil;
  a = [JackSupport jackdArgumentsForSettings: [NSDictionary dictionary] error: &err];
  PASS(a == nil && [err length] > 0, "missing device fails hard with a message");

  NSArray *badDevs = strs(@"hw:0; rm -rf /", @"-d", @"hw 0", @"", @"hw:\"x\"", @"hw:0\n", @"$(id)", nil);
  for (NSString *bad in badDevs)
    {
      err = nil;
      a = [JackSupport jackdArgumentsForSettings:
        [NSDictionary dictionaryWithObject: bad forKey: JackdDevice] error: &err];
      PASS(a == nil && err != nil, "device '%s' rejected", [bad UTF8String]);
    }

  NSArray *badRates = [NSArray arrayWithObjects:
    [NSNumber numberWithInt: 0], [NSNumber numberWithInt: -1],
    [NSNumber numberWithInt: 7999], [NSNumber numberWithInt: 400000], nil];
  for (NSNumber *r in badRates)
    {
      NSDictionary *d = [NSDictionary dictionaryWithObjectsAndKeys:
        @"hw:0", JackdDevice, r, JackdSampleRate, nil];
      PASS([JackSupport jackdArgumentsForSettings: d error: &err] == nil,
           "rate %d rejected", [r intValue]);
    }
  NSArray *badFrames = [NSArray arrayWithObjects:
    [NSNumber numberWithInt: 0], [NSNumber numberWithInt: 1000],
    [NSNumber numberWithInt: 8], [NSNumber numberWithInt: 65536], nil];
  for (NSNumber *f in badFrames)
    {
      NSDictionary *d = [NSDictionary dictionaryWithObjectsAndKeys:
        @"hw:0", JackdDevice, f, JackdBufferFrames, nil];
      PASS([JackSupport jackdArgumentsForSettings: d error: &err] == nil,
           "frames %d rejected (power of two, 16..8192)", [f intValue]);
    }
  NSDictionary *d = [NSDictionary dictionaryWithObjectsAndKeys:
    @"hw:0", JackdDevice, [NSNumber numberWithInt: 1], JackdPeriods, nil];
  PASS([JackSupport jackdArgumentsForSettings: d error: &err] == nil, "1 period rejected");
  d = [NSDictionary dictionaryWithObjectsAndKeys:
    @"hw:0", JackdDevice, @"a b", JackdServerName, nil];
  PASS([JackSupport jackdArgumentsForSettings: d error: &err] == nil,
       "server name with a space rejected");
  d = [NSDictionary dictionaryWithObjectsAndKeys:
    @"-dummy", JackdDevice, nil];
  PASS([JackSupport jackdArgumentsForSettings: d error: &err] == nil,
       "device that looks like an option rejected");
}

static void testClockDevice(void)
{
  PASS_EQUAL([JackSupport clockDeviceForJackdArguments:
    strs(@"jackd", @"-d", @"alsa", @"-d", @"hw:1", @"-r", @"48000", nil)], @"hw:1",
    "-d alsa -d hw:1");
  PASS_EQUAL([JackSupport clockDeviceForJackdArguments:
    strs(@"/usr/bin/jackd", @"-dalsa", @"-dhw:CARD=PCH", nil)], @"hw:CARD=PCH",
    "-dalsa -dhw:CARD=PCH");
  PASS_EQUAL([JackSupport clockDeviceForJackdArguments:
    strs(@"jackd", @"-dalsa", @"--device", @"hw:2", nil)], @"hw:2", "--device hw:2");
  PASS_EQUAL([JackSupport clockDeviceForJackdArguments:
    strs(@"jackd", @"--driver=alsa", @"--device=hw:3,0", nil)], @"hw:3,0",
    "--driver=alsa --device=hw:3,0");
  PASS_EQUAL([JackSupport clockDeviceForJackdArguments:
    strs(@"jackd", @"-n", @"gstest1", @"-P", @"70", @"-d", @"alsa", @"-d", @"hw:0",
         @"-p", @"256", @"-n", @"3", nil)], @"hw:0",
    "server options before the driver, driver -n is not the device");
  PASS_EQUAL([JackSupport clockDeviceForJackdArguments:
    strs(@"-d", @"alsa", @"-d", @"hw:4", nil)], @"hw:4", "works without the program name");
  PASS_EQUAL([JackSupport clockDeviceForJackdArguments:
    strs(@"jackd", @"-d", @"alsa", @"-r", @"44100", nil)], @"hw:0",
    "alsa without -d uses jackd's own default hw:0");
  PASS([JackSupport clockDeviceForJackdArguments:
    strs(@"jackd", @"-d", @"dummy", @"-r", @"48000", @"-p", @"256", nil)] == nil,
    "dummy driver has no clock device");
  PASS([JackSupport clockDeviceForJackdArguments:
    strs(@"jackd", @"-d", @"net", @"-d", @"hw:1", nil)] == nil,
    "other driver's -d is not an ALSA device");
  PASS([JackSupport clockDeviceForJackdArguments: [NSArray array]] == nil, "empty argv");
  PASS([JackSupport clockDeviceForJackdArguments: strs(@"jackd", nil)] == nil, "no driver");
  /* the arguments we generate round-trip */
  NSArray *gen = [JackSupport jackdArgumentsForSettings:
    [NSDictionary dictionaryWithObjectsAndKeys: @"hw:CARD=Audio", JackdDevice,
     @"gsx", JackdServerName, nil] error: NULL];
  PASS_EQUAL([JackSupport clockDeviceForJackdArguments: gen], @"hw:CARD=Audio",
    "generated arguments round-trip");
}

static NSDictionary *bridgePlan(NSArray *pb, NSArray *cap, NSArray *running, NSString *clock)
{
  return [JackSupport bridgePlanForPlaybackDevices: pb captureDevices: cap
                                    runningBridges: running clockDevice: clock
                                        sampleRate: 48000 bufferFrames: 512
                                           periods: 3 serverName: nil];
}

static NSSet *names(NSArray *starts)
{
  NSMutableSet *s = [NSMutableSet set];
  for (NSDictionary *d in starts)
    [s addObject: [d objectForKey: @"name"]];
  return s;
}

static void testBridges(void)
{
  NSArray *pb = [NSArray arrayWithObjects:
    dev(@"PCH", @"hw:CARD=PCH,DEV=0", @"playback"),
    dev(@"Audio", @"hw:CARD=Audio,DEV=0", @"playback"),
    dev(@"vc4hdmi0", @"hw:CARD=vc4hdmi0,DEV=0", @"playback"), nil];
  NSArray *cap = [NSArray arrayWithObjects:
    dev(@"PCH", @"hw:CARD=PCH,DEV=0", @"capture"),
    dev(@"Audio", @"hw:CARD=Audio,DEV=0", @"capture"), nil];

  NSDictionary *p = bridgePlan(pb, cap, [NSArray array], @"hw:CARD=PCH,DEV=0");
  PASS_EQUAL(names([p objectForKey: @"start"]),
    setOf(@"gsout-Audio", @"gsout-vc4hdmi0", @"gsin-Audio", nil),
    "clock device (PCH) is never bridged, the others are, both directions");
  PASS([[p objectForKey: @"stop"] count] == 0, "nothing to stop");

  NSDictionary *first = nil;
  for (NSDictionary *d in [p objectForKey: @"start"])
    if ([[d objectForKey: @"name"] isEqual: @"gsout-Audio"])
      first = d;
  PASS_EQUAL([first objectForKey: @"executable"], @"alsa_out", "playback bridge is alsa_out");
  PASS_EQUAL([first objectForKey: @"arguments"],
    strs(@"-j", @"gsout-Audio", @"-d", @"hw:CARD=Audio,DEV=0", @"-r", @"48000",
         @"-p", @"512", @"-n", @"3", @"-q", @"1", nil),
    "alsa_out argv: -j name -d hw -r rate -p frames -n periods -q 1");
  for (NSDictionary *d in [p objectForKey: @"start"])
    if ([[d objectForKey: @"name"] isEqual: @"gsin-Audio"])
      first = d;
  PASS_EQUAL([first objectForKey: @"executable"], @"alsa_in", "capture bridge is alsa_in");
  PASS_EQUAL([[first objectForKey: @"arguments"] objectAtIndex: 1], @"gsin-Audio", "alsa_in client name");

  /* with a server name the bridge joins that server */
  p = [JackSupport bridgePlanForPlaybackDevices: pb captureDevices: cap
                                 runningBridges: [NSArray array]
                                    clockDevice: @"hw:CARD=PCH,DEV=0"
                                     sampleRate: 48000 bufferFrames: 512 periods: 3
                                     serverName: @"gstest7"];
  NSArray *args = nil;
  for (NSDictionary *d in [p objectForKey: @"start"])
    args = [d objectForKey: @"arguments"];
  PASS([args containsObject: @"-S"] && [args containsObject: @"gstest7"], "server name passed with -S");

  /* idempotent: everything running -> nothing to do */
  NSArray *running = strs(@"gsout-Audio", @"gsout-vc4hdmi0", @"gsin-Audio", nil);
  p = bridgePlan(pb, cap, running, @"hw:CARD=PCH,DEV=0");
  PASS([[p objectForKey: @"start"] count] == 0 && [[p objectForKey: @"stop"] count] == 0,
       "idempotent when all bridges run");

  /* a bridge that died is restarted */
  p = bridgePlan(pb, cap, strs(@"gsout-Audio", @"gsin-Audio", nil), @"hw:CARD=PCH,DEV=0");
  PASS_EQUAL(names([p objectForKey: @"start"]), setOf(@"gsout-vc4hdmi0", nil), "dead bridge restarted");

  /* unplugged device: its bridges stop */
  NSArray *pb2 = [NSArray arrayWithObjects: [pb objectAtIndex: 0], [pb objectAtIndex: 2], nil];
  NSArray *cap2 = [NSArray arrayWithObject: [cap objectAtIndex: 0]];
  p = bridgePlan(pb2, cap2, running, @"hw:CARD=PCH,DEV=0");
  PASS_EQUAL([NSSet setWithArray: [p objectForKey: @"stop"]],
             setOf(@"gsout-Audio", @"gsin-Audio", nil), "vanished device's bridges are stopped");
  PASS([[p objectForKey: @"start"] count] == 0, "nothing started");

  /* the clock device changes: its old bridge stops, the old clock gets one */
  p = bridgePlan(pb, cap, strs(@"gsout-PCH", @"gsin-PCH", @"gsout-vc4hdmi0", nil), @"hw:CARD=Audio,DEV=0");
  PASS([[p objectForKey: @"stop"] count] == 0, "no unexpected stops");
  p = bridgePlan(pb, cap, strs(@"gsout-Audio", @"gsin-Audio", @"gsout-vc4hdmi0", nil), @"hw:CARD=Audio,DEV=0");
  PASS_EQUAL([NSSet setWithArray: [p objectForKey: @"stop"]],
             setOf(@"gsout-Audio", @"gsin-Audio", nil), "a bridge of the new clock device is stopped");
  PASS_EQUAL(names([p objectForKey: @"start"]), setOf(@"gsout-PCH", @"gsin-PCH", nil),
             "the former clock device gets bridges");

  /* the clock device written as hw:1 (index) still excludes card index 1 */
  NSMutableDictionary *indexed = [NSMutableDictionary dictionaryWithDictionary: [pb objectAtIndex: 0]];
  [indexed setObject: [NSNumber numberWithInt: 1] forKey: JackDeviceCardIndex];
  p = bridgePlan([NSArray arrayWithObject: indexed], [NSArray array], [NSArray array], @"hw:1");
  PASS([[p objectForKey: @"start"] count] == 0, "hw:1 excludes the card with index 1");
  p = bridgePlan([NSArray arrayWithObject: indexed], [NSArray array], [NSArray array], @"hw:PCH,0");
  PASS([[p objectForKey: @"start"] count] == 0, "hw:PCH,0 excludes card PCH");
  p = bridgePlan([NSArray arrayWithObject: indexed], [NSArray array], [NSArray array], @"hw:CARD=PCH,DEV=3");
  PASS([[p objectForKey: @"start"] count] == 1, "another device number of the clock card is a different device");
  p = bridgePlan([NSArray arrayWithObject: indexed], [NSArray array], [NSArray array], nil);
  PASS([[p objectForKey: @"start"] count] == 1, "no clock device known: nothing excluded");

  /* foreign running clients are never touched; hostile ids are not bridged */
  p = bridgePlan(pb, cap, strs(@"gsout-Audio", @"gsin-Audio", @"gsout-vc4hdmi0", @"firefox",
                               @"gershwin-sound", @"system", nil), @"hw:CARD=PCH,DEV=0");
  PASS([[p objectForKey: @"stop"] count] == 0, "only gsout-/gsin- names are managed");
  NSArray *evil = [NSArray arrayWithObject: dev(@"a;b", @"hw:CARD=X,DEV=0", @"playback")];
  p = bridgePlan(evil, [NSArray array], [NSArray array], nil);
  PASS_EQUAL(names([p objectForKey: @"start"]), setOf(@"gsout-a_b", nil), "card id sanitised into a client name");
  evil = [NSArray arrayWithObject: dev(@"X", @"hw:X; reboot", @"playback")];
  p = bridgePlan(evil, [NSArray array], [NSArray array], nil);
  PASS([[p objectForKey: @"start"] count] == 0 && [[p objectForKey: @"errors"] count] == 1,
       "bad hw name is reported and not started");
  PASS_EQUAL([JackSupport bridgeClientNameForCardId: @"Audio" direction: @"capture"],
             @"gsin-Audio", "capture client name");
}

static void testPatchbayPlayback(void)
{
  /* stereo app, system selected */
  NSArray *ports = cat(systemPorts(), cat(bridgePorts(@"Audio"), appOut(@"mpv", 2)));
  NSDictionary *p = plan(ports, @"system", nil);
  PASS_EQUAL(pairs([p objectForKey: @"connect"]),
    setOf(@"mpv:out_1>system:playback_1", @"mpv:out_2>system:playback_2", nil),
    "stereo app goes pairwise to the selected device");
  PASS([[p objectForKey: @"disconnect"] count] == 0, "nothing to disconnect");

  /* bridged device selected */
  p = plan(ports, @"gsout-Audio", nil);
  PASS_EQUAL(pairs([p objectForKey: @"connect"]),
    setOf(@"mpv:out_1>gsout-Audio:playback_1", @"mpv:out_2>gsout-Audio:playback_2", nil),
    "bridged device as target");

  /* mono app feeds all device ports */
  ports = cat(systemPorts(), appOut(@"beep", 1));
  p = plan(ports, @"system", nil);
  PASS_EQUAL(pairs([p objectForKey: @"connect"]),
    setOf(@"beep:out_1>system:playback_1", @"beep:out_1>system:playback_2", nil), "mono app feeds both");

  /* 4 port app: extra ports are left */
  ports = cat(systemPorts(), appOut(@"daw", 4));
  p = plan(ports, @"system", nil);
  PASS_EQUAL(pairs([p objectForKey: @"connect"]),
    setOf(@"daw:out_1>system:playback_1", @"daw:out_2>system:playback_2", nil),
    "ports beyond the device's are left unconnected");

  /* natural order: out_10 sorts after out_2 */
  ports = cat(systemPorts(), appOut(@"daw", 10));
  p = plan(ports, @"system", nil);
  PASS_EQUAL(pairs([p objectForKey: @"connect"]),
    setOf(@"daw:out_1>system:playback_1", @"daw:out_2>system:playback_2", nil),
    "port order is numeric, not lexical");

  /* switching: app on system, selection moves to the bridged device */
  NSMutableArray *ports2 = [NSMutableArray array];
  for (NSDictionary *q in cat(systemPorts(), cat(bridgePorts(@"Audio"), appOut(@"mpv", 2))))
    [ports2 addObject: q];
  ports = applyPlan(ports2, plan(ports2, @"system", nil));
  p = plan(ports, @"gsout-Audio", nil);
  PASS_EQUAL(pairs([p objectForKey: @"disconnect"]),
    setOf(@"mpv:out_1>system:playback_1", @"mpv:out_2>system:playback_2", nil),
    "disconnected from the other device's playback ports");
  PASS_EQUAL(pairs([p objectForKey: @"connect"]),
    setOf(@"mpv:out_1>gsout-Audio:playback_1", @"mpv:out_2>gsout-Audio:playback_2", nil),
    "and connected to the selected one");

  /* already correct: nothing to do, and a plan is idempotent when applied */
  ports = applyPlan(ports, p);
  p = plan(ports, @"gsout-Audio", nil);
  PASS([[p objectForKey: @"connect"] count] == 0 && [[p objectForKey: @"disconnect"] count] == 0,
       "already-correct connections are not repeated");

  /* partially right: only the missing one is added */
  NSMutableArray *half = [NSMutableArray array];
  for (NSDictionary *q in cat(systemPorts(), appOut(@"mpv", 2)))
    {
      NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary: q];
      if ([[q objectForKey: @"name"] isEqual: @"mpv:out_1"])
        [m setObject: strs(@"system:playback_1", nil) forKey: @"connections"];
      if ([[q objectForKey: @"name"] isEqual: @"system:playback_1"])
        [m setObject: strs(@"mpv:out_1", nil) forKey: @"connections"];
      [half addObject: m];
    }
  p = plan(half, @"system", nil);
  PASS_EQUAL(pairs([p objectForKey: @"connect"]), setOf(@"mpv:out_2>system:playback_2", nil),
             "only the missing connection is made");

  /* crossed wiring to the selected device is corrected */
  NSMutableArray *crossed = [NSMutableArray array];
  for (NSDictionary *q in cat(systemPorts(), appOut(@"mpv", 2)))
    {
      NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary: q];
      if ([[q objectForKey: @"name"] isEqual: @"mpv:out_1"])
        [m setObject: strs(@"system:playback_2", nil) forKey: @"connections"];
      [crossed addObject: m];
    }
  p = plan(crossed, @"system", nil);
  PASS_EQUAL(pairs([p objectForKey: @"disconnect"]), setOf(@"mpv:out_1>system:playback_2", nil),
             "crossed wiring to the selected device is removed");

  /* connections to other applications are not ours */
  NSMutableArray *mix = [NSMutableArray array];
  for (NSDictionary *q in cat(systemPorts(), cat(appOut(@"mpv", 2), appIn(@"recorder", 2))))
    {
      NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary: q];
      if ([[q objectForKey: @"name"] isEqual: @"mpv:out_1"])
        [m setObject: strs(@"recorder:in_1", nil) forKey: @"connections"];
      [mix addObject: m];
    }
  p = plan(mix, @"system", nil);
  PASS([[p objectForKey: @"disconnect"] count] == 0, "a connection to another application is left alone");

  /* two apps */
  ports = cat(systemPorts(), cat(appOut(@"a", 2), appOut(@"b", 1)));
  p = plan(ports, @"system", nil);
  PASS([[p objectForKey: @"connect"] count] == 4, "each app is routed independently");
}

static void testPatchbayIgnores(void)
{
  /* gershwin-sound's own ports (also when JACK made the name unique) */
  NSArray *ports = cat(systemPorts(),
    cat(appOut(@"gershwin-sound", 2), appOut(@"gershwin-sound-01", 2)));
  NSDictionary *p = plan(ports, @"system", @"system");
  PASS([[p objectForKey: @"connect"] count] == 0, "ports of gershwin-sound are ignored");

  /* bridge ports and physical ports are not applications */
  ports = cat(systemPorts(), bridgePorts(@"Audio"));
  p = plan(ports, @"system", @"system");
  PASS([[p objectForKey: @"connect"] count] == 0 && [[p objectForKey: @"disconnect"] count] == 0,
       "devices are not routed to each other");

  /* ALSA jack plugin client counts as an application */
  ports = cat(systemPorts(), cat(bridgePorts(@"Audio"),
    cat([NSArray arrayWithObjects: port(@"aplay.P.123.0:out_000", 2, nil),
         port(@"aplay.P.123.0:out_001", 2, nil), nil],
        [NSArray arrayWithObjects: port(@"arecord.C.123.0:in_000", 1, nil),
         port(@"arecord.C.123.0:in_001", 1, nil), nil])));
  p = plan(ports, @"gsout-Audio", @"gsin-Audio");
  PASS_EQUAL(pairs([p objectForKey: @"connect"]),
    setOf(@"aplay.P.123.0:out_000>gsout-Audio:playback_1",
          @"aplay.P.123.0:out_001>gsout-Audio:playback_2",
          @"gsin-Audio:capture_1>arecord.C.123.0:in_000",
          @"gsin-Audio:capture_2>arecord.C.123.0:in_001", nil),
    "ALSA jack plugin clients are routed both ways");
}

static void testPatchbayCapture(void)
{
  NSArray *ports = cat(systemPorts(), cat(bridgePorts(@"Audio"), appIn(@"audacity", 2)));
  NSDictionary *p = plan(ports, nil, @"system");
  PASS_EQUAL(pairs([p objectForKey: @"connect"]),
    setOf(@"system:capture_1>audacity:in_1", @"system:capture_2>audacity:in_2", nil),
    "capture ports go pairwise to the application");
  p = plan(ports, nil, @"gsin-Audio");
  PASS_EQUAL(pairs([p objectForKey: @"connect"]),
    setOf(@"gsin-Audio:capture_1>audacity:in_1", @"gsin-Audio:capture_2>audacity:in_2", nil),
    "bridged capture device");

  /* switch the input: the old device is disconnected */
  NSArray *applied = applyPlan(ports, plan(ports, nil, @"system"));
  p = plan(applied, nil, @"gsin-Audio");
  PASS_EQUAL(pairs([p objectForKey: @"disconnect"]),
    setOf(@"system:capture_1>audacity:in_1", @"system:capture_2>audacity:in_2", nil),
    "disconnected from the other input device");
  PASS([[p objectForKey: @"connect"] count] == 2, "connected to the new input device");
  applied = applyPlan(applied, p);
  p = plan(applied, nil, @"gsin-Audio");
  PASS([[p objectForKey: @"connect"] count] == 0 && [[p objectForKey: @"disconnect"] count] == 0,
       "capture side idempotent");

  /* mono application gets the first capture port; mono device feeds all */
  ports = cat(systemPorts(), appIn(@"tuner", 1));
  p = plan(ports, nil, @"system");
  PASS_EQUAL(pairs([p objectForKey: @"connect"]), setOf(@"system:capture_1>tuner:in_1", nil),
             "mono capture client gets the first port");
  ports = cat([NSArray arrayWithObject: port(@"gsin-Mic:capture_1", 2, nil)], appIn(@"rec", 2));
  p = plan(ports, nil, @"gsin-Mic");
  PASS_EQUAL(pairs([p objectForKey: @"connect"]),
    setOf(@"gsin-Mic:capture_1>rec:in_1", @"gsin-Mic:capture_1>rec:in_2", nil),
    "mono device feeds all application ports");
}

static void testPatchbayMissing(void)
{
  NSArray *ports = cat(systemPorts(), appOut(@"mpv", 2));
  NSDictionary *p = plan(ports, @"gsout-Gone", nil);
  PASS([[p objectForKey: @"connect"] count] == 0 && [[p objectForKey: @"disconnect"] count] == 0,
       "missing output device: nothing done");
  PASS([[p objectForKey: @"problems"] count] >= 1, "missing output device is reported");

  /* app currently on the system device keeps playing while the device is missing */
  NSArray *routed = applyPlan(ports, plan(ports, @"system", nil));
  p = plan(routed, @"gsout-Gone", nil);
  PASS([[p objectForKey: @"disconnect"] count] == 0, "no disconnect when the target is missing");

  p = plan(ports, nil, nil);
  PASS([[p objectForKey: @"connect"] count] == 0, "nothing selected: nothing done");
  PASS([[p objectForKey: @"problems"] count] == 2, "nothing selected is reported for both sides");

  /* a missing input does not stop the output side */
  p = plan(ports, @"system", @"gsin-Gone");
  PASS([[p objectForKey: @"connect"] count] == 2, "output side still routed");
  PASS([[p objectForKey: @"problems"] count] == 1, "only the input side reported");
}

static void testAsoundrc(void)
{
  NSString *block = [JackSupport asoundrcJackBlock];
  PASS([block hasPrefix: @"# BEGIN gershwin jack\n"] && [block hasSuffix: @"# END gershwin jack\n"],
       "block is marked");
  PASS([block rangeOfString: @"pcm.!default"].location != NSNotFound, "block overrides the default pcm");
  PASS([block rangeOfString: @"type jack"].location != NSNotFound, "uses the jack plugin");
  PASS([block rangeOfString: @"system:playback_1"].location != NSNotFound, "ports the plugin can connect to");
  PASS([block canBeConvertedToEncoding: NSASCIIStringEncoding],
       "ASCII only");

  NSString *orig = @"pcm.!default {\n    type hw\n    card 0\n}\n";
  NSString *err = nil;
  NSString *applied = [JackSupport asoundrcByApplyingJackBlockTo: orig error: &err];
  PASS([applied hasPrefix: orig], "existing content untouched and first (the later definition wins in ALSA)");
  PASS([JackSupport asoundrcHasJackBlock: applied], "block present");
  PASS(![JackSupport asoundrcHasJackBlock: orig], "block absent in the original");
  PASS_EQUAL([JackSupport asoundrcByRemovingJackBlockFrom: applied error: &err], orig,
             "remove restores the original byte for byte");

  NSString *twice = [JackSupport asoundrcByApplyingJackBlockTo: applied error: &err];
  PASS_EQUAL(twice, applied, "applying twice is idempotent");

  /* replace a stale block in place, content before and after untouched */
  NSString *stale = [NSString stringWithFormat:
    @"head\n\n# BEGIN gershwin jack\nold stuff\n# END gershwin jack\ntail\n"];
  NSString *fresh = [JackSupport asoundrcByApplyingJackBlockTo: stale error: &err];
  NSString *want = [NSString stringWithFormat: @"head\n\n%@tail\n", block];
  PASS_EQUAL(fresh, want, "stale block replaced in place");

  /* the odd originals */
  NSArray *origs = strs(@"", @"\n", @"no trailing newline", @"two\n\n", @"# comment\n\n\nx {\n}\n", nil);
  for (NSString *o in origs)
    {
      NSString *a = [JackSupport asoundrcByApplyingJackBlockTo: o error: &err];
      PASS([JackSupport asoundrcHasJackBlock: a], "block applied to %lu bytes", (unsigned long)[o length]);
      PASS_EQUAL([JackSupport asoundrcByRemovingJackBlockFrom: a error: &err], o,
                 "roundtrip exact for original of %lu bytes", (unsigned long)[o length]);
      PASS_EQUAL([JackSupport asoundrcByApplyingJackBlockTo: a error: &err], a, "idempotent too");
    }
  PASS_EQUAL([JackSupport asoundrcByRemovingJackBlockFrom: orig error: &err], orig,
             "removing from text without a block changes nothing");

  err = nil;
  PASS([JackSupport asoundrcByApplyingJackBlockTo: @"x\n# BEGIN gershwin jack\nbroken\n" error: &err] == nil
       && err != nil, "damaged block (no END) fails hard");
  err = nil;
  PASS([JackSupport asoundrcByRemovingJackBlockFrom: @"x\n# BEGIN gershwin jack\nbroken\n" error: &err] == nil
       && err != nil, "damaged block cannot be removed silently");
}

static NSString *section(NSString *key, NSString *a, NSString *b)
{
  return [NSString stringWithFormat: @"    %@ {\n        0 %@\n        1 %@\n    }\n", key, a, b];
}

static void testAsoundrcRouted(void)
{
  /* the default block is the one naming the system ports */
  NSArray *sysPb = strs(@"system:playback_1", @"system:playback_2", nil);
  NSArray *sysCap = strs(@"system:capture_1", @"system:capture_2", nil);
  PASS_EQUAL([JackSupport asoundrcJackBlockWithPlaybackPorts: sysPb capturePorts: sysCap],
             [JackSupport asoundrcJackBlock], "default block = system ports");

  NSString *mono = [JackSupport asoundrcJackBlockWithPlaybackPorts: sysPb
                                                      capturePorts: strs(@"gsin-Microphone:capture_1", nil)];
  PASS([mono rangeOfString: section(@"capture_ports", @"gsin-Microphone:capture_1",
                                    @"gsin-Microphone:capture_1")].location != NSNotFound,
       "a single port serves both channels");
  NSString *noCap = [JackSupport asoundrcJackBlockWithPlaybackPorts: sysPb capturePorts: [NSArray array]];
  PASS([noCap rangeOfString: @"capture_ports"].location == NSNotFound
       && [noCap rangeOfString: section(@"playback_ports", @"system:playback_1", @"system:playback_2")].location
          != NSNotFound, "no capture port at all: no capture section, playback kept");
  NSString *bad = [JackSupport asoundrcJackBlockWithPlaybackPorts: strs(@"x\"y:1", @"a b:2", @"ok:3", nil)
                                                     capturePorts: [NSArray array]];
  PASS([bad rangeOfString: section(@"playback_ports", @"ok:3", @"ok:3")].location != NSNotFound,
       "names that would break the config are skipped");

  /* the Bose headset case: six playback ports, no capture; a mono USB mic bridged */
  NSMutableArray *ports = [NSMutableArray array];
  for (int i = 12; i >= 1; i--)
    [ports addObject: port([NSString stringWithFormat: @"system:playback_%d", i], 1 | 4, nil)];
  NSArray *withMic = cat(ports, [NSArray arrayWithObject: port(@"gsin-Microphone:capture_1", 2, nil)]);
  NSString *b = [JackSupport asoundrcJackBlockForPorts: withMic outputClient: @"system"
                                           inputClient: @"gsin-Microphone"];
  PASS([b rangeOfString: section(@"playback_ports", @"system:playback_1", @"system:playback_2")].location
       != NSNotFound, "playback: the first two system ports in port order");
  PASS([b rangeOfString: section(@"capture_ports", @"gsin-Microphone:capture_1",
                                 @"gsin-Microphone:capture_1")].location != NSNotFound,
       "capture: the routed mono mic bridge on both channels");
  b = [JackSupport asoundrcJackBlockForPorts: withMic outputClient: @"system" inputClient: @"system"];
  PASS([b rangeOfString: @"0 gsin-Microphone:capture_1"].location != NSNotFound,
       "routed input without capture ports: the first capture port there is");
  b = [JackSupport asoundrcJackBlockForPorts: ports outputClient: @"system" inputClient: @"system"];
  PASS([b rangeOfString: @"capture_ports"].location == NSNotFound, "no capture port anywhere: no capture section");
  NSArray *bridged = cat(cat(systemPorts(), bridgePorts(@"USB")), appOut(@"firefox", 2));
  b = [JackSupport asoundrcJackBlockForPorts: bridged outputClient: @"gsout-USB" inputClient: @"gsin-USB"];
  PASS([b rangeOfString: @"0 gsout-USB:playback_1"].location != NSNotFound
       && [b rangeOfString: @"0 gsin-USB:capture_1"].location != NSNotFound, "bridged clients named");
  b = [JackSupport asoundrcJackBlockForPorts: bridged outputClient: @"gsout-Gone" inputClient: nil];
  PASS([b rangeOfString: @"0 system:playback_1"].location != NSNotFound,
       "a routed client without ports falls back to system");

  /* custom blocks keep the exact roundtrip and replace each other in place */
  NSString *err = nil;
  NSArray *origs = strs(@"", @"\n", @"no trailing newline", @"pcm.!default {\n    type hw\n    card 0\n}\n", nil);
  for (NSString *o in origs)
    {
      NSString *a = [JackSupport asoundrcByApplyingJackBlock: mono to: o error: &err];
      NSString *c = [JackSupport asoundrcByApplyingJackBlock: noCap to: a error: &err];
      PASS([c rangeOfString: @"capture_ports"].location == NSNotFound && ([o length] == 0 || [c hasPrefix: o]),
           "a new block replaces the old one (%lu bytes)", (unsigned long)[o length]);
      PASS_EQUAL([JackSupport asoundrcByRemovingJackBlockFrom: c error: &err], o,
                 "roundtrip exact after a block change (%lu bytes)", (unsigned long)[o length]);
    }
}

static NSDictionary *proc(int pid, int uid, NSString *comm, NSArray *argv)
{
  return [NSDictionary dictionaryWithObjectsAndKeys:
    [NSNumber numberWithInt: pid], @"pid", [NSNumber numberWithInt: uid], @"uid",
    comm, @"comm", argv ? argv : [NSArray array], @"argv", nil];
}

static void testDetection(void)
{
  NSArray *table = [NSArray arrayWithObjects:
    proc(10, 1000, @"jackd", strs(@"jackd", @"-d", @"alsa", nil)),
    proc(11, 1000, @"jackdbus", nil),
    proc(12, 1001, @"jackd", nil),
    proc(13, 1000, @"bash", strs(@"bash", @"-c", @"jackd", nil)),
    proc(14, 1000, @"jackd-helper", nil),
    proc(15, 1000, @"alsa_out", nil), nil];
  NSArray *pids = [JackSupport jackdProcessIDsInTable: table forUID: 1000];
  PASS_EQUAL(pids, ([NSArray arrayWithObjects: [NSNumber numberWithInt: 10], [NSNumber numberWithInt: 11], nil]),
             "own jackd and jackdbus only, not another user's, not by argv");
  PASS([[JackSupport jackdProcessIDsInTable: table forUID: 4] count] == 0, "none for another uid");
  PASS([[JackSupport jackdProcessIDsInTable: [NSArray array] forUID: 0] count] == 0, "empty table");
  NSArray *procs = [JackSupport jackdProcessesInTable: table forUID: 1000];
  PASS_EQUAL([[procs objectAtIndex: 0] objectForKey: @"argv"], strs(@"jackd", @"-d", @"alsa", nil),
             "entries carry argv for the clock device");

  BOOL (^exists)(NSString *) = ^BOOL(NSString *p) {
    return [p isEqual: @"/opt/bin/jackd"] || [p isEqual: @"/usr/local/bin/jackd"]; };
  PASS([JackSupport isJackdAvailableWithPATH: @"/bin:/opt/bin" fileExists: exists], "found on PATH");
  PASS([JackSupport isJackdAvailableWithPATH: @"/bin" fileExists: exists], "found in /usr/local/bin fallback");
  BOOL (^none)(NSString *) = ^BOOL(NSString *p) { return NO; };
  PASS(![JackSupport isJackdAvailableWithPATH: @"/bin:/opt/bin" fileExists: none], "not available");
  PASS(![JackSupport isJackdAvailableWithPATH: nil fileExists: none], "nil PATH");
  BOOL (^usr)(NSString *) = ^BOOL(NSString *p) { return [p isEqual: @"/usr/bin/jackd"]; };
  PASS([JackSupport isJackdAvailableWithPATH: @"" fileExists: usr], "empty PATH still checks /usr/bin");
  PASS([JackSupport isJackdAvailableWithPATH: @"::/opt/bin::" fileExists: exists], "empty PATH entries skipped");
}

static NSDictionary *idxDev(NSString *cardId, NSString *hw, int index)
{
  return [NSDictionary dictionaryWithObjectsAndKeys: cardId, JackDeviceCardId, hw, JackDeviceHW,
    [NSNumber numberWithInt: index], JackDeviceCardIndex, nil];
}

static void testIsClockDevice(void)
{
  NSDictionary *pch = idxDev(@"PCH", @"hw:CARD=PCH,DEV=0", 0);
  PASS([JackSupport isDevice: pch clockDevice: @"hw:CARD=PCH,DEV=0"], "same hw name");
  PASS([JackSupport isDevice: pch clockDevice: @"hw:0"], "by card index");
  PASS([JackSupport isDevice: pch clockDevice: @"hw:PCH"], "by bare card id");
  PASS(![JackSupport isDevice: pch clockDevice: @"hw:PCH,3"], "other device of the card");
  PASS(![JackSupport isDevice: pch clockDevice: nil], "no clock device (dummy driver)");
  PASS(![JackSupport isDevice: idxDev(@"USB", @"hw:CARD=USB,DEV=0", 1) clockDevice: @"hw:0"],
       "other card");
}

static void testSelection(void)
{
  NSArray *pb = [NSArray arrayWithObjects:
    idxDev(@"PCH_0", @"hw:CARD=PCH,DEV=0", 0), idxDev(@"PCH_3", @"hw:CARD=PCH,DEV=3", 0),
    idxDev(@"USB", @"hw:CARD=USB,DEV=0", 1), nil];
  NSString *sel = @"x";
  PASS([JackSupport selectedDeviceInDevices: pb jackCard: nil alsaDefault: nil selection: &sel] == nil
       && sel == nil, "nothing selected");
  NSDictionary *d = [JackSupport selectedDeviceInDevices: pb jackCard: @"PCH_3" alsaDefault: @"USB.0"
                                               selection: &sel];
  PASS_EQUAL([d objectForKey: JackDeviceCardId], @"PCH_3", "the JACK card wins over the ALSA default");
  PASS_EQUAL(sel, @"PCH_3", "selection named");
  d = [JackSupport selectedDeviceInDevices: pb jackCard: @"Gone" alsaDefault: @"USB.0" selection: &sel];
  PASS(d == nil && [sel isEqual: @"Gone"], "selected JACK card unplugged: none, named");
  d = [JackSupport selectedDeviceInDevices: pb jackCard: nil alsaDefault: @"PCH.3" selection: &sel];
  PASS_EQUAL([d objectForKey: JackDeviceCardId], @"PCH_3", "ALSA default card.device");
  d = [JackSupport selectedDeviceInDevices: pb jackCard: nil alsaDefault: @"USB.0" selection: &sel];
  PASS_EQUAL([d objectForKey: JackDeviceCardId], @"USB", "ALSA default of a single-PCM card");
  d = [JackSupport selectedDeviceInDevices: pb jackCard: nil alsaDefault: @"hw:1,0" selection: &sel];
  PASS_EQUAL([d objectForKey: JackDeviceCardId], @"USB", "ALSA default hw:N,M (card without id)");
  d = [JackSupport selectedDeviceInDevices: pb jackCard: nil alsaDefault: @"PCH.7" selection: &sel];
  PASS(d == nil && [sel isEqual: @"PCH.7"], "ALSA default not present: none, named");
}

static void testSettings(void)
{
  NSString *dir = [NSString stringWithFormat: @"%@/gwjacktest.%d",
    NSTemporaryDirectory(), (int)getpid()];
  [[NSFileManager defaultManager] removeItemAtPath: dir error: NULL];
  NSString *path = [dir stringByAppendingPathComponent: @"sub/sound-defaults.plist"];
  PASS(![path hasPrefix: NSHomeDirectory()] || ![[JackSupport defaultSettingsPath] isEqual: path],
       "test uses its own path, not the real one");

  NSDictionary *s = [JackSupport settingsAtPath: path];
  PASS([[s objectForKey: JackSettingUseJack] boolValue] == NO, "UseJack defaults to NO");
  PASS([[s objectForKey: JackSettingBufferFrames] intValue] == 1024, "buffer defaults to 1024");
  PASS([[s objectForKey: JackSettingSampleRate] intValue] == 48000, "rate defaults to 48000");
  PASS([s objectForKey: JackSettingOutputCard] == nil && [s objectForKey: JackSettingALSAOutput] == nil,
       "no selection by default");

  NSString *err = nil;
  NSDictionary *set = [NSDictionary dictionaryWithObjectsAndKeys:
    [NSNumber numberWithBool: YES], JackSettingUseJack,
    [NSNumber numberWithInt: 256], JackSettingBufferFrames, nil];
  PASS([JackSupport setSettings: set atPath: path error: &err], "written (%s)", err ? [err UTF8String] : "ok");
  s = [JackSupport settingsAtPath: path];
  PASS([[s objectForKey: JackSettingUseJack] boolValue] == YES, "UseJack read back");
  PASS([[s objectForKey: JackSettingBufferFrames] intValue] == 256, "buffer read back");
  PASS([[s objectForKey: JackSettingSampleRate] intValue] == 48000, "unset rate keeps default");

  /* the keys ALSABackend owns survive */
  NSMutableDictionary *raw = [NSMutableDictionary dictionaryWithContentsOfFile: path];
  [raw setObject: @"hw:0" forKey: @"defaultOutput"];
  [raw writeToFile: path atomically: YES];
  PASS([JackSupport setSettings: [NSDictionary dictionaryWithObject: [NSNumber numberWithInt: 44100]
                                                              forKey: JackSettingSampleRate]
                         atPath: path error: &err], "second write");
  raw = [NSMutableDictionary dictionaryWithContentsOfFile: path];
  PASS_EQUAL([raw objectForKey: @"defaultOutput"], @"hw:0", "other keys left alone");
  PASS_EQUAL([[JackSupport settingsAtPath: path] objectForKey: JackSettingALSAOutput], @"hw:0",
             "the ALSA default output is read");
  PASS([[raw objectForKey: JackSettingUseJack] boolValue] == YES, "earlier JACK keys kept");
  PASS([[raw objectForKey: JackSettingSampleRate] intValue] == 44100, "rate updated");

  err = nil;
  PASS(![JackSupport setSettings: [NSDictionary dictionaryWithObject: [NSNumber numberWithInt: 1000]
                                                               forKey: JackSettingBufferFrames]
                          atPath: path error: &err] && err != nil, "invalid buffer size refused");
  PASS(![JackSupport setSettings: [NSDictionary dictionaryWithObject: @"x" forKey: @"Bogus"]
                          atPath: path error: &err], "unknown key refused");
  PASS(![JackSupport setSettings: [NSDictionary dictionaryWithObject: @"hw:CARD=PCH"
                                                              forKey: @"JackClockDevice"]
                          atPath: path error: &err], "the old clock device setting is gone");
  PASS(![JackSupport setSettings: [NSDictionary dictionaryWithObject: @"PCH.0"
                                                              forKey: JackSettingALSAOutput]
                          atPath: path error: &err], "the ALSA defaults are not ours to write");

  /* an old file with JackClockDevice: ignored */
  raw = [NSMutableDictionary dictionaryWithContentsOfFile: path];
  [raw setObject: @"hw:CARD=PCH,DEV=0" forKey: @"JackClockDevice"];
  [raw setObject: @"bad value;" forKey: @"defaultInput"];
  [raw writeToFile: path atomically: YES];
  s = [JackSupport settingsAtPath: path];
  PASS([s objectForKey: @"JackClockDevice"] == nil, "a stale JackClockDevice is not read");
  PASS([s objectForKey: JackSettingALSAInput] == nil, "an invalid ALSA default is not read");

  /* corrupt file values fall back to defaults when read */
  raw = [NSMutableDictionary dictionaryWithContentsOfFile: path];
  [raw setObject: @"garbage" forKey: JackSettingBufferFrames];
  [raw writeToFile: path atomically: YES];
  PASS([[[JackSupport settingsAtPath: path] objectForKey: JackSettingBufferFrames] intValue] == 1024,
       "garbage value reads as the default");

  /* the routing keys of the supervisor */
  PASS([[JackSupport settingsAtPath: path] objectForKey: JackSettingOutputCard] == nil,
       "no output card by default");
  PASS_EQUAL(JackSettingOutputCard, @"JackOutputCard", "output key name");
  PASS_EQUAL(JackSettingInputCard, @"JackInputCard", "input key name");
  NSDictionary *cards = [NSDictionary dictionaryWithObjectsAndKeys:
    @"USB", JackSettingOutputCard, @"HDMI_3", JackSettingInputCard, nil];
  PASS([JackSupport setSettings: cards atPath: path error: &err], "card keys written");
  s = [JackSupport settingsAtPath: path];
  PASS_EQUAL([s objectForKey: JackSettingOutputCard], @"USB", "output card read back");
  PASS_EQUAL([s objectForKey: JackSettingInputCard], @"HDMI_3", "input card read back");
  PASS(![JackSupport setSettings: [NSDictionary dictionaryWithObject: @"a b"
                                                              forKey: JackSettingOutputCard]
                          atPath: path error: &err], "invalid card id refused");
  PASS([JackSupport setSettings: [NSDictionary dictionaryWithObject: [NSNull null]
                                                             forKey: JackSettingOutputCard]
                         atPath: path error: &err]
       && [[JackSupport settingsAtPath: path] objectForKey: JackSettingOutputCard] == nil,
       "output card cleared");
  [[NSFileManager defaultManager] removeItemAtPath: dir error: NULL];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  testJackdArguments();
  testClockDevice();
  testBridges();
  testPatchbayPlayback();
  testPatchbayIgnores();
  testPatchbayCapture();
  testPatchbayMissing();
  testAsoundrc();
  testAsoundrcRouted();
  testDetection();
  testSettings();
  testIsClockDevice();
  testSelection();
  [arp release];
  return 0;
}
