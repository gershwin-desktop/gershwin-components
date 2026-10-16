/* t_BatteryRefresh.m - ObjectTesting coverage for the Battery menu extra.
 *
 * The extra used to read the battery exactly once, when it was loaded, and
 * never again: the menu bar kept showing the state the machine had at Menu
 * startup for the rest of the session.  These tests pin the two refresh
 * paths the manager gives it - the pre-open hook and the 2 s tick - and the
 * rule that a repaint is only asked for when the drawn icon would change.
 *
 * Headless: updateBattery is the real one, it just reads its "sysfs" files
 * out of a dictionary instead of /sys.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later OR BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "BatteryExtra.h"
#import "GSMenuExtraContext.h"

/* What the test drives and what it reads: -readFile: is what the extra gets
 * its numbers from, -iconName says which icon the menu bar would draw, and
 * -tick is the manager's periodic callback (it is not part of the
 * GSMenuExtra protocol, the manager probes for it by selector). */
@interface BatteryExtra (TestHooks)
- (NSString *)readFile:(NSString *)path;
- (NSString *)iconName;
- (void)tick;
@end

/* Stands in for the real context, counting the repaints the extra asks for. */
@interface CountingContext : GSMenuExtraContext
{
    NSInteger _invalidations;
}
- (NSInteger)invalidations;
@end

@implementation CountingContext
- (void)invalidatePresentation
{
    _invalidations++;
}
- (NSInteger)invalidations
{
    return _invalidations;
}
@end

/* The real extra, reading updateBattery's files out of a dictionary.  Files
 * left out come back nil, exactly as readFile: does when the file is not
 * there. */
@interface FakeBattery : BatteryExtra
{
    NSDictionary *_sysfs;
}
- (void)setSysfs:(NSDictionary *)files;
@end

@implementation FakeBattery
- (void)setSysfs:(NSDictionary *)files
{
    _sysfs = files;
}
- (NSString *)readFile:(NSString *)path
{
    return [_sysfs objectForKey:path];
}
@end

static NSString *const kAcOnline = @"/sys/class/power_supply/AC/online";
static NSString *const kBatStatus = @"/sys/class/power_supply/BAT0/status";
static NSString *const kBatCapacity = @"/sys/class/power_supply/BAT0/capacity";
static NSString *const kEnergyNow = @"/sys/class/power_supply/BAT0/energy_now";
static NSString *const kPowerNow = @"/sys/class/power_supply/BAT0/power_now";

static NSDictionary *Battery(NSString *ac, NSString *status, NSString *capacity)
{
    NSMutableDictionary *files = [NSMutableDictionary dictionary];
    [files setObject:ac forKey:kAcOnline];
    [files setObject:status forKey:kBatStatus];
    [files setObject:capacity forKey:kBatCapacity];
    [files setObject:@"39800000" forKey:kEnergyNow];
    [files setObject:@"15000000" forKey:kPowerNow];
    return files;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* --- the readings the extra had at load must not become permanent --- */
  START_SET("battery refresh after load");

  CountingContext *ctx = [[CountingContext alloc] initWithManager:nil
                                                        identifier:@"Battery"];
  FakeBattery *e = [[FakeBattery alloc] init];
  [e setContext:ctx];
  [e setSysfs:Battery(@"0", @"Discharging", @"70")];
  [e menuExtraDidLoad];

  PASS_EQUAL([e iconName], @"battery-medium",
             "70 percent on battery draws the medium icon");
  PASS([ctx invalidations] == 1,
       "the first real reading repaints the menu bar once (repaints: %ld)",
       (long)[ctx invalidations]);

  /* The machine is now on AC, but the extra has not looked yet.  Before the
     refresh paths existed this state - or worse, one from hours ago - is
     what stayed on screen. */
  [e setSysfs:Battery(@"1", @"Discharging", @"70")];
  PASS_EQUAL([e iconName], @"battery-medium",
             "the icon still shows the last reading until something refreshes");

  [e menuExtraWillOpenMenu];
  PASS_EQUAL([e iconName], @"battery-charged",
             "opening the menu re-reads the battery");
  PASS([ctx invalidations] == 2,
       "and repaints because the icon changed (repaints: %ld)",
       (long)[ctx invalidations]);

  /* The manager ticks every extra every 2 seconds; no menu was opened. */
  [e setSysfs:Battery(@"1", @"Charging", @"71")];
  {
    int i;
    for (i = 0; i < 60; i++)
      [e tick];
  }
  PASS_EQUAL([e iconName], @"battery-charging",
             "the tick re-reads the battery without the menu being opened");
  PASS([ctx invalidations] == 3,
       "and repaints because the icon changed (repaints: %ld)",
       (long)[ctx invalidations]);

  /* A reading that would not change the drawn icon costs no repaint: the
     percentage moves constantly while the icon does not. */
  [e setSysfs:Battery(@"1", @"Charging", @"66")];
  [e menuExtraWillOpenMenu];
  PASS_EQUAL([e iconName], @"battery-charging",
             "66 percent on AC still draws the charging icon");
  PASS([ctx invalidations] == 3,
       "no repaint while the icon would look the same (repaints: %ld)",
       (long)[ctx invalidations]);

  END_SET("battery refresh after load");

  /* --- nothing readable: say nothing rather than invent a charge level --- */
  START_SET("no battery data");

  CountingContext *noneCtx = [[CountingContext alloc] initWithManager:nil
                                                           identifier:@"Battery"];
  FakeBattery *none = [[FakeBattery alloc] init];
  [none setContext:noneCtx];
  [none setSysfs:[NSDictionary dictionary]];
  [none menuExtraDidLoad];

  PASS([none iconName] == nil,
       "with no battery data there is no icon at all, not a fake 0 percent");
  PASS([noneCtx invalidations] == 0,
       "and nothing to repaint (repaints: %ld)", (long)[noneCtx invalidations]);

  END_SET("no battery data");

  [arp release];
  return 0;
}
