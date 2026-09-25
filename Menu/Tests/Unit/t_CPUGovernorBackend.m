/* t_CPUGovernorBackend.m - ObjectTesting coverage for CPUGovernorBackend's
 * pure logic: the sysfs governor-list parse and the check-mark index a menu
 * needs.  Headless, no /sys tree or hardware required.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "CPUGovernorBackend.h"

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    /* --- parseAvailableGovernorsFromSysfsList: --- */
    {
        NSArray *parsed = [CPUGovernorBackend
            parseAvailableGovernorsFromSysfsList:@"performance powersave"];
        NSArray *want = @[@"performance", @"powersave"];
        PASS_EQUAL(parsed, want, "splits a two-governor sysfs line in order");
    }
    {
        NSArray *parsed = [CPUGovernorBackend
            parseAvailableGovernorsFromSysfsList:@"conservative ondemand userspace powersave performance schedutil\n"];
        PASS([parsed count] == 6, "keeps every governor on a longer line");
        PASS_EQUAL([parsed objectAtIndex:0], @"conservative", "preserves the sysfs order (first entry)");
        PASS_EQUAL([parsed lastObject], @"schedutil", "preserves the sysfs order (last entry)");
    }
    {
        /* A host with no cpufreq driver has no such file; the sysfs read
           returns an empty string, not nil. The Energy prefPane's fallback
           for this case is ["powersave", "performance"] - keep matching it,
           since it is what the check-mark logic expects to find. */
        NSArray *parsed = [CPUGovernorBackend parseAvailableGovernorsFromSysfsList:@""];
        NSArray *want = @[@"powersave", @"performance"];
        PASS_EQUAL(parsed, want, "falls back to the two universal governors when sysfs has nothing");
    }

    /* --- indexOfGovernor:inList: (check-mark selection state) --- */
    {
        NSArray *govs = @[@"performance", @"powersave", @"schedutil"];
        PASS([CPUGovernorBackend indexOfGovernor:@"powersave" inList:govs] == 1,
             "finds the current governor's position for the check mark");
    }
    {
        NSArray *govs = @[@"performance", @"powersave"];
        PASS([CPUGovernorBackend indexOfGovernor:@"schedutil" inList:govs] == NSNotFound,
             "reports no check mark when the current governor is not in the list");
    }
    {
        NSArray *govs = @[@"performance", @"powersave"];
        PASS([CPUGovernorBackend indexOfGovernor:nil inList:govs] == NSNotFound,
             "an unreadable current governor (nil) checks nothing rather than crashing");
    }

    [arp release];
    return 0;
}
