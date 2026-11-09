/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* JackSupport against a real server: starts its own jackd with the dummy
   driver on a private server name (so it cannot meet the user's jackd),
   exercises JackConnection and the patchbay planner on the real port list,
   and kills it again.  Skips when jackd or libjack is not installed. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Sound/JackSupport.h"

enum { kIn = 1, kOut = 2 };

static NSArray *portsOf(JackConnection *c) { return [c allPorts]; }

static NSDictionary *find(NSArray *ports, NSString *name)
{
  for (NSDictionary *p in ports)
    if ([[p objectForKey: @"name"] isEqual: name])
      return p;
  return nil;
}

static BOOL connected(NSArray *ports, NSString *src, NSString *dst)
{
  return [[find(ports, src) objectForKey: @"connections"] containsObject: dst];
}

static BOOL applyPlan(JackConnection *c, NSDictionary *plan)
{
  BOOL ok = YES;
  for (NSArray *op in [plan objectForKey: @"disconnect"])
    ok &= [c disconnect: [op objectAtIndex: 0] from: [op objectAtIndex: 1]];
  for (NSArray *op in [plan objectForKey: @"connect"])
    ok &= [c connect: [op objectAtIndex: 0] to: [op objectAtIndex: 1]];
  return ok;
}

static void spin(double seconds)
{
  [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: seconds]];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  if (![JackConnection isLibraryAvailable] || ![JackSupport isJackdAvailable])
    {
      fprintf(stderr, "SKIP t_JackSupportLive: jackd or libjack.so.0 not installed\n");
      [arp release];
      return 0;
    }

  NSString *server = [NSString stringWithFormat: @"gstest%d", (int)getpid()];
  PASS([JackSupport runningServerNamed: server] == nil, "no server before we start one");
  PASS([JackConnection openWithServerName: server] == nil,
       "opening never starts a server (JackNoStartServer)");
  PASS([JackConnection openWithServerName: server] == nil,
       "still no server after the probe");

  NSTask *jackd = [[NSTask alloc] init];
  [jackd setLaunchPath: @"/usr/bin/env"];
  [jackd setArguments: [NSArray arrayWithObjects: @"jackd", @"-n", server, @"-d", @"dummy",
                        @"-r", @"48000", @"-p", @"256", nil]];
  [jackd setStandardOutput: [NSFileHandle fileHandleWithNullDevice]];
  [jackd setStandardError: [NSFileHandle fileHandleWithNullDevice]];
  [jackd launch];

  JackConnection *main_ = nil;
  for (int i = 0; i < 50 && main_ == nil; i++)
    {
      spin(0.2);
      main_ = [JackConnection openWithServerName: server];
    }
  if (main_ == nil)
    {
      PASS(NO, "private jackd answered within 10 s");
      [jackd terminate];
      [jackd release];
      [arp release];
      return 0;
    }
  PASS([main_ isOpen], "connection open");
  PASS([main_ sampleRate] == 48000, "sample rate 48000");
  PASS([main_ bufferFrames] == 256, "buffer 256");

  /* detection */
  NSNumber *pid = [NSNumber numberWithInt: [jackd processIdentifier]];
  NSArray *procs = [JackSupport jackdProcesses];
  NSDictionary *mine = nil;
  for (NSDictionary *e in procs)
    if ([[e objectForKey: @"pid"] isEqual: pid]) mine = e;
  PASS(mine != nil, "our jackd is in the process list (comm jackd)");
  PASS([[JackSupport jackdProcessIDs] containsObject: pid], "pid listed");
  PASS(mine && [JackSupport clockDeviceForJackdArguments: [mine objectForKey: @"argv"]] == nil,
       "dummy driver: no clock device in the real argv");
  PASS(mine && [[mine objectForKey: @"argv"] containsObject: server], "argv read from /proc");
  JackConnection *running = [JackSupport runningServerNamed: server];
  PASS(running != nil && [running isOpen], "runningServerNamed: connects");
  [running close];
  PASS(![running isOpen], "closed");
  PASS([running allPorts] == nil, "closed connection has no ports");

  /* reading needs no activation */
  NSArray *ports = portsOf(main_);
  PASS(find(ports, @"system:playback_1") && find(ports, @"system:playback_2")
       && find(ports, @"system:capture_1") && find(ports, @"system:capture_2"),
       "system ports listed");
  NSDictionary *sp = find(ports, @"system:playback_1");
  PASS([[sp objectForKey: @"isInput"] boolValue] && [[sp objectForKey: @"isPhysical"] boolValue]
       && [[sp objectForKey: @"client"] isEqual: @"system"], "playback_1 is a physical input of 'system'");
  sp = find(ports, @"system:capture_1");
  PASS([[sp objectForKey: @"isOutput"] boolValue] && [[sp objectForKey: @"isPhysical"] boolValue],
       "capture_1 is a physical output");

  /* impersonate an application and two bridges */
  JackConnection *app = [JackConnection openWithServerName: server clientName: @"liveapp"];
  JackConnection *bout = [JackConnection openWithServerName: server clientName: @"gsout-test"];
  JackConnection *bin = [JackConnection openWithServerName: server clientName: @"gsin-test"];
  PASS(app && bout && bin, "test clients open");
  BOOL reg = YES;
  reg &= [app registerAudioPortNamed: @"out_1" flags: kOut];
  reg &= [app registerAudioPortNamed: @"out_2" flags: kOut];
  reg &= [app registerAudioPortNamed: @"in_1" flags: kIn];
  reg &= [app registerAudioPortNamed: @"in_2" flags: kIn];
  reg &= [bout registerAudioPortNamed: @"playback_1" flags: kIn];
  reg &= [bout registerAudioPortNamed: @"playback_2" flags: kIn];
  reg &= [bin registerAudioPortNamed: @"capture_1" flags: kOut];
  reg &= [bin registerAudioPortNamed: @"capture_2" flags: kOut];
  PASS(reg, "ports registered");

  ports = portsOf(main_);
  PASS(find(ports, @"liveapp:out_2") != nil && find(ports, @"gsout-test:playback_1") != nil,
       "test ports visible");

  /* route to the bridged device, as planned */
  NSDictionary *plan = [JackSupport patchbayPlanForPorts: ports
                                            outputClient: @"gsout-test"
                                             inputClient: @"gsin-test"];
  PASS([[plan objectForKey: @"connect"] count] == 4 && [[plan objectForKey: @"problems"] count] == 0,
       "plan: 2 playback + 2 capture connections");
  PASS(applyPlan(main_, plan), "all operations accepted by the server");
  ports = portsOf(main_);
  PASS(connected(ports, @"liveapp:out_1", @"gsout-test:playback_1")
       && connected(ports, @"liveapp:out_2", @"gsout-test:playback_2"), "playback routed");
  PASS(connected(ports, @"gsin-test:capture_1", @"liveapp:in_1")
       && connected(ports, @"gsin-test:capture_2", @"liveapp:in_2"), "capture routed");
  plan = [JackSupport patchbayPlanForPorts: ports outputClient: @"gsout-test" inputClient: @"gsin-test"];
  PASS([[plan objectForKey: @"connect"] count] == 0 && [[plan objectForKey: @"disconnect"] count] == 0,
       "replanning on the real state is empty");

  /* switch to the system device: old connections go, new ones appear */
  plan = [JackSupport patchbayPlanForPorts: ports outputClient: @"system" inputClient: @"system"];
  PASS([[plan objectForKey: @"disconnect"] count] == 4 && [[plan objectForKey: @"connect"] count] == 4,
       "switch: 4 disconnects, 4 connects");
  PASS(applyPlan(main_, plan), "switch applied");
  ports = portsOf(main_);
  PASS(connected(ports, @"liveapp:out_1", @"system:playback_1")
       && connected(ports, @"liveapp:out_2", @"system:playback_2")
       && !connected(ports, @"liveapp:out_1", @"gsout-test:playback_1")
       && connected(ports, @"system:capture_1", @"liveapp:in_1")
       && !connected(ports, @"gsin-test:capture_1", @"liveapp:in_1"), "switched on the real server");
  plan = [JackSupport patchbayPlanForPorts: ports outputClient: @"system" inputClient: @"system"];
  PASS([[plan objectForKey: @"connect"] count] == 0 && [[plan objectForKey: @"disconnect"] count] == 0,
       "idempotent after the switch");

  /* buffer size */
  PASS([main_ setBufferFrames: 512], "set_buffer_size accepted");
  for (int i = 0; i < 20 && [main_ bufferFrames] != 512; i++) spin(0.1);
  PASS([main_ bufferFrames] == 512, "buffer size now 512");

  [app close];
  [bout close];
  [bin close];
  spin(0.3);
  ports = portsOf(main_);
  PASS(find(ports, @"liveapp:out_1") == nil, "closed clients' ports are gone");

  [main_ close];
  [jackd terminate];
  [jackd waitUntilExit];
  [jackd release];
  spin(0.2);
  PASS([JackConnection openWithServerName: server] == nil, "server gone after kill");
  PASS(![[JackSupport jackdProcessIDs] containsObject: pid], "jackd process gone");

  [arp release];
  return 0;
}
