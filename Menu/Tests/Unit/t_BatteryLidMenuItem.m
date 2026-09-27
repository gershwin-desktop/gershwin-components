/* t_BatteryLidMenuItem.m - "Stay awake at lid close" menu item coverage.
 *
 * Proves the check mark the user sees is really wired to
 * EnergyLidCloseOnceArmer's state through BatteryExtra's real -menu and
 * -validateMenuItem:, not just that the state machine is correct in
 * isolation (t_LidCloseOnce covers that in isolation; this is the "did the
 * effect reach the menu" half - gnustep-red-green-tdd's "a headless test of
 * a decision does not prove the effect reached the user" pitfall).
 *
 * TestBattery overrides -createLidArmerWithUnsupportedReason: (the one seam
 * BatteryExtra exposes for this) to hand back an armer built from fakes
 * instead of the real D-Bus/systemd-inhibit backend.
 *
 * Headless: needs a DISPLAY only because NSMenu/NSMenuItem are AppKit
 * classes; nothing here draws.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later OR BSD-2-Clause
 */
#import <AppKit/AppKit.h>
#import "Testing.h"
#import "BatteryExtra.h"
#import "GSMenuExtraContext.h"
#import "EnergyLidCloseOnce.h"

@interface FakeLidEventSource2 : NSObject <EnergyLidEventSource>
{
    void (^_handler)(BOOL closed);
}
- (void)simulateLidClosed:(BOOL)closed;
@end

@implementation FakeLidEventSource2
- (void)setLidStateHandler:(void (^)(BOOL closed))handler
{
    _handler = [handler copy];
}
- (void)start { }
- (void)stop { }
- (void)simulateLidClosed:(BOOL)closed
{
    if (_handler) _handler(closed);
}
@end

@interface FakeInhibitor2 : NSObject <EnergySleepInhibitor>
{
    BOOL _inhibiting;
}
@end

@implementation FakeInhibitor2
- (BOOL)startInhibitingLidHandlingWhy:(NSString *)why error:(NSError **)error
{
    (void)why; (void)error;
    _inhibiting = YES;
    return YES;
}
- (void)stopInhibiting { _inhibiting = NO; }
- (BOOL)isInhibiting { return _inhibiting; }
@end

/* Supported: hands back a real armer wired to fakes. */
@interface SupportedTestBattery : BatteryExtra
{
    FakeLidEventSource2 *_fakeSource;
}
- (FakeLidEventSource2 *)fakeSource;
@end

@implementation SupportedTestBattery
- (EnergyLidCloseOnceArmer *)createLidArmerWithUnsupportedReason:(NSString **)reason
{
    (void)reason;
    _fakeSource = [[FakeLidEventSource2 alloc] init];
    FakeInhibitor2 *inhibitor = [[FakeInhibitor2 alloc] init];
    return [[EnergyLidCloseOnceArmer alloc] initWithLidEventSource:_fakeSource
                                                          inhibitor:inhibitor];
}
- (FakeLidEventSource2 *)fakeSource
{
    return _fakeSource;
}
@end

/* Unsupported: the platform stub path (BSDs, or Linux with no logind). */
@interface UnsupportedTestBattery : BatteryExtra
@end

@implementation UnsupportedTestBattery
- (EnergyLidCloseOnceArmer *)createLidArmerWithUnsupportedReason:(NSString **)reason
{
    if (reason) {
        *reason = @"fake: platform not supported";
    }
    return nil;
}
@end

/* -menu builds fresh items every time (menu-extras skill: "a build of -menu
 * must never touch the previous build's objects"), so the item is found by
 * its action selector, same as it would be picked out of a live menu. */
static NSMenuItem *FindLidItem(NSMenu *menu)
{
    for (NSMenuItem *item in [menu itemArray]) {
        if ([item action] == @selector(toggleStayAwakeAtLidClose:)) {
            return item;
        }
    }
    return nil;
}

int main(void)
{
  [NSApplication sharedApplication];
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("supported platform: arm, lid closes once, consumed");

  SupportedTestBattery *e = [[SupportedTestBattery alloc] init];
  GSMenuExtraContext *ctx = [[GSMenuExtraContext alloc] initWithManager:nil
                                                              identifier:@"Battery"];
  [e setContext:ctx];
  [e menuExtraDidLoad];

  NSMenu *menu = [e menu];
  NSMenuItem *item = FindLidItem(menu);
  PASS(item != nil, "the menu carries a 'Stay awake at lid close' item");
  PASS([e validateMenuItem:item], "it is enabled when the backend is available");
  PASS([item state] == NSOffState, "and starts unchecked");

  [e toggleStayAwakeAtLidClose:item];
  PASS([e validateMenuItem:item], "still enabled after arming");
  PASS([item state] == NSOnState,
       "validateMenuItem: checks it after the user arms it");

  [[e fakeSource] simulateLidClosed:YES];
  /* The armer transitions the instant the lid closes, but nothing pushes
   * that into the menu item on its own - same as the rest of this extra's
   * state, it is picked up the next time AppKit revalidates the item
   * (menu tracking) or a fresh -menu is built. */
  [e validateMenuItem:item];
  PASS([item state] == NSOffState,
       "the check mark clears itself once the lid has closed");

  END_SET("supported platform: arm, lid closes once, consumed");

  START_SET("unsupported platform");

  UnsupportedTestBattery *u = [[UnsupportedTestBattery alloc] init];
  GSMenuExtraContext *uctx = [[GSMenuExtraContext alloc] initWithManager:nil
                                                               identifier:@"Battery"];
  [u setContext:uctx];
  [u menuExtraDidLoad];

  NSMenu *umenu = [u menu];
  NSMenuItem *uitem = FindLidItem(umenu);
  PASS(uitem != nil, "the item is still shown, so the user can see the feature exists");
  PASS(![u validateMenuItem:uitem],
       "but disabled rather than silently doing nothing when clicked");

  END_SET("unsupported platform");

  [arp release];
  return 0;
}
