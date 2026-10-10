/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* JackSupervisor in a fake world: processes, the JACK server, the clock and
   the timer are simulated, the files (settings, ~/.asoundrc, the status
   plist, /proc/asound) are real files in a temporary directory.  Needs no
   jackd; t_JackSupervisorLive runs the real thing. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Sound/JackSupport.h"
#import "Sound/JackSupervisor.h"
#include <signal.h>
#include <sys/stat.h>

@class FakeEnv;

#pragma mark Fake processes

@interface FakeProcess : NSObject <JackSupervisorProcess>
{
@public
  pid_t pid;
  BOOL alive;
  BOOL ignoresTerm;
  NSString *comm;
  NSString *client;     // bridges: their JACK client name
}
@end

@implementation FakeProcess
- (void) dealloc { [comm release]; [client release]; [super dealloc]; }
- (pid_t) processIdentifier { return pid; }
- (BOOL) isRunning { return alive; }
@end

#pragma mark Fake server

@interface FakeServer : NSObject <JackSupervisorServer>
{
@public
  NSMutableArray *ports;
  NSUInteger rate, frames;
  BOOL activated, closed;
  NSUInteger connects, disconnects, bufferSets;
}
- (void) addPort: (NSString *)name flags: (int)flags;
- (void) removeClient: (NSString *)client;
- (BOOL) is: (NSString *)src connectedTo: (NSString *)dst;
@end

@implementation FakeServer
- (id) init
{
  if ((self = [super init]) != nil)
    {
      ports = [NSMutableArray new];
      rate = 48000;
      frames = 1024;
    }
  return self;
}
- (void) dealloc { [ports release]; [super dealloc]; }
- (void) addPort: (NSString *)name flags: (int)flags
{
  NSRange r = [name rangeOfString: @":"];
  [ports addObject: [NSMutableDictionary dictionaryWithObjectsAndKeys:
    name, @"name", [name substringToIndex: r.location], @"client",
    [NSNumber numberWithInt: flags], @"flags",
    [NSNumber numberWithBool: (flags & 1) != 0], @"isInput",
    [NSNumber numberWithBool: (flags & 2) != 0], @"isOutput",
    [NSNumber numberWithBool: (flags & 4) != 0], @"isPhysical",
    [NSMutableArray array], @"connections", nil]];
}
- (NSMutableDictionary *) port: (NSString *)name
{
  for (NSMutableDictionary *p in ports)
    if ([[p objectForKey: @"name"] isEqual: name]) return p;
  return nil;
}
- (void) removeClient: (NSString *)client
{
  NSMutableArray *gone = [NSMutableArray array];
  for (NSMutableDictionary *p in ports)
    if ([[p objectForKey: @"client"] isEqual: client]) [gone addObject: p];
  for (NSMutableDictionary *p in gone)
    {
      for (NSString *other in [[[p objectForKey: @"connections"] copy] autorelease])
        [[[self port: other] objectForKey: @"connections"] removeObject: [p objectForKey: @"name"]];
      [ports removeObject: p];
    }
}
- (BOOL) is: (NSString *)src connectedTo: (NSString *)dst
{
  return [[[self port: src] objectForKey: @"connections"] containsObject: dst];
}
- (NSUInteger) sampleRate { return closed ? 0 : rate; }
- (NSUInteger) bufferFrames { return closed ? 0 : frames; }
- (BOOL) setBufferFrames: (NSUInteger)f
{
  activated = YES;
  bufferSets++;
  frames = f;
  return YES;
}
- (NSArray *) allPorts
{
  if (closed) return nil;
  NSMutableArray *copy = [NSMutableArray array];
  for (NSDictionary *p in ports)
    {
      NSMutableDictionary *d = [[p mutableCopy] autorelease];
      [d setObject: [[[p objectForKey: @"connections"] copy] autorelease] forKey: @"connections"];
      [copy addObject: d];
    }
  return copy;
}
- (BOOL) connect: (NSString *)src to: (NSString *)dst
{
  activated = YES;
  connects++;
  if (![self port: src] || ![self port: dst]) return NO;
  if (![self is: src connectedTo: dst])
    {
      [[[self port: src] objectForKey: @"connections"] addObject: dst];
      [[[self port: dst] objectForKey: @"connections"] addObject: src];
    }
  return YES;
}
- (BOOL) disconnect: (NSString *)src from: (NSString *)dst
{
  activated = YES;
  disconnects++;
  [[[self port: src] objectForKey: @"connections"] removeObject: dst];
  [[[self port: dst] objectForKey: @"connections"] removeObject: src];
  return YES;
}
- (void) close { closed = YES; activated = NO; }
@end

#pragma mark Fake environment

@interface FakeEnv : NSObject <JackSupervisorEnvironment>
{
@public
  BOOL platform, installed, plugin;
  NSString *dir;
  NSTimeInterval now;
  NSMutableArray *table;        // foreign processes: pid, comm, argv
  NSMutableArray *children;     // FakeProcess we launched
  NSMutableArray *launches;     // {exe, args, log, limit}
  NSMutableDictionary *cpu;     // pid -> CPU seconds
  NSMutableArray *signals;      // @[sig, pid]
  NSMutableArray *blockAtJackdTerm;  // asoundrc had the block when jackd got TERM
  BOOL serverUp, autoUp, launchFails, bridgesDie;
  FakeServer *server;
  NSUInteger opens;
  BOOL timer;
  NSUInteger timersMade;
  void (^watch)(void);
  pid_t nextPid;
}
- (NSString *) path: (NSString *)name;
@end

@implementation FakeEnv
- (id) init
{
  if ((self = [super init]) != nil)
    {
      platform = installed = plugin = YES;
      static int n = 0;
      dir = [[NSString alloc] initWithFormat: @"%@/gwjacksup.%d.%d", NSTemporaryDirectory(), (int)getpid(), n++];
      [[NSFileManager defaultManager] removeItemAtPath: dir error: NULL];
      [[NSFileManager defaultManager] createDirectoryAtPath: [dir stringByAppendingPathComponent: @"asound"]
                                withIntermediateDirectories: YES attributes: nil error: NULL];
      now = 1000;
      table = [NSMutableArray new];
      children = [NSMutableArray new];
      launches = [NSMutableArray new];
      signals = [NSMutableArray new];
      cpu = [NSMutableDictionary new];
      blockAtJackdTerm = [NSMutableArray new];
      server = [FakeServer new];
      [server addPort: @"system:playback_1" flags: 1 | 4];
      [server addPort: @"system:playback_2" flags: 1 | 4];
      [server addPort: @"system:capture_1" flags: 2 | 4];
      [server addPort: @"system:capture_2" flags: 2 | 4];
      nextPid = 5000;
    }
  return self;
}
- (void) dealloc
{
  [[NSFileManager defaultManager] removeItemAtPath: dir error: NULL];
  [dir release]; [table release]; [children release]; [launches release];
  [signals release]; [cpu release]; [blockAtJackdTerm release]; [server release]; [watch release];
  [super dealloc];
}
- (NSString *) path: (NSString *)name { return [dir stringByAppendingPathComponent: name]; }
- (BOOL) isPlatformSupported { return platform; }
- (BOOL) isJackdInstalled { return installed; }
- (BOOL) isALSAJackPluginInstalled { return plugin; }
- (NSString *) serverName { return @"gsfake"; }
- (NSString *) settingsPath { return [self path: @"sound-defaults.plist"]; }
- (NSString *) asoundrcPath { return [self path: @"asoundrc"]; }
- (NSString *) statusPath { return [self path: @"cache/jack-status.plist"]; }
- (NSString *) logDirectory { return [self path: @"cache"]; }
- (NSString *) alsaProcRoot { return [self path: @"asound"]; }
- (NSString *) alsaDevRoot { return [self path: @"dev"]; }
- (double) cpuSecondsOfProcess: (pid_t)p
{
  NSNumber *n = [cpu objectForKey: [NSNumber numberWithInt: p]];
  return n ? [n doubleValue] : 0;
}
- (NSTimeInterval) now { return now; }
- (void) sleepFor: (NSTimeInterval)s { now += s; }
- (NSArray *) userProcessesNamed: (NSArray *)names
{
  NSMutableArray *r = [NSMutableArray array];
  for (NSDictionary *e in table)
    if ([names containsObject: [e objectForKey: @"comm"]]) [r addObject: e];
  return r;
}
- (FakeProcess *) child: (pid_t)pid
{
  for (FakeProcess *p in children) if (p->pid == pid) return p;
  return nil;
}
- (BOOL) isProcessAlive: (pid_t)pid named: (NSString *)comm
{
  FakeProcess *c = [self child: pid];
  if (c) return c->alive && [c->comm isEqual: comm];
  for (NSDictionary *e in table)
    if ([[e objectForKey: @"pid"] intValue] == pid && [[e objectForKey: @"comm"] isEqual: comm]) return YES;
  return NO;
}
- (BOOL) asoundrcHasBlock
{
  NSString *t = [NSString stringWithContentsOfFile: [self asoundrcPath] encoding: NSUTF8StringEncoding error: NULL];
  return t && [JackSupport asoundrcHasJackBlock: t];
}
- (void) die: (FakeProcess *)c
{
  c->alive = NO;
  if ([c->comm isEqual: @"jackd"]) serverUp = NO;
  if (c->client) [server removeClient: c->client];
}
- (void) sendSignal: (int)sig toProcess: (pid_t)pid
{
  [signals addObject: [NSArray arrayWithObjects: [NSNumber numberWithInt: sig], [NSNumber numberWithInt: pid], nil]];
  pid_t target = pid < 0 ? -pid : pid;
  FakeProcess *c = [self child: target];
  if (c)
    {
      if ([c->comm isEqual: @"jackd"] && sig == SIGTERM)
        [blockAtJackdTerm addObject: [NSNumber numberWithBool: [self asoundrcHasBlock]]];
      if (sig == SIGKILL || !c->ignoresTerm) [self die: c];
      return;
    }
  NSDictionary *gone = nil;
  for (NSDictionary *e in table)
    if ([[e objectForKey: @"pid"] intValue] == target) gone = e;
  if (gone)
    {
      NSString *client = nil;
      NSUInteger i = [[gone objectForKey: @"argv"] indexOfObject: @"-j"];
      if (i != NSNotFound) client = [[gone objectForKey: @"argv"] objectAtIndex: i + 1];
      if (client) [server removeClient: client];
      [table removeObject: gone];
    }
}
- (id<JackSupervisorProcess>) launchExecutable: (NSString *)exe arguments: (NSArray *)args
                                       logPath: (NSString *)log fileSizeLimit: (unsigned long long)limit
                                         error: (NSString **)error
{
  [launches addObject: [NSDictionary dictionaryWithObjectsAndKeys: exe, @"exe", args, @"args", log, @"log",
    [NSNumber numberWithUnsignedLongLong: limit], @"limit", nil]];
  if (launchFails)
    {
      *error = @"simulated launch failure";
      return nil;
    }
  FakeProcess *p = [[FakeProcess new] autorelease];
  p->pid = nextPid++;
  p->alive = YES;
  p->comm = [exe copy];
  [children addObject: p];
  if ([exe isEqual: @"jackd"] && autoUp) serverUp = YES;
  if ([exe isEqual: @"alsa_out"] || [exe isEqual: @"alsa_in"])
    {
      NSString *name = [args objectAtIndex: [args indexOfObject: @"-j"] + 1];
      p->client = [name copy];
      if (bridgesDie)
        p->alive = NO;
      else if ([exe isEqual: @"alsa_out"])
        {
          [server addPort: [name stringByAppendingString: @":playback_1"] flags: 1];
          [server addPort: [name stringByAppendingString: @":playback_2"] flags: 1];
        }
      else
        {
          [server addPort: [name stringByAppendingString: @":capture_1"] flags: 2];
          [server addPort: [name stringByAppendingString: @":capture_2"] flags: 2];
        }
    }
  return p;
}
- (id<JackSupervisorServer>) openServer
{
  if (!serverUp) return nil;
  opens++;
  server->closed = NO;
  return server;
}
- (BOOL) watchSettingsWithBlock: (void (^)(void))b error: (NSString **)error
{
  [watch release];
  watch = [b copy];
  return YES;
}
- (void) stopWatchingSettings { [watch release]; watch = nil; }
- (id) scheduleTimerWithInterval: (NSTimeInterval)i block: (void (^)(void))b
{
  timer = YES;
  timersMade++;
  return @"timer";
}
- (void) cancelTimer: (id)t { timer = NO; }
@end

#pragma mark Helpers

static void writeCards(FakeEnv *e, NSArray *cards)
{
  /* cards: arrays of @[index, id, @[pcm entries]]; the /dev/snd nodes of
     cards that stay keep their identity, like a card that is not touched */
  NSString *root = [e alsaProcRoot];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *devRoot = [e alsaDevRoot];
  [fm createDirectoryAtPath: devRoot withIntermediateDirectories: YES attributes: nil error: NULL];
  NSMutableSet *nodes = [NSMutableSet set];
  for (NSArray *c in cards)
    for (NSString *pcm in [c objectAtIndex: 2])
      if ([pcm hasPrefix: @"pcm"])
        [nodes addObject: [NSString stringWithFormat: @"pcmC%dD%@", [[c objectAtIndex: 0] intValue],
          [pcm substringFromIndex: 3]]];
  for (NSString *n in [fm contentsOfDirectoryAtPath: devRoot error: NULL])
    if (![nodes containsObject: n]) [fm removeItemAtPath: [devRoot stringByAppendingPathComponent: n] error: NULL];
  for (NSString *n in nodes)
    {
      NSString *path = [devRoot stringByAppendingPathComponent: n];
      if (![fm fileExistsAtPath: path]) [@"" writeToFile: path atomically: NO encoding: NSUTF8StringEncoding error: NULL];
    }
  for (NSString *entry in [fm contentsOfDirectoryAtPath: root error: NULL])
    [fm removeItemAtPath: [root stringByAppendingPathComponent: entry] error: NULL];
  NSMutableString *text = [NSMutableString string];
  for (NSArray *c in cards)
    {
      [text appendFormat: @"%2d [%-15@]: USB-Audio - %@ device\n                      Long name\n",
        [[c objectAtIndex: 0] intValue], [c objectAtIndex: 1], [c objectAtIndex: 1]];
      NSString *cdir = [root stringByAppendingPathComponent:
        [NSString stringWithFormat: @"card%d", [[c objectAtIndex: 0] intValue]]];
      for (NSString *pcm in [c objectAtIndex: 2])
        [fm createDirectoryAtPath: [cdir stringByAppendingPathComponent: pcm]
      withIntermediateDirectories: YES attributes: nil error: NULL];
    }
  [text writeToFile: [root stringByAppendingPathComponent: @"cards"] atomically: YES
           encoding: NSUTF8StringEncoding error: NULL];
}

/* The kernel enumerated the device again: a new node, so a new inode (made
   before the old one goes, so the inode cannot be reused). */
static void reenumerate(FakeEnv *e, NSString *node)
{
  NSString *path = [[e alsaDevRoot] stringByAppendingPathComponent: node];
  NSString *tmp = [path stringByAppendingString: @".new"];
  [@"" writeToFile: tmp atomically: NO encoding: NSUTF8StringEncoding error: NULL];
  rename([tmp fileSystemRepresentation], [path fileSystemRepresentation]);
}

static NSArray *card(int i, NSString *cid, NSArray *pcms)
{
  return [NSArray arrayWithObjects: [NSNumber numberWithInt: i], cid, pcms, nil];
}

static NSArray *PCH(void) { return card(0, @"PCH", [NSArray arrayWithObjects: @"pcm0p", @"pcm0c", nil]); }
static NSArray *USB(void) { return card(1, @"USB", [NSArray arrayWithObjects: @"pcm0p", @"pcm0c", nil]); }

static void setSettings(FakeEnv *e, NSDictionary *d)
{
  NSString *err = nil;
  if (![JackSupport setSettings: d atPath: [e settingsPath] error: &err])
    fprintf(stderr, "setSettings failed: %s\n", [err UTF8String]);
  if (e->watch) e->watch();
}

static NSDictionary *on(void)
{
  return [NSDictionary dictionaryWithObject: [NSNumber numberWithBool: YES] forKey: JackSettingUseJack];
}

static NSString *asoundrc(FakeEnv *e)
{
  return [NSString stringWithContentsOfFile: [e asoundrcPath] encoding: NSUTF8StringEncoding error: NULL];
}

static NSUInteger launchesOf(FakeEnv *e, NSString *exe)
{
  NSUInteger n = 0;
  for (NSDictionary *l in e->launches) if ([[l objectForKey: @"exe"] isEqual: exe]) n++;
  return n;
}

static NSDictionary *lastLaunch(FakeEnv *e, NSString *exe)
{
  NSDictionary *r = nil;
  for (NSDictionary *l in e->launches) if ([[l objectForKey: @"exe"] isEqual: exe]) r = l;
  return r;
}

static BOOL signalled(FakeEnv *e, int sig, pid_t pid)
{
  for (NSArray *s in e->signals)
    if ([[s objectAtIndex: 0] intValue] == sig && [[s objectAtIndex: 1] intValue] == pid) return YES;
  return NO;
}

static void tickFor(JackSupervisor *s, FakeEnv *e, int seconds)
{
  for (int i = 0; i < seconds; i++)
    {
      e->now += 1;
      [s tick];
    }
}

static NSString *stateOf(JackSupervisor *s)
{
  return [[s statusDictionary] objectForKey: JackStatusState];
}

static NSUInteger notifications = 0;

@interface Counter : NSObject
@end
@implementation Counter
- (void) note: (NSNotification *)n { notifications++; }
@end

#pragma mark Tests

static void testDevices(void)
{
  FakeEnv *e = [[FakeEnv new] autorelease];
  writeCards(e, [NSArray arrayWithObjects: PCH(),
    card(1, @"USB", [NSArray arrayWithObject: @"pcm0p"]),
    card(2, @"HDMI", [NSArray arrayWithObjects: @"pcm3p", @"pcm7p", @"pcm6c", @"info", nil]), nil]);
  NSDictionary *d = [JackSupervisor alsaDevicesAtRoot: [e alsaProcRoot]];
  NSArray *p = [d objectForKey: @"playback"];
  NSArray *c = [d objectForKey: @"capture"];
  PASS([p count] == 4 && [c count] == 2, "4 playback, 2 capture devices");
  PASS_EQUAL([[p objectAtIndex: 0] objectForKey: JackDeviceCardId], @"PCH", "single-device card keeps its id");
  PASS_EQUAL([[p objectAtIndex: 0] objectForKey: JackDeviceHW], @"hw:CARD=PCH,DEV=0", "hw name by card id");
  PASS_EQUAL([[p objectAtIndex: 1] objectForKey: JackDeviceCardId], @"USB", "playback-only card");
  PASS_EQUAL([[p objectAtIndex: 2] objectForKey: JackDeviceCardId], @"HDMI_3", "several devices: id_dev");
  PASS_EQUAL([[p objectAtIndex: 3] objectForKey: JackDeviceHW], @"hw:CARD=HDMI,DEV=7", "dev 7");
  PASS_EQUAL([[c objectAtIndex: 1] objectForKey: JackDeviceCardId], @"HDMI_6", "capture id_dev");
  PASS([[[p objectAtIndex: 2] objectForKey: JackDeviceCardIndex] intValue] == 2, "card index");
  PASS_EQUAL([[p objectAtIndex: 1] objectForKey: JackDeviceDisplayName], @"USB device", "display name");
  PASS([[[JackSupervisor alsaDevicesAtRoot: [e path: @"nothing"]] objectForKey: @"playback"] count] == 0,
       "no /proc/asound: no devices");
}

static void testHelpers(void)
{
  NSArray *a1 = [NSArray arrayWithObjects: @"jackd", @"-d", @"alsa", @"-n", @"3", nil];
  NSArray *a2 = [NSArray arrayWithObjects: @"jackd", @"-n", @"x1", @"-d", @"alsa", nil];
  NSArray *a3 = [NSArray arrayWithObjects: @"--name=x2", @"-ddummy", nil];
  PASS_EQUAL([JackSupervisor serverNameForJackdArguments: a1], @"default",
    "-n after the driver is the period count");
  PASS_EQUAL([JackSupervisor serverNameForJackdArguments: a2], @"x1", "server name");
  PASS_EQUAL([JackSupervisor serverNameForJackdArguments: a3], @"x2", "--name= without program");

  PASS([JackSupervisor menuTitleForStatus: [NSDictionary dictionaryWithObject: JackStateDisabled
                                                                       forKey: JackStatusState]] == nil,
       "no menu line when JACK is off");
  NSDictionary *run = [NSDictionary dictionaryWithObjectsAndKeys: JackStateRunning, JackStatusState,
    [NSNumber numberWithInt: 48000], JackStatusSampleRate, [NSNumber numberWithInt: 1024], JackStatusBufferFrames, nil];
  PASS_EQUAL([JackSupervisor menuTitleForStatus: run], @"JACK: running, 48 kHz, 1024 frames", "running line");
  run = [NSDictionary dictionaryWithObjectsAndKeys: JackStateRunning, JackStatusState,
    [NSNumber numberWithInt: 44100], JackStatusSampleRate, [NSNumber numberWithInt: 256], JackStatusBufferFrames, nil];
  PASS_EQUAL([JackSupervisor menuTitleForStatus: run], @"JACK: running, 44.1 kHz, 256 frames", "44.1 kHz");
  PASS_EQUAL([JackSupervisor menuTitleForStatus: [NSDictionary dictionaryWithObject: JackStateStarting
    forKey: JackStatusState]], @"JACK: starting...", "starting line");
  PASS_EQUAL([JackSupervisor menuTitleForStatus: [NSDictionary dictionaryWithObject: JackStateFailed
    forKey: JackStatusState]], @"JACK: failed, see log", "failed line");
}

static void testIdle(void)
{
  FakeEnv *e = [[FakeEnv new] autorelease];
  e->platform = NO;
  setSettings(e, on());
  JackSupervisor *s = [[[JackSupervisor alloc] initWithEnvironment: e] autorelease];
  [s start];
  PASS([stateOf(s) isEqual: JackStateUnavailable] && ![s isTimerScheduled] && e->watch == nil
       && [e->launches count] == 0, "not Linux: unavailable, no timer, no watch, nothing started");
  PASS(![[NSFileManager defaultManager] fileExistsAtPath: [e statusPath]], "not Linux: no status file");
  [s stop];

  e = [[FakeEnv new] autorelease];
  e->installed = NO;
  setSettings(e, on());
  s = [[[JackSupervisor alloc] initWithEnvironment: e] autorelease];
  [s start];
  PASS([stateOf(s) isEqual: JackStateUnavailable] && ![s isTimerScheduled] && [e->launches count] == 0,
       "no jackd: unavailable, no timer");
  PASS_EQUAL([JackSupervisor menuTitleForStatus: [s statusDictionary]], @"JACK: unavailable", "menu says so");
  [s stop];

  e = [[FakeEnv new] autorelease];
  writeCards(e, [NSArray arrayWithObject: PCH()]);
  s = [[[JackSupervisor alloc] initWithEnvironment: e] autorelease];
  [s start];
  PASS([stateOf(s) isEqual: JackStateDisabled] && ![s isTimerScheduled] && e->watch != nil
       && [e->launches count] == 0 && asoundrc(e) == nil,
       "UseJack off: disabled, no timer, only the settings watch");
  NSUInteger reads = [s settingsReadCount];
  e->watch();
  e->watch();
  PASS([s settingsReadCount] == reads, "unchanged settings file is not parsed again");
  NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile: [e statusPath]];
  PASS_EQUAL([st objectForKey: JackStatusState], JackStateDisabled, "status file says disabled");
  [s stop];
}

static void testLifecycle(void)
{
  FakeEnv *e = [[FakeEnv new] autorelease];
  writeCards(e, [NSArray arrayWithObject: PCH()]);
  NSString *original = @"# mine\npcm.!default { type hw card 0 }\n";
  [original writeToFile: [e asoundrcPath] atomically: NO encoding: NSUTF8StringEncoding error: NULL];
  chmod([[e asoundrcPath] fileSystemRepresentation], 0600);

  Counter *counter = [[Counter new] autorelease];
  JackSupervisor *s = [[[JackSupervisor alloc] initWithEnvironment: e] autorelease];
  [[NSNotificationCenter defaultCenter] addObserver: counter selector: @selector(note:)
    name: JackSupervisorStatusDidChangeNotification object: s];
  [s start];
  PASS(![s isTimerScheduled], "off at first");

  notifications = 0;
  setSettings(e, on());
  PASS([s isTimerScheduled], "turning JACK on starts the timer");
  PASS(notifications == 1, "status change notified");
  [s tick];
  NSDictionary *l = lastLaunch(e, @"jackd");
  NSArray *want = [NSArray arrayWithObjects: @"-n", @"gsfake", @"-d", @"alsa", @"-d", @"hw:CARD=PCH,DEV=0",
    @"-r", @"48000", @"-p", @"1024", @"-n", @"3", nil];
  PASS_EQUAL([l objectForKey: @"args"], want, "jackd launched on the first playback device");
  PASS_EQUAL([l objectForKey: @"log"], [e path: @"cache/jackd.log"], "jackd log in the cache dir");
  PASS([stateOf(s) isEqual: JackStateStarting], "starting");
  PASS(![e asoundrcHasBlock], "no block while starting");
  PASS_EQUAL([JackSupervisor menuTitleForStatus: [s statusDictionary]], @"JACK: starting...", "menu: starting");

  e->serverUp = YES;
  tickFor(s, e, 1);
  NSDictionary *st = [s statusDictionary];
  PASS([[st objectForKey: JackStatusState] isEqual: JackStateRunning]
       && [[st objectForKey: JackStatusOwner] isEqual: @"own"], "running, own");
  PASS([[st objectForKey: JackStatusSampleRate] intValue] == 48000
       && [[st objectForKey: JackStatusBufferFrames] intValue] == 1024, "rate and frames from the server");
  PASS_EQUAL([st objectForKey: JackStatusClockDevice], @"hw:CARD=PCH,DEV=0", "clock device in status");
  PASS([e asoundrcHasBlock], "block added while running");
  PASS([asoundrc(e) hasPrefix: original], "the user's text kept in front");
  struct stat sb;
  stat([[e asoundrcPath] fileSystemRepresentation], &sb);
  PASS((sb.st_mode & 0777) == 0600, "file mode kept");
  NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile: [e statusPath]];
  PASS_EQUAL([file objectForKey: JackStatusState], JackStateRunning, "status file says running");
  PASS([[file objectForKey: @"ownJackdPid"] intValue] == 5000, "status file records our jackd");

  /* an application plays: routed to the clock device */
  [e->server addPort: @"app:out_1" flags: 2];
  [e->server addPort: @"app:out_2" flags: 2];
  [e->server addPort: @"app:in_1" flags: 1];
  tickFor(s, e, 1);
  PASS([e->server is: @"app:out_1" connectedTo: @"system:playback_1"]
       && [e->server is: @"app:out_2" connectedTo: @"system:playback_2"]
       && [e->server is: @"system:capture_1" connectedTo: @"app:in_1"], "patchbay routes to system");
  PASS(e->server->closed, "the activated client is closed after the tick");
  NSUInteger opens = e->opens;
  NSUInteger connects = e->server->connects;
  tickFor(s, e, 3);
  PASS(e->server->connects == connects, "nothing to do: no connect calls");
  PASS(e->opens == opens + 1 && !e->server->closed && !e->server->activated,
       "a passive client stays open across ticks");

  /* a USB card is plugged in: nobody selected it, so no bridge */
  writeCards(e, [NSArray arrayWithObjects: PCH(), USB(), nil]);
  tickFor(s, e, 1);
  PASS(launchesOf(e, @"alsa_out") == 0 && launchesOf(e, @"alsa_in") == 0, "unselected USB is not bridged");
  /* selecting it bridges it; jackd keeps running on PCH */
  NSMutableDictionary *sel = [NSMutableDictionary dictionaryWithDictionary: on()];
  [sel setObject: @"USB" forKey: JackSettingOutputCard];
  setSettings(e, sel);
  PASS(!signalled(e, SIGTERM, -5000) && launchesOf(e, @"jackd") == 1, "selection change: jackd not restarted");
  tickFor(s, e, 1);
  PASS(launchesOf(e, @"alsa_out") == 1 && launchesOf(e, @"alsa_in") == 0, "only the selected output bridged");
  NSArray *bargs = [lastLaunch(e, @"alsa_out") objectForKey: @"args"];
  PASS([bargs containsObject: @"gsout-USB"] && [bargs containsObject: @"hw:CARD=USB,DEV=0"]
       && [bargs containsObject: @"gsfake"], "alsa_out argv: client, device, server");
  PASS_EQUAL([[s statusDictionary] objectForKey: JackStatusBridges],
             ([NSArray arrayWithObjects: @"gsout-USB", nil]), "bridge in status");
  tickFor(s, e, 1);
  PASS([e->server is: @"app:out_1" connectedTo: @"gsout-USB:playback_1"]
       && ![e->server is: @"app:out_1" connectedTo: @"system:playback_1"], "output moved to USB");
  PASS([e->server is: @"system:capture_1" connectedTo: @"app:in_1"], "input stays on system");
  PASS_EQUAL([[s statusDictionary] objectForKey: JackStatusOutputClient], @"gsout-USB", "status: routed to USB");
  PASS([[[s statusDictionary] objectForKey: JackStatusOutputBridged] boolValue], "status: output bridged");
  PASS_EQUAL([[s statusDictionary] objectForKey: JackStatusDrivenDevice], @"PCH device", "status: driven device");

  /* the bridge crashes: restarted after a back-off, not every second */
  FakeProcess *bridge = nil;
  for (FakeProcess *p in e->children) if ([p->client isEqual: @"gsout-USB"]) bridge = p;
  [e die: bridge];
  tickFor(s, e, 1);
  PASS(launchesOf(e, @"alsa_out") == 1, "not restarted at once");
  tickFor(s, e, 2);
  PASS(launchesOf(e, @"alsa_out") == 2, "restarted after 2 s");

  /* unplugged: bridge stopped, routing falls back, setting kept */
  writeCards(e, [NSArray arrayWithObject: PCH()]);
  tickFor(s, e, 1);
  PASS([[[s statusDictionary] objectForKey: JackStatusBridges] count] == 0, "bridges stopped on unplug");
  PASS(signalled(e, SIGTERM, 5002), "SIGTERM to the bridge");
  PASS([e->server is: @"app:out_1" connectedTo: @"system:playback_1"], "routing falls back to system");
  PASS([[[s statusDictionary] objectForKey: JackStatusMessage] rangeOfString: @"USB"].location != NSNotFound
       && [[[s statusDictionary] objectForKey: JackStatusMessage] rangeOfString: @"PCH device"].location != NSNotFound,
       "status reports the missing device and what plays instead");
  PASS(![[[s statusDictionary] objectForKey: JackStatusOutputBridged] boolValue], "status: not bridged");
  PASS_EQUAL([[JackSupport settingsAtPath: [e settingsPath]] objectForKey: JackSettingOutputCard], @"USB",
             "setting kept");

  /* buffer size: set live, no restart */
  [sel setObject: [NSNumber numberWithInt: 256] forKey: JackSettingBufferFrames];
  setSettings(e, sel);
  PASS(e->server->bufferSets == 1 && launchesOf(e, @"jackd") == 1, "buffer change applied live");
  tickFor(s, e, 1);
  PASS([[[s statusDictionary] objectForKey: JackStatusBufferFrames] intValue] == 256,
       "status follows the server's buffer size");

  /* sample rate change: block removed before jackd is stopped, then restart */
  [sel setObject: [NSNumber numberWithInt: 44100] forKey: JackSettingSampleRate];
  [e->blockAtJackdTerm removeAllObjects];
  setSettings(e, sel);
  PASS([e->blockAtJackdTerm count] == 1 && [[e->blockAtJackdTerm objectAtIndex: 0] boolValue] == NO,
       "block gone before jackd got SIGTERM");
  PASS(signalled(e, SIGTERM, -5000), "SIGTERM to jackd's process group");
  PASS([asoundrc(e) isEqual: original], "asoundrc restored byte for byte");
  tickFor(s, e, 1);
  PASS(launchesOf(e, @"jackd") == 2 && [[lastLaunch(e, @"jackd") objectForKey: @"args"] containsObject: @"44100"],
       "jackd restarted with the new rate");
  e->serverUp = YES;
  tickFor(s, e, 1);
  PASS([stateOf(s) isEqual: JackStateRunning] && [e asoundrcHasBlock], "running again, block back");

  /* jackd crashes */
  FakeProcess *jd = nil;
  for (FakeProcess *p in e->children) if ([p->comm isEqual: @"jackd"] && p->alive) jd = p;
  [e die: jd];
  tickFor(s, e, 1);
  PASS(![e asoundrcHasBlock], "block removed when jackd dies");
  PASS([stateOf(s) isEqual: JackStateFailed], "failed, retrying");
  e->autoUp = YES;
  tickFor(s, e, 3);
  PASS(launchesOf(e, @"jackd") == 3, "restarted after the back-off");
  tickFor(s, e, 1);
  PASS([stateOf(s) isEqual: JackStateRunning], "running again");

  /* stop: block first, bridges and our jackd killed */
  writeCards(e, [NSArray arrayWithObjects: PCH(), USB(), nil]);
  [sel setObject: @"USB" forKey: JackSettingInputCard];
  setSettings(e, sel);
  PASS([[[s statusDictionary] objectForKey: JackStatusBridges] count] == 1, "one bridge started at once");
  e->now += 0.5;
  [s tick];
  PASS([[[s statusDictionary] objectForKey: JackStatusBridges] count] == 1, "the next not within a second");
  e->now += 0.5;
  [s tick];
  tickFor(s, e, 1);
  PASS([[[s statusDictionary] objectForKey: JackStatusBridges] count] == 2, "bridges running before stop");
  [e->blockAtJackdTerm removeAllObjects];
  [s stop];
  PASS([e->blockAtJackdTerm count] == 1 && ![[e->blockAtJackdTerm objectAtIndex: 0] boolValue],
       "stop: block removed before jackd is signalled");
  BOOL allDead = YES;
  for (FakeProcess *p in e->children) if (p->alive) allDead = NO;
  PASS(allDead, "stop: every child is gone");
  PASS([asoundrc(e) isEqual: original] && ![s isTimerScheduled] && e->watch == nil,
       "stop: file restored, no timer, no watch");
  PASS_EQUAL([[NSDictionary dictionaryWithContentsOfFile: [e statusPath]] objectForKey: JackStatusState],
             JackStateDisabled, "status file says disabled");
  [[NSNotificationCenter defaultCenter] removeObserver: counter];
}

static void testTurnOff(void)
{
  FakeEnv *e = [[FakeEnv new] autorelease];
  writeCards(e, [NSArray arrayWithObject: PCH()]);
  e->autoUp = YES;
  setSettings(e, on());
  JackSupervisor *s = [[[JackSupervisor alloc] initWithEnvironment: e] autorelease];
  [s start];
  tickFor(s, e, 1);
  PASS([stateOf(s) isEqual: JackStateRunning] && [e asoundrcHasBlock], "running");
  setSettings(e, [NSDictionary dictionaryWithObject: [NSNumber numberWithBool: NO] forKey: JackSettingUseJack]);
  PASS([stateOf(s) isEqual: JackStateDisabled] && ![s isTimerScheduled] && asoundrc(e) == nil
       && signalled(e, SIGTERM, -5000), "turned off: stopped, no timer, the block's file removed again");
  PASS(e->watch != nil, "still watching the settings");
  [s stop];
}

static void testStartFailures(void)
{
  FakeEnv *e = [[FakeEnv new] autorelease];
  writeCards(e, [NSArray arrayWithObject: PCH()]);
  setSettings(e, on());
  JackSupervisor *s = [[[JackSupervisor alloc] initWithEnvironment: e] autorelease];
  [s start];
  PASS(launchesOf(e, @"jackd") == 1, "first attempt at start");
  tickFor(s, e, 10);
  PASS(signalled(e, SIGTERM, -5000) && [stateOf(s) isEqual: JackStateFailed],
       "no answer within 10 s: killed, failed");
  tickFor(s, e, 1);
  PASS(launchesOf(e, @"jackd") == 1, "no immediate retry");
  e->launchFails = YES;
  tickFor(s, e, 1);
  PASS(launchesOf(e, @"jackd") == 2, "retry after 2 s");
  tickFor(s, e, 3);
  PASS(launchesOf(e, @"jackd") == 2, "next retry not before 4 s");
  tickFor(s, e, 1);
  PASS(launchesOf(e, @"jackd") == 3, "third attempt after 4 s");
  tickFor(s, e, 8);
  PASS(launchesOf(e, @"jackd") == 4, "fourth after 8 s");
  tickFor(s, e, 16);
  PASS(launchesOf(e, @"jackd") == 5 && [stateOf(s) isEqual: JackStateFailed] && ![s isTimerScheduled],
       "fifth failure: gave up, timer stopped");
  PASS([[[s statusDictionary] objectForKey: JackStatusMessage] rangeOfString: @"gave up"].location != NSNotFound,
       "message says it gave up");
  tickFor(s, e, 120);
  PASS(launchesOf(e, @"jackd") == 5, "no more attempts");
  e->launchFails = NO;
  e->autoUp = YES;
  NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary: on()];
  [d setObject: [NSNumber numberWithInt: 512] forKey: JackSettingBufferFrames];
  setSettings(e, d);
  PASS([s isTimerScheduled], "a settings change resets: timer back");
  tickFor(s, e, 2);
  PASS(launchesOf(e, @"jackd") == 6 && [stateOf(s) isEqual: JackStateRunning], "started after the reset");
  [s stop];

  /* no playback device at all */
  e = [[FakeEnv new] autorelease];
  writeCards(e, [NSArray array]);
  setSettings(e, on());
  s = [[[JackSupervisor alloc] initWithEnvironment: e] autorelease];
  [s start];
  PASS(launchesOf(e, @"jackd") == 0 && [stateOf(s) isEqual: JackStateFailed], "no device: failed, nothing launched");
  [s stop];

  /* a bridge that cannot run is given up after 5 tries */
  e = [[FakeEnv new] autorelease];
  writeCards(e, [NSArray arrayWithObjects: PCH(), card(1, @"USB", [NSArray arrayWithObject: @"pcm0p"]), nil]);
  e->autoUp = YES;
  e->bridgesDie = YES;
  NSMutableDictionary *usb = [NSMutableDictionary dictionaryWithDictionary: on()];
  [usb setObject: @"USB" forKey: JackSettingOutputCard];
  setSettings(e, usb);
  /* a jackd of the user on PCH, so the selected USB card needs a bridge */
  [e->table addObject: [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithInt: 990], @"pid",
    @"jackd", @"comm", [NSArray arrayWithObjects: @"jackd", @"-n", @"gsfake", @"-d", @"alsa", @"-d",
    @"hw:CARD=PCH,DEV=0", nil], @"argv", nil]];
  e->serverUp = YES;
  s = [[[JackSupervisor alloc] initWithEnvironment: e] autorelease];
  [s start];
  tickFor(s, e, 120);
  PASS(launchesOf(e, @"alsa_out") == 5, "dying bridge started 5 times, then given up");
  [s stop];
}

static void testAdopted(void)
{
  FakeEnv *e = [[FakeEnv new] autorelease];
  writeCards(e, [NSArray arrayWithObjects: PCH(), USB(), nil]);
  [e->table addObject: [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithInt: 777], @"pid",
    @"jackd", @"comm", [NSArray arrayWithObjects: @"jackd", @"-n", @"gsfake", @"-d", @"alsa", @"-d", @"hw:1", nil],
    @"argv", nil]];
  /* a jackd of another server name is not ours to adopt */
  [e->table addObject: [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithInt: 778], @"pid",
    @"jackd", @"comm", [NSArray arrayWithObjects: @"jackd", @"-d", @"dummy", nil], @"argv", nil]];
  /* a bridge a crashed supervisor left behind */
  [e->table addObject: [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithInt: 880], @"pid",
    @"alsa_in", @"comm", [NSArray arrayWithObjects: @"alsa_in", @"-j", @"gsin-PCH", @"-d", @"hw:CARD=PCH,DEV=0",
    @"-S", @"gsfake", nil], @"argv", nil]];
  [e->server addPort: @"gsin-PCH:capture_1" flags: 2];
  e->serverUp = YES;
  setSettings(e, on());
  JackSupervisor *s = [[[JackSupervisor alloc] initWithEnvironment: e] autorelease];
  [s start];
  NSDictionary *st = [s statusDictionary];
  PASS(launchesOf(e, @"jackd") == 0 && [[st objectForKey: JackStatusState] isEqual: JackStateRunning]
       && [[st objectForKey: JackStatusOwner] isEqual: @"adopted"], "the user's jackd is adopted");
  PASS_EQUAL([st objectForKey: JackStatusClockDevice], @"hw:1", "clock device from its command line");
  PASS(launchesOf(e, @"alsa_in") == 0 && launchesOf(e, @"alsa_out") == 0 && signalled(e, SIGTERM, 880),
       "nothing selected: the orphaned gsin-PCH is taken over and stopped, nothing bridged");
  PASS_EQUAL([st objectForKey: JackStatusDrivenDevice], @"USB device", "driven device of the adopted jackd");
  PASS([e asoundrcHasBlock], "block added for the adopted server too");

  NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary: on()];
  [d setObject: [NSNumber numberWithInt: 512] forKey: JackSettingBufferFrames];
  [d setObject: @"PCH" forKey: JackSettingOutputCard];
  setSettings(e, d);
  PASS(e->server->bufferSets == 1 && e->server->frames == 512, "buffer set live on the adopted server");
  tickFor(s, e, 1);
  PASS(!signalled(e, SIGTERM, -777) && launchesOf(e, @"jackd") == 0 && launchesOf(e, @"alsa_out") == 1,
       "PCH selected: bridged, the adopted jackd keeps running");

  [s stop];
  PASS(!signalled(e, SIGTERM, -777) && !signalled(e, SIGTERM, 777) && !signalled(e, SIGKILL, -777),
       "stop leaves the adopted jackd alone");
  PASS(signalled(e, SIGTERM, 5000), "the bridge is stopped");
  PASS(asoundrc(e) == nil, "block removed");

  /* a jackd an earlier supervisor started is recognised as our own */
  e = [[FakeEnv new] autorelease];
  writeCards(e, [NSArray arrayWithObject: PCH()]);
  NSArray *args = [NSArray arrayWithObjects: @"-n", @"gsfake", @"-d", @"alsa", @"-d", @"hw:CARD=PCH,DEV=0",
    @"-r", @"48000", @"-p", @"1024", @"-n", @"3", nil];
  [e->table addObject: [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithInt: 4242], @"pid",
    @"jackd", @"comm", [[NSArray arrayWithObject: @"jackd"] arrayByAddingObjectsFromArray: args], @"argv", nil]];
  [[NSFileManager defaultManager] createDirectoryAtPath: [e logDirectory] withIntermediateDirectories: YES
                                             attributes: nil error: NULL];
  [[NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithInt: 4242], @"ownJackdPid",
    args, @"ownJackdArguments", nil] writeToFile: [e statusPath] atomically: YES];
  e->serverUp = YES;
  setSettings(e, on());
  s = [[[JackSupervisor alloc] initWithEnvironment: e] autorelease];
  [s start];
  tickFor(s, e, 1);
  PASS_EQUAL([[s statusDictionary] objectForKey: JackStatusOwner], @"own", "earlier own jackd taken back");
  [s stop];
  PASS(signalled(e, SIGTERM, -4242), "and stopped with the supervisor");
}

static NSArray *HDMI(void)
{
  return card(2, @"HDMI", [NSArray arrayWithObjects: @"pcm3p", @"pcm7p", nil]);
}

static void writePCMId(FakeEnv *e, int cardIndex, NSString *pcm, NSString *pcmId)
{
  NSString *path = [[e alsaProcRoot] stringByAppendingPathComponent:
    [NSString stringWithFormat: @"card%d/%@/info", cardIndex, pcm]];
  [[NSString stringWithFormat: @"card: %d\ndevice: 3\nid: %@\nname: \n", cardIndex, pcmId]
    writeToFile: path atomically: YES encoding: NSUTF8StringEncoding error: NULL];
}

static NSString *jackdDevice(FakeEnv *e)
{
  NSArray *args = [lastLaunch(e, @"jackd") objectForKey: @"args"];
  NSUInteger i = [args indexOfObject: @"alsa"];
  return (i == NSNotFound || i + 2 >= [args count]) ? nil : [args objectAtIndex: i + 2];
}

static NSUInteger bridgeCount(JackSupervisor *s)
{
  return [[[s statusDictionary] objectForKey: JackStatusBridges] count];
}

static FakeProcess *liveJackd(FakeEnv *e)
{
  for (FakeProcess *p in e->children) if ([p->comm isEqual: @"jackd"] && p->alive) return p;
  return nil;
}

static void testSelectionPolicy(void)
{
  FakeEnv *e = [[FakeEnv new] autorelease];
  writeCards(e, [NSArray arrayWithObjects: PCH(), USB(), HDMI(), nil]);
  e->autoUp = YES;
  NSMutableDictionary *sel = [NSMutableDictionary dictionaryWithDictionary: on()];
  [sel setObject: @"USB" forKey: JackSettingOutputCard];
  /* an old plist still names a clock device: ignored */
  [sel setObject: @"hw:CARD=PCH,DEV=0" forKey: @"JackClockDevice"];
  [[NSFileManager defaultManager] createDirectoryAtPath: [e path: @""] withIntermediateDirectories: YES
                                             attributes: nil error: NULL];
  [sel writeToFile: [e settingsPath] atomically: YES];
  [sel removeObjectForKey: @"JackClockDevice"];

  JackSupervisor *s = [[[JackSupervisor alloc] initWithEnvironment: e] autorelease];
  [s start];
  PASS_EQUAL(jackdDevice(e), @"hw:CARD=USB,DEV=0", "first start: jackd on the selected output, stale clock key ignored");
  tickFor(s, e, 1);
  NSDictionary *st = [s statusDictionary];
  PASS([stateOf(s) isEqual: JackStateRunning] && bridgeCount(s) == 0, "running, selection is jackd's device: no bridge");
  PASS(![[st objectForKey: JackStatusOutputBridged] boolValue]
       && [[st objectForKey: JackStatusOutputClient] isEqual: @"system"], "output is system, not bridged");
  PASS_EQUAL([st objectForKey: JackStatusDrivenDevice], @"USB device", "driven device named");
  PASS_EQUAL([st objectForKey: JackStatusRoutedOutputCard], @"clock", "routed output: jackd's device");
  [e->server addPort: @"app:out_1" flags: 2];
  [e->server addPort: @"app:out_2" flags: 2];
  [e->server addPort: @"app:in_1" flags: 1];
  tickFor(s, e, 1);
  PASS([e->server is: @"app:out_1" connectedTo: @"system:playback_1"], "app plays to system");

  /* another device selected: the watch ticks at once and bridges it; the
     next fast tick routes; no restart */
  PASS([s timerInterval] == 1.0, "idle: one tick a second");
  [sel setObject: @"HDMI_3" forKey: JackSettingOutputCard];
  setSettings(e, sel);
  PASS(launchesOf(e, @"jackd") == 1 && [e->signals count] == 0, "selection change never restarts jackd");
  PASS_EQUAL([[s statusDictionary] objectForKey: JackStatusBridges], [NSArray arrayWithObject: @"gsout-HDMI_3"],
             "bridged by the watch's immediate tick, nothing else");
  PASS_EQUAL([[s statusDictionary] objectForKey: JackStatusRoutedOutputCard], @"clock",
             "not routed before the bridge has ports");
  PASS([s timerInterval] < 0.5, "fast ticks while the routing is pending");
  e->now += 0.2;
  [s tick];
  PASS_EQUAL([[s statusDictionary] objectForKey: JackStatusRoutedOutputCard], @"HDMI_3",
             "routed output card follows in the tick that connects");
  PASS_EQUAL([[NSDictionary dictionaryWithContentsOfFile: [e statusPath]] objectForKey: @"routedOutputCard"],
             @"HDMI_3", "and is in the status file at once");
  PASS([s timerInterval] == 1.0, "back to one tick a second");
  PASS([e->server is: @"app:out_1" connectedTo: @"gsout-HDMI_3:playback_1"]
       && ![e->server is: @"app:out_1" connectedTo: @"system:playback_1"], "connections moved to the bridge");
  st = [s statusDictionary];
  PASS([[st objectForKey: JackStatusOutputBridged] boolValue], "status: output bridged");
  PASS_EQUAL([st objectForKey: JackStatusDrivenDevice], @"USB device", "jackd still drives USB");
  pid_t hdmiPid = 0;
  for (FakeProcess *p in e->children) if ([p->client isEqual: @"gsout-HDMI_3"]) hdmiPid = p->pid;
  PASS_EQUAL([lastLaunch(e, @"alsa_out") objectForKey: @"args"] ? @"ok" : nil, @"ok", "bridge launched");

  /* back to jackd's own device: bridge removed, routed to system, at once */
  [sel setObject: @"USB" forKey: JackSettingOutputCard];
  setSettings(e, sel);
  PASS_EQUAL([[s statusDictionary] objectForKey: JackStatusRoutedOutputCard], @"clock", "routed back at once");
  PASS(bridgeCount(s) == 0 && signalled(e, SIGTERM, hdmiPid), "selection back on jackd's device: bridge stopped");
  PASS([e->server is: @"app:out_1" connectedTo: @"system:playback_1"], "routed back to system");
  PASS(launchesOf(e, @"jackd") == 1, "still the first jackd");

  /* input on another device than output: bridged; output on HDMI_7 too: two bridges, one per tick */
  tickFor(s, e, 1);
  [sel setObject: @"PCH" forKey: JackSettingInputCard];
  [sel setObject: @"HDMI_7" forKey: JackSettingOutputCard];
  setSettings(e, sel);
  NSUInteger most = 0;
  PASS(bridgeCount(s) == 1 && launchesOf(e, @"alsa_out") == 2 && launchesOf(e, @"alsa_in") == 0,
       "stagger: the output bridge first");
  for (int i = 0; i < 3; i++)
    {
      tickFor(s, e, 1);
      if (bridgeCount(s) > most) most = bridgeCount(s);
    }
  PASS(most == 2, "two bridges, never more");
  st = [s statusDictionary];
  PASS_EQUAL([st objectForKey: JackStatusBridges], ([NSArray arrayWithObjects: @"gsin-PCH", @"gsout-HDMI_7", nil]),
             "gsin-PCH and gsout-HDMI_7");
  PASS([e->server is: @"gsin-PCH:capture_1" connectedTo: @"app:in_1"], "app records from the PCH bridge");
  PASS_EQUAL([[s statusDictionary] objectForKey: JackStatusRoutedInputCard], @"PCH", "routed input card");

  /* unplug the selected HDMI card: its bridge goes, output falls back to system */
  writeCards(e, [NSArray arrayWithObjects: PCH(), USB(), nil]);
  tickFor(s, e, 1);
  st = [s statusDictionary];
  PASS_EQUAL([st objectForKey: JackStatusBridges], [NSArray arrayWithObject: @"gsin-PCH"], "only the input bridge left");
  PASS([e->server is: @"app:out_1" connectedTo: @"system:playback_1"], "output back on system");
  PASS([[st objectForKey: JackStatusMessage] rangeOfString: @"HDMI_7"].location != NSNotFound,
       "status says the selected output is missing");
  /* replug: bridge back within a poll, routing the tick after */
  writeCards(e, [NSArray arrayWithObjects: PCH(), USB(), HDMI(), nil]);
  writePCMId(e, 2, @"pcm7p", @"HDMI 1 (*)");
  tickFor(s, e, 1);
  PASS(bridgeCount(s) == 2, "replugged device bridged again");
  tickFor(s, e, 1);
  PASS([e->server is: @"app:out_1" connectedTo: @"gsout-HDMI_7:playback_1"]
       && [[s statusDictionary] objectForKey: JackStatusMessage] == nil, "routing moved back, no message");

  /* the next jackd start follows the then-current selection */
  [e die: liveJackd(e)];
  tickFor(s, e, 3);
  PASS(launchesOf(e, @"jackd") == 2 && [jackdDevice(e) isEqual: @"hw:CARD=HDMI,DEV=7"],
       "restart after a crash: jackd on the selected HDMI_7");
  tickFor(s, e, 2);
  st = [s statusDictionary];
  PASS_EQUAL([st objectForKey: JackStatusBridges], [NSArray arrayWithObject: @"gsin-PCH"],
             "output needs no bridge any more");
  PASS_EQUAL([st objectForKey: JackStatusDrivenDevice], @"HDMI device - HDMI 1", "PCM id in the driven name");
  [s stop];
}

static void testFallbackChain(void)
{
  /* no JACK card: the ALSA default output */
  FakeEnv *e = [[FakeEnv new] autorelease];
  writeCards(e, [NSArray arrayWithObjects: PCH(), HDMI(), nil]);
  NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary: on()];
  [d setObject: @"HDMI.7" forKey: @"defaultOutput"];
  [d setObject: @"PCH.0" forKey: @"defaultInput"];
  [[NSFileManager defaultManager] createDirectoryAtPath: [e path: @""] withIntermediateDirectories: YES
                                             attributes: nil error: NULL];
  [d writeToFile: [e settingsPath] atomically: YES];
  e->autoUp = YES;
  JackSupervisor *s = [[[JackSupervisor alloc] initWithEnvironment: e] autorelease];
  [s start];
  PASS_EQUAL(jackdDevice(e), @"hw:CARD=HDMI,DEV=7", "no JACK card: jackd on the ALSA default output");
  tickFor(s, e, 3);
  PASS_EQUAL([[s statusDictionary] objectForKey: JackStatusBridges], [NSArray arrayWithObject: @"gsin-PCH"],
             "the ALSA default input on another device is bridged");
  [s stop];

  /* nothing selected at all: the first card that plays */
  e = [[FakeEnv new] autorelease];
  writeCards(e, [NSArray arrayWithObjects: PCH(), HDMI(), nil]);
  setSettings(e, on());
  s = [[[JackSupervisor alloc] initWithEnvironment: e] autorelease];
  [s start];
  PASS_EQUAL(jackdDevice(e), @"hw:CARD=PCH,DEV=0", "nothing selected: the first playback device");
  [s stop];

  /* the selected output is unplugged at start: the first card that plays */
  e = [[FakeEnv new] autorelease];
  writeCards(e, [NSArray arrayWithObject: PCH()]);
  e->autoUp = YES;
  d = [NSMutableDictionary dictionaryWithDictionary: on()];
  [d setObject: @"USB" forKey: JackSettingOutputCard];
  setSettings(e, d);
  s = [[[JackSupervisor alloc] initWithEnvironment: e] autorelease];
  [s start];
  PASS_EQUAL(jackdDevice(e), @"hw:CARD=PCH,DEV=0", "selected output missing: jackd on the first device");
  tickFor(s, e, 1);
  PASS(bridgeCount(s) == 0 && [[[s statusDictionary] objectForKey: JackStatusOutputClient] isEqual: @"system"],
       "no bridge, routed to system");
  /* when it arrives it is bridged, jackd stays */
  writeCards(e, [NSArray arrayWithObjects: PCH(), USB(), nil]);
  tickFor(s, e, 1);
  PASS(launchesOf(e, @"jackd") == 1 && launchesOf(e, @"alsa_out") == 1 && launchesOf(e, @"alsa_in") == 0,
       "the arriving selection is bridged, jackd not restarted");
  [s stop];
}

static unsigned long long sizeOf(NSString *path)
{
  return [[[NSFileManager defaultManager] attributesOfItemAtPath: path error: NULL] fileSize];
}

static void appendBytes(NSString *path, NSUInteger n)
{
  NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath: path];
  if (h == nil)
    {
      [[NSData data] writeToFile: path atomically: NO];
      h = [NSFileHandle fileHandleForWritingAtPath: path];
    }
  [h seekToEndOfFile];
  [h writeData: [NSMutableData dataWithLength: n]];
  [h closeFile];
}

static pid_t bridgePid(FakeEnv *e, NSString *client)
{
  pid_t pid = 0;
  for (FakeProcess *p in e->children) if ([p->client isEqual: client] && p->alive) pid = p->pid;
  return pid;
}

static void testAsoundrcFollowsRouting(void)
{
  /* a playback-only headset drives jackd (no system:capture_*), a mono USB mic is the input */
  FakeEnv *e = [[FakeEnv new] autorelease];
  [e->server removeClient: @"system"];
  for (int i = 1; i <= 6; i++)
    [e->server addPort: [NSString stringWithFormat: @"system:playback_%d", i] flags: 1 | 4];
  writeCards(e, [NSArray arrayWithObjects: card(0, @"Audio", [NSArray arrayWithObject: @"pcm0p"]),
    card(2, @"Microphone", [NSArray arrayWithObject: @"pcm0c"]), nil]);
  e->autoUp = YES;
  NSMutableDictionary *sel = [NSMutableDictionary dictionaryWithDictionary: on()];
  [sel setObject: @"Audio" forKey: JackSettingOutputCard];
  [sel setObject: @"Microphone" forKey: JackSettingInputCard];
  setSettings(e, sel);
  JackSupervisor *s = [[[JackSupervisor alloc] initWithEnvironment: e] autorelease];
  [s start];
  PASS([stateOf(s) isEqual: JackStateRunning] && launchesOf(e, @"alsa_in") == 1, "running, mic bridged");
  PASS([asoundrc(e) rangeOfString: @"0 system:playback_1\n        1 system:playback_2"].location != NSNotFound
       && [asoundrc(e) rangeOfString: @"capture_ports"].location == NSNotFound,
       "before the mic's ports exist: playback only, no missing capture port named");
  tickFor(s, e, 1);
  PASS([asoundrc(e) rangeOfString: @"0 gsin-Microphone:capture_1\n        1 gsin-Microphone:capture_2"].location
       != NSNotFound, "block names the routed mic bridge for capture");
  PASS_EQUAL([[s statusDictionary] objectForKey: JackStatusRoutedInputCard], @"Microphone", "input routed to the mic");
  struct stat a, b;
  stat([[e asoundrcPath] fileSystemRepresentation], &a);
  tickFor(s, e, 3);
  stat([[e asoundrcPath] fileSystemRepresentation], &b);
  PASS(a.st_ino == b.st_ino && a.st_mtime == b.st_mtime, "unchanged routing: the file is not rewritten");

  /* the input deselected: the bridge goes in this tick and the block stops naming it at once */
  [sel setObject: [NSNull null] forKey: JackSettingInputCard];
  setSettings(e, sel);
  PASS(bridgeCount(s) == 0 && [asoundrc(e) rangeOfString: @"gsin-Microphone"].location == NSNotFound,
       "stopped bridge no longer named");

  /* a missing block is put back with the routed ports, and removed before jackd is signalled */
  [@"# mine\n" writeToFile: [e asoundrcPath] atomically: YES encoding: NSUTF8StringEncoding error: NULL];
  tickFor(s, e, 1);
  PASS([asoundrc(e) hasPrefix: @"# mine\n"] && [e asoundrcHasBlock], "block restored after an outside rewrite");
  [e->blockAtJackdTerm removeAllObjects];
  [s stop];
  PASS([e->blockAtJackdTerm count] == 1 && ![[e->blockAtJackdTerm objectAtIndex: 0] boolValue]
       && [asoundrc(e) isEqual: @"# mine\n"], "stop: block gone before jackd's SIGTERM, file restored");
}

static void testBridgeHealth(void)
{
  FakeEnv *e = [[FakeEnv new] autorelease];
  writeCards(e, [NSArray arrayWithObjects: PCH(), USB(), nil]);
  e->autoUp = YES;
  NSMutableDictionary *sel = [NSMutableDictionary dictionaryWithDictionary: on()];
  [sel setObject: @"PCH" forKey: JackSettingOutputCard];
  setSettings(e, sel);
  JackSupervisor *s = [[[JackSupervisor alloc] initWithEnvironment: e] autorelease];
  [s start];
  tickFor(s, e, 1);
  [sel setObject: @"USB" forKey: JackSettingInputCard];
  setSettings(e, sel);
  PASS(launchesOf(e, @"alsa_in") == 1, "USB mic bridged");
  PASS([[lastLaunch(e, @"alsa_in") objectForKey: @"limit"] unsignedLongLongValue] == 1024 * 1024
       && [[lastLaunch(e, @"jackd") objectForKey: @"limit"] unsignedLongLongValue] == 0,
       "bridges get a 1 MB file size limit, jackd none (its shm files)");
  NSArray *firstArgs = [lastLaunch(e, @"alsa_in") objectForKey: @"args"];
  tickFor(s, e, 3);
  PASS(launchesOf(e, @"alsa_in") == 1, "a healthy bridge is left alone");

  /* the kernel enumerates the mic again between two polls: new node, same card */
  pid_t old = bridgePid(e, @"gsin-USB");
  reenumerate(e, @"pcmC1D0c");
  tickFor(s, e, 1);
  PASS(signalled(e, SIGTERM, old) && launchesOf(e, @"alsa_in") == 2, "new device node: bridge restarted at once");
  PASS_EQUAL([lastLaunch(e, @"alsa_in") objectForKey: @"args"], firstArgs, "same argv");

  /* it comes back as another card number: same id, same bridge name and argv */
  tickFor(s, e, 1);
  old = bridgePid(e, @"gsin-USB");
  writeCards(e, [NSArray arrayWithObjects: PCH(), card(3, @"USB", [NSArray arrayWithObjects: @"pcm0p", @"pcm0c", nil]), nil]);
  tickFor(s, e, 1);
  PASS(signalled(e, SIGTERM, old) && launchesOf(e, @"alsa_in") == 3, "new card index: bridge restarted");
  PASS_EQUAL([lastLaunch(e, @"alsa_in") objectForKey: @"args"], firstArgs, "argv by card id, unchanged");
  PASS_EQUAL([[s statusDictionary] objectForKey: JackStatusBridges], [NSArray arrayWithObject: @"gsin-USB"],
             "still the one bridge gsin-USB");

  /* spinning on a dead handle: restarted after 3 hot ticks, with the back-off */
  tickFor(s, e, 1);
  old = bridgePid(e, @"gsin-USB");
  NSNumber *key = [NSNumber numberWithInt: old];
  double used = 0;
  for (int i = 0; i < 2; i++)
    {
      used += 0.9;
      [e->cpu setObject: [NSNumber numberWithDouble: used] forKey: key];
      tickFor(s, e, 1);
    }
  PASS(!signalled(e, SIGTERM, old), "two hot ticks: still running");
  used += 0.9;
  [e->cpu setObject: [NSNumber numberWithDouble: used] forKey: key];
  tickFor(s, e, 1);
  PASS(signalled(e, SIGTERM, old) && launchesOf(e, @"alsa_in") == 3, "third hot tick: stopped, not restarted at once");
  tickFor(s, e, 2);
  PASS(launchesOf(e, @"alsa_in") == 4, "restarted after the back-off");

  /* a flooding log: restarted, and the log cut back */
  tickFor(s, e, 1);
  old = bridgePid(e, @"gsin-USB");
  NSString *log = [e path: @"cache/jack-gsin-USB.log"];
  appendBytes(log, 300 * 1024);
  tickFor(s, e, 1);
  PASS(signalled(e, SIGTERM, old) && sizeOf(log) == 0, "log flood: bridge stopped, log truncated");
  tickFor(s, e, 4);
  PASS(launchesOf(e, @"alsa_in") == 5, "and started again");

  /* slow growth past the cap: truncated, bridge kept */
  old = bridgePid(e, @"gsin-USB");
  for (int i = 0; i < 6; i++)
    {
      appendBytes(log, 50 * 1024);
      tickFor(s, e, 1);
    }
  PASS(!signalled(e, SIGTERM, old) && sizeOf(log) < 256 * 1024, "slow log growth: cut back, bridge kept");
  NSString *jlog = [e path: @"cache/jackd.log"];
  appendBytes(jlog, 300 * 1024);
  tickFor(s, e, 1);
  PASS(sizeOf(jlog) == 0 && launchesOf(e, @"jackd") == 1, "jackd's log cut back too, jackd kept");
  [s stop];
}

static void testDamagedAsoundrc(void)
{
  FakeEnv *e = [[FakeEnv new] autorelease];
  writeCards(e, [NSArray arrayWithObject: PCH()]);
  NSString *bad = @"# BEGIN gershwin jack\npcm.x {}\n";
  [bad writeToFile: [e asoundrcPath] atomically: NO encoding: NSUTF8StringEncoding error: NULL];
  e->autoUp = YES;
  setSettings(e, on());
  JackSupervisor *s = [[[JackSupervisor alloc] initWithEnvironment: e] autorelease];
  [s start];
  tickFor(s, e, 2);
  PASS([stateOf(s) isEqual: JackStateRunning] && [asoundrc(e) isEqual: bad],
       "a damaged block is left alone (logged), JACK still runs");
  [s stop];
  PASS([asoundrc(e) isEqual: bad], "and not touched on stop");

  e = [[FakeEnv new] autorelease];
  writeCards(e, [NSArray arrayWithObject: PCH()]);
  e->autoUp = YES;
  e->plugin = NO;
  setSettings(e, on());
  s = [[[JackSupervisor alloc] initWithEnvironment: e] autorelease];
  [s start];
  tickFor(s, e, 2);
  PASS([stateOf(s) isEqual: JackStateRunning] && asoundrc(e) == nil, "no ALSA jack plugin: no block");
  [s stop];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  testDevices();
  testHelpers();
  testIdle();
  testLifecycle();
  testTurnOff();
  testStartFailures();
  testAdopted();
  testDamagedAsoundrc();
  testSelectionPolicy();
  testFallbackChain();
  testAsoundrcFollowsRouting();
  testBridgeHealth();
  [arp release];
  return 0;
}
