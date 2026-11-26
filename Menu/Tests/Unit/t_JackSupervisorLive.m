/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* JackSupervisor against the real system environment: a real jackd (dummy
   driver, private server name), the real inotify watch on the settings, the
   real timer and NSTask children, a real test client for the patchbay.  The
   files live in a temporary directory, and /proc/asound is replaced by a
   fake one so a card can appear and go away; since alsa_out needs a real
   card, the bridges run "sleep 100" instead (their argv is covered by the
   planner tests).  Skips when jackd or libjack is not installed. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Sound/JackSupport.h"
#import "Sound/JackSupervisor.h"
#include <signal.h>
#include <unistd.h>

@interface LiveEnv : JackSupervisorSystemEnvironment
{
@public
  NSString *dir;
  NSMutableArray *children;    // @[exe, process]
}
@end

@implementation LiveEnv
- (NSString *) settingsPath { return [dir stringByAppendingPathComponent: @"config/sound-defaults.plist"]; }
/* Under a private HOME, so arecord/aplay started with that HOME read it. */
- (NSString *) asoundrcPath { return [dir stringByAppendingPathComponent: @"home/.asoundrc"]; }
- (NSString *) statusPath { return [dir stringByAppendingPathComponent: @"cache/jack-status.plist"]; }
- (NSString *) logDirectory { return [dir stringByAppendingPathComponent: @"cache"]; }
- (NSString *) alsaProcRoot { return [dir stringByAppendingPathComponent: @"asound"]; }
- (NSString *) alsaDevRoot { return [dir stringByAppendingPathComponent: @"dev"]; }
- (id<JackSupervisorProcess>) launchExecutable: (NSString *)exe arguments: (NSArray *)args
                                       logPath: (NSString *)log fileSizeLimit: (unsigned long long)limit
                                         error: (NSString **)error
{
  NSArray *real = args;
  NSString *program = exe;
  if ([exe isEqual: @"jackd"])
    real = [NSArray arrayWithObjects: @"-n", [self serverName], @"-d", @"dummy",
                    @"-r", @"48000", @"-p", @"256", nil];
  else
    {
      program = @"sleep";
      real = [NSArray arrayWithObject: @"100"];
    }
  id<JackSupervisorProcess> p = [super launchExecutable: program arguments: real logPath: log
                                                fileSizeLimit: limit error: error];
  if (p) [children addObject: [NSArray arrayWithObjects: exe, p, nil]];
  return p;
}
@end

static void spin(double seconds)
{
  [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: seconds]];
}

static void writeCards(LiveEnv *e, BOOL extra)
{
  NSString *root = [e alsaProcRoot];
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm removeItemAtPath: root error: NULL];
  [fm createDirectoryAtPath: [root stringByAppendingPathComponent: @"card0/pcm0p"]
withIntermediateDirectories: YES attributes: nil error: NULL];
  NSString *text = @" 0 [FAKE           ]: Dummy - Fake clock card\n                      Fake\n";
  if (extra)
    {
      [fm createDirectoryAtPath: [root stringByAppendingPathComponent: @"card1/pcm0p"]
    withIntermediateDirectories: YES attributes: nil error: NULL];
      text = [text stringByAppendingString: @" 1 [EXTRA          ]: USB-Audio - Extra card\n                      Extra\n"];
    }
  [text writeToFile: [root stringByAppendingPathComponent: @"cards"] atomically: YES
           encoding: NSUTF8StringEncoding error: NULL];
}

static NSString *stateOf(JackSupervisor *s)
{
  return [[s statusDictionary] objectForKey: JackStatusState];
}

static BOOL waitFor(BOOL (^cond)(void), double seconds)
{
  for (double t = 0; t < seconds; t += 0.1)
    {
      if (cond()) return YES;
      spin(0.1);
    }
  return cond();
}

static id<JackSupervisorProcess> child(LiveEnv *e, NSString *exe)
{
  id<JackSupervisorProcess> found = nil;
  for (NSArray *c in e->children)
    if ([[c objectAtIndex: 0] isEqual: exe]) found = [c objectAtIndex: 1];
  return found;
}

/* Voluntary context switches of all our threads: each is a wakeup. */
static long long wakeups(void)
{
  long long total = 0;
  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSString *tid in [fm contentsOfDirectoryAtPath: @"/proc/self/task" error: NULL])
    {
      NSString *st = [NSString stringWithContentsOfFile:
        [NSString stringWithFormat: @"/proc/self/task/%@/status", tid] encoding: NSUTF8StringEncoding error: NULL];
      for (NSString *line in [st componentsSeparatedByString: @"\n"])
        if ([line hasPrefix: @"voluntary_ctxt_switches:"])
          total += [[[line componentsSeparatedByString: @":"] lastObject] longLongValue];
    }
  return total;
}

static BOOL hasBlock(LiveEnv *e)
{
  NSString *t = [NSString stringWithContentsOfFile: [e asoundrcPath] encoding: NSUTF8StringEncoding error: NULL];
  return t && [JackSupport asoundrcHasJackBlock: t];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  if (![JackConnection isLibraryAvailable] || ![JackSupport isJackdAvailable])
    {
      fprintf(stderr, "SKIP t_JackSupervisorLive: jackd or libjack.so.0 not installed\n");
      [arp release];
      return 0;
    }

  NSString *server = [NSString stringWithFormat: @"gstest%d", (int)getpid()];
  LiveEnv *e = [[[LiveEnv alloc] initWithServerName: server] autorelease];
  e->dir = [[NSString stringWithFormat: @"%@/gwjacklive.%d", NSTemporaryDirectory(), (int)getpid()] retain];
  e->children = [[NSMutableArray alloc] init];
  [[NSFileManager defaultManager] removeItemAtPath: e->dir error: NULL];
  writeCards(e, NO);
  [[NSFileManager defaultManager] createDirectoryAtPath: [e->dir stringByAppendingPathComponent: @"home"]
                            withIntermediateDirectories: YES attributes: nil error: NULL];
  NSString *original = @"# the user's own\n";
  [original writeToFile: [e asoundrcPath] atomically: NO encoding: NSUTF8StringEncoding error: NULL];

  JackSupervisor *s = [[JackSupervisor alloc] initWithEnvironment: e];
  [s start];
  PASS([stateOf(s) isEqual: JackStateDisabled] && ![s isTimerScheduled], "off: disabled, no timer");
  long long w0 = wakeups();
  spin(5);
  long long offWakeups = wakeups() - w0;
  printf("idle cost with JACK off: %lld wakeups in 5 s\n", offWakeups);
  PASS(offWakeups <= 3, "JACK off: (almost) no wakeups");

  NSString *err = nil;
  [JackSupport setSettings: [NSDictionary dictionaryWithObject: [NSNumber numberWithBool: YES]
                                                        forKey: JackSettingUseJack]
                    atPath: [e settingsPath] error: &err];
  PASS(waitFor(^{ return [s isTimerScheduled]; }, 2), "the settings watch noticed UseJack");
  PASS(waitFor(^{ return [stateOf(s) isEqual: JackStateRunning]; }, 12), "jackd started and running");
  NSDictionary *st = [s statusDictionary];
  PASS([[st objectForKey: JackStatusOwner] isEqual: @"own"]
       && [[st objectForKey: JackStatusSampleRate] intValue] == 48000
       && [[st objectForKey: JackStatusBufferFrames] intValue] == 256, "own server, 48 kHz, 256 frames");
  PASS(hasBlock(e), "asoundrc block present while running");
  id<JackSupervisorProcess> jackd = child(e, @"jackd");
  pid_t jackdPid = [jackd processIdentifier];
  PASS(getpgid(jackdPid) == jackdPid, "jackd runs in its own process group");
  PASS([[NSFileManager defaultManager] fileExistsAtPath: [[e logDirectory] stringByAppendingPathComponent: @"jackd.log"]],
       "jackd log written");

  long long w1 = wakeups();
  spin(5);
  printf("cost with JACK on (own jackd, supervisor only): %lld wakeups in 5 s\n", wakeups() - w1);

  /* the patchbay connects a real client */
  JackConnection *app = [JackConnection openWithServerName: server clientName: @"liveapp"];
  BOOL reg = [app registerAudioPortNamed: @"out_1" flags: 2] && [app registerAudioPortNamed: @"out_2" flags: 2];
  PASS(app && reg, "test client with two outputs");
  JackConnection *probe = [JackConnection openWithServerName: server clientName: @"liveprobe"];
  BOOL routed = waitFor(^{
    for (NSDictionary *p in [probe allPorts])
      if ([[p objectForKey: @"name"] isEqual: @"liveapp:out_2"])
        return [[p objectForKey: @"connections"] containsObject: @"system:playback_2"];
    return NO;
  }, 3);
  PASS(routed, "patchbay connected liveapp to system within a few seconds");

  /* a card appears: not selected, so not bridged */
  writeCards(e, YES);
  spin(2.5);
  PASS(child(e, @"alsa_out") == nil && child(e, @"alsa_in") == nil, "an unselected card is not bridged");
  /* selected: the settings watch ticks at once and bridges it, jackd stays */
  NSDate *t0 = [NSDate date];
  [JackSupport setSettings: [NSDictionary dictionaryWithObject: @"EXTRA" forKey: JackSettingOutputCard]
                    atPath: [e settingsPath] error: &err];
  PASS(waitFor(^{ return (BOOL)(child(e, @"alsa_out") != nil); }, 3), "bridge started for the selected card");
  double latency = -[t0 timeIntervalSinceNow];
  printf("selection to bridge start: %.0f ms\n", latency * 1000);
  PASS(latency < 0.7, "bridge started by the watch, not the next timer tick");
  id<JackSupervisorProcess> bridge = child(e, @"alsa_out");
  NSDictionary *bst = [s statusDictionary];
  PASS([bridge isRunning] && [[bst objectForKey: JackStatusBridges] isEqual: [NSArray arrayWithObject: @"gsout-EXTRA"]]
       && [[bst objectForKey: JackStatusOutputBridged] boolValue], "only that bridge, output bridged");
  PASS([jackd isRunning] && child(e, @"jackd") == jackd, "jackd not restarted by the selection");
  NSString *limits = [NSString stringWithContentsOfFile:
    [NSString stringWithFormat: @"/proc/%d/limits", (int)[bridge processIdentifier]]
                                               encoding: NSUTF8StringEncoding error: NULL];
  NSString *fsize = nil;
  for (NSString *line in [limits componentsSeparatedByString: @"\n"])
    if ([line hasPrefix: @"Max file size"]) fsize = line;
  PASS(fsize && [fsize rangeOfString: @" 1048576 "].location != NSNotFound,
       "bridge runs with a 1 MB file size limit (%s)", fsize ? [fsize UTF8String] : "none");
  writeCards(e, NO);
  PASS(waitFor(^{ return (BOOL)![bridge isRunning]; }, 4), "bridge stopped when the card went away");

  /* ALSA applications through the managed block: plays and records */
  if ([e isALSAJackPluginInstalled] && [[NSFileManager defaultManager] isExecutableFileAtPath: @"/usr/bin/arecord"])
    {
      NSArray *tools = [NSArray arrayWithObjects: @"aplay", @"arecord", nil];
      for (NSString *tool in tools)
        {
          NSTask *t = [[[NSTask alloc] init] autorelease];
          [t setLaunchPath: @"/usr/bin/env"];
          [t setArguments: [NSArray arrayWithObjects:
            [@"HOME=" stringByAppendingString: [e->dir stringByAppendingPathComponent: @"home"]],
            [@"JACK_DEFAULT_SERVER=" stringByAppendingString: server], tool, @"-q", @"-D", @"default",
            @"-d", @"1", @"-f", @"S16_LE", @"-r", @"48000", @"-c", @"2",
            [tool isEqual: @"aplay"] ? @"/dev/zero" : @"/dev/null", nil]];
          [t setStandardOutput: [NSFileHandle fileHandleWithNullDevice]];
          [t setStandardError: [NSFileHandle fileHandleWithNullDevice]];
          [t launch];
          [t waitUntilExit];
          PASS([t terminationStatus] == 0, "%s -D default works through the JACK block", [tool UTF8String]);
        }
    }
  else
    fprintf(stderr, "SKIP aplay/arecord: ALSA jack plugin or arecord missing\n");

  /* stop */
  [s stop];
  PASS(!hasBlock(e), "block removed on stop");
  NSString *now = [NSString stringWithContentsOfFile: [e asoundrcPath] encoding: NSUTF8StringEncoding error: NULL];
  PASS([now isEqual: original], "asoundrc restored byte for byte");
  PASS(![jackd isRunning] && kill(jackdPid, 0) != 0, "our jackd is gone");
  [app close];
  [probe close];
  PASS([JackConnection openWithServerName: server] == nil, "server gone");
  PASS(![s isTimerScheduled], "no timer after stop");
  [s release];

  /* an adopted server survives the supervisor */
  NSTask *own = [[[NSTask alloc] init] autorelease];
  [own setLaunchPath: @"/usr/bin/env"];
  [own setArguments: [NSArray arrayWithObjects: @"jackd", @"-n", server, @"-d", @"dummy", @"-r", @"44100",
                      @"-p", @"512", nil]];
  [own setStandardOutput: [NSFileHandle fileHandleWithNullDevice]];
  [own setStandardError: [NSFileHandle fileHandleWithNullDevice]];
  [own launch];
  PASS(waitFor(^{ JackConnection *c = [JackConnection openWithServerName: server];
                  [c close]; return (BOOL)(c != nil); }, 10), "user's own jackd up");
  [[NSFileManager defaultManager] removeItemAtPath: [e statusPath] error: NULL];
  s = [[JackSupervisor alloc] initWithEnvironment: e];
  [s start];
  PASS(waitFor(^{ return [stateOf(s) isEqual: JackStateRunning]; }, 5)
       && [[[s statusDictionary] objectForKey: JackStatusOwner] isEqual: @"adopted"]
       && [[[s statusDictionary] objectForKey: JackStatusSampleRate] intValue] == 44100, "adopted at 44.1 kHz");
  [s stop];
  [s release];
  spin(0.5);
  PASS([own isRunning], "adopted jackd left running");
  [own terminate];
  [own waitUntilExit];

  for (NSArray *c in e->children)
    if ([[c objectAtIndex: 1] isRunning]) kill([[c objectAtIndex: 1] processIdentifier], SIGKILL);
  [[NSFileManager defaultManager] removeItemAtPath: e->dir error: NULL];
  [arp release];
  return 0;
}
