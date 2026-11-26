/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* CaptivePortalDetector is built without ARC and hands a copy of its
   completion block to a background thread.  The copy was never balanced, so
   every check leaked a block and everything the block captured (the WLAN menu
   extra among it).  The probe does one HTTP request; when it does not answer
   within the timeout the test reports that it did not run. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "CaptivePortalDetector.h"

static int gDeallocs = 0;

@interface Witness : NSObject
@end

@implementation Witness
- (void)dealloc
{
  gDeallocs++;
  [super dealloc];
}
@end

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  __block BOOL called = NO;
  @autoreleasepool
    {
      Witness *witness = [[Witness alloc] init];
      [CaptivePortalDetector checkForCaptivePortalForceWithCompletion:
        ^(BOOL isCaptive, NSString *redirectURL)
        {
          (void)witness;
          called = YES;
        }];
      [witness release];
    }

  NSDate *limit = [NSDate dateWithTimeIntervalSinceNow: 20.0];
  while (!called && [limit timeIntervalSinceNow] > 0)
    {
      [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                               beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.1]];
    }
  if (!called)
    {
      fprintf(stderr, "t_CaptivePortalBlock: no answer from the probe, not run\n");
      [arp release];
      return 0;
    }

  /* Let the pool that held the block's last reference drain. */
  [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                           beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.5]];

  PASS(gDeallocs == 1, "the completion block and what it captured are released after the check");

  [arp release];
  return 0;
}
