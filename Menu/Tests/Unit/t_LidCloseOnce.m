/* t_LidCloseOnce.m - ObjectTesting coverage for EnergyLidCloseOnceArmer.
 *
 * "Stay awake at lid close" arms a one-shot inhibitor: the check mark in the
 * Battery extra's menu is on exactly while armed, and clears itself the
 * instant the lid closes once - covered here with a fake lid-event source
 * (the test fires "closed"/"opened" by hand, no real hardware or D-Bus) and
 * a fake inhibitor (records start/stop, can be told to fail so arming fails
 * hard instead of pretending to succeed).
 *
 * Headless: Foundation only, no display.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later OR BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
/* EnergyLidCloseOnceArmer is ARC (Libraries/EnergyBackend builds it that
 * way); Testing.h's PASS macros are not ARC-safe, so it is linked as a
 * separate object (per-file ARC flags in the GNUmakefile) rather than
 * #include-d into this non-ARC test translation unit. */
#import "EnergyLidCloseOnce.h"

@interface FakeLidEventSource : NSObject <EnergyLidEventSource>
{
    void (^_handler)(BOOL closed);
}
@property (nonatomic, readonly) NSInteger startCount;
@property (nonatomic, readonly) NSInteger stopCount;
- (void)simulateLidClosed:(BOOL)closed;
@end

@implementation FakeLidEventSource
- (void)setLidStateHandler:(void (^)(BOOL closed))handler
{
    _handler = [handler copy];
}
- (void)start
{
    _startCount++;
}
- (void)stop
{
    _stopCount++;
}
- (void)simulateLidClosed:(BOOL)closed
{
    if (_handler) {
        _handler(closed);
    }
}
@end

@interface FakeInhibitor : NSObject <EnergySleepInhibitor>
{
    BOOL _inhibiting;
}
@property (nonatomic) BOOL shouldFail;
@property (nonatomic, readonly) NSInteger startCount;
@property (nonatomic, readonly) NSInteger stopCount;
@end

@implementation FakeInhibitor
- (BOOL)startInhibitingLidHandlingWhy:(NSString *)why error:(NSError **)error
{
    (void)why;
    _startCount++;
    if (_shouldFail) {
        if (error) {
            *error = [NSError errorWithDomain:EnergyLidCloseOnceErrorDomain
                                          code:1
                                      userInfo:@{NSLocalizedDescriptionKey: @"fake failure"}];
        }
        return NO;
    }
    _inhibiting = YES;
    return YES;
}
- (void)stopInhibiting
{
    _stopCount++;
    _inhibiting = NO;
}
- (BOOL)isInhibiting
{
    return _inhibiting;
}
@end

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* --- the ordinary path: arm, lid closes once, consumed --- */
  START_SET("arm then one lid close");

  FakeLidEventSource *source = [[FakeLidEventSource alloc] init];
  FakeInhibitor *inhibitor = [[FakeInhibitor alloc] init];
  EnergyLidCloseOnceArmer *armer =
      [[EnergyLidCloseOnceArmer alloc] initWithLidEventSource:source
                                                      inhibitor:inhibitor];

  PASS(![armer isArmed], "starts unarmed");

  NSError *error = nil;
  BOOL armed = [armer armWithError:&error];
  PASS(armed, "arming succeeds when the inhibitor grants the lock");
  PASS([armer isArmed], "is armed right after -armWithError:");
  PASS([inhibitor startCount] == 1, "the inhibitor lock is taken exactly once");
  PASS([source startCount] == 1, "the lid source is told to start watching");

  [source simulateLidClosed:NO];
  PASS([armer isArmed],
       "an 'opened' event while armed changes nothing - only a close consumes it");
  PASS([inhibitor stopCount] == 0, "and the lock is not released for it");

  [source simulateLidClosed:YES];
  PASS(![armer isArmed], "the first lid close consumes the arm");
  PASS([armer state] == EnergyLidArmStateUnarmed,
       "the machine lands back in the unarmed state, not stuck consumed");
  PASS([inhibitor stopCount] == 1, "the lock is released once the close was handled");
  PASS([source stopCount] == 1, "and the lid source is told to stop watching");

  [source simulateLidClosed:YES];
  PASS([inhibitor stopCount] == 1,
       "a second close with nothing armed does not double-release the lock");

  END_SET("arm then one lid close");

  /* --- cancelling before the lid ever closes --- */
  START_SET("disarm before any close");

  FakeLidEventSource *source2 = [[FakeLidEventSource alloc] init];
  FakeInhibitor *inhibitor2 = [[FakeInhibitor alloc] init];
  EnergyLidCloseOnceArmer *armer2 =
      [[EnergyLidCloseOnceArmer alloc] initWithLidEventSource:source2
                                                      inhibitor:inhibitor2];
  [armer2 armWithError:NULL];
  [armer2 disarm];
  PASS(![armer2 isArmed], "disarm clears the check mark");
  PASS([inhibitor2 stopCount] == 1, "and releases the lock");

  [armer2 disarm];
  PASS([inhibitor2 stopCount] == 1, "disarming twice does not release twice");

  END_SET("disarm before any close");

  /* --- the inhibitor refuses the lock: fail hard, never pretend --- */
  START_SET("inhibitor refuses");

  FakeLidEventSource *source3 = [[FakeLidEventSource alloc] init];
  FakeInhibitor *inhibitor3 = [[FakeInhibitor alloc] init];
  [inhibitor3 setShouldFail:YES];
  EnergyLidCloseOnceArmer *armer3 =
      [[EnergyLidCloseOnceArmer alloc] initWithLidEventSource:source3
                                                      inhibitor:inhibitor3];
  NSError *error3 = nil;
  BOOL armed3 = [armer3 armWithError:&error3];
  PASS(!armed3, "arming fails when the inhibitor cannot take the lock");
  PASS(error3 != nil, "and hands back an error rather than failing silently");
  PASS(![armer3 isArmed], "so the check mark never lights up for a lock we do not hold");
  PASS([source3 startCount] == 0,
       "the lid source is never started for an arm that did not take");

  END_SET("inhibitor refuses");

  /* --- arming twice is idempotent, not a second lock --- */
  START_SET("double arm");

  FakeLidEventSource *source4 = [[FakeLidEventSource alloc] init];
  FakeInhibitor *inhibitor4 = [[FakeInhibitor alloc] init];
  EnergyLidCloseOnceArmer *armer4 =
      [[EnergyLidCloseOnceArmer alloc] initWithLidEventSource:source4
                                                      inhibitor:inhibitor4];
  [armer4 armWithError:NULL];
  [armer4 armWithError:NULL];
  PASS([inhibitor4 startCount] == 1, "arming while already armed takes no second lock");

  END_SET("double arm");

  [arp release];
  return 0;
}
