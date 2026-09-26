/* t_DKLineMerge.m - ObjectTesting coverage for DKLineMerge. Headless.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../../DKLineMerge.m"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  NSString *base = @"- [ ] Buy milk\n- [ ] Walk dog\n- [ ] Pay rent\n";

  /* --- only local changed: local wins, no conflict --- */
  {
    NSString *local = @"- [x] Buy milk\n- [ ] Walk dog\n- [ ] Pay rent\n";
    BOOL conflict = YES;
    NSString *merged = [DKLineMerge mergeBase: base local: local remote: base conflict: &conflict];

    PASS(conflict == NO, "a remote-unchanged file is not a conflict");
    PASS_EQUAL(merged, local, "local's edit wins when remote did not change");
  }

  /* --- only remote changed: remote wins, no conflict --- */
  {
    NSString *remote = @"- [ ] Buy milk\n- [x] Walk dog\n- [ ] Pay rent\n";
    BOOL conflict = YES;
    NSString *merged = [DKLineMerge mergeBase: base local: base remote: remote conflict: &conflict];

    PASS(conflict == NO, "a local-unchanged file is not a conflict");
    PASS_EQUAL(merged, remote, "remote's edit wins when local did not change");
  }

  /* --- both sides made the identical edit: no conflict --- */
  {
    NSString *same = @"- [x] Buy milk\n- [ ] Walk dog\n- [ ] Pay rent\n";
    BOOL conflict = YES;
    NSString *merged = [DKLineMerge mergeBase: base local: same remote: same conflict: &conflict];

    PASS(conflict == NO, "an identical edit on both sides is not a conflict");
    PASS_EQUAL(merged, same, "the shared edit is kept");
  }

  /* --- both sides changed the SAME line differently, plus each has an
   * untouched line elsewhere: neither edit is silently dropped --- */
  {
    NSString *local = @"- [x] Buy milk\n- [ ] Walk dog\n- [ ] Pay rent\n";
    NSString *remote = @"- [ ] Buy bread\n- [ ] Walk dog\n- [ ] Pay rent\n";
    BOOL conflict = NO;
    NSString *merged = [DKLineMerge mergeBase: base local: local remote: remote conflict: &conflict];

    PASS(conflict == YES, "editing the same line differently on both sides is a conflict");
    PASS([merged rangeOfString: @"Buy milk"].location != NSNotFound, "local's edit survives inside the conflict block");
    PASS([merged rangeOfString: @"Buy bread"].location != NSNotFound, "remote's edit survives inside the conflict block");
    PASS([merged rangeOfString: @"Walk dog"].location != NSNotFound, "an untouched line outside the conflict is preserved");
    PASS([merged rangeOfString: @"<<<<<<< local"].location != NSNotFound, "conflict is marked so it is never silently resolved");
  }

  [arp release];
  return 0;
}
