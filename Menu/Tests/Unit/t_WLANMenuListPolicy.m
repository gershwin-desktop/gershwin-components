/* t_WLANMenuListPolicy.m - ObjectTesting coverage for the WLAN extra's
 * scan-result-vs-cache decision: pins the bug where an empty scan (common
 * while associated, since several drivers suppress full scans then) wiped
 * out the last known network list just because the radio was connected.
 * Headless, no backend or hardware needed.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "WLANMenuListPolicy.h"

static WLAN *MakeWLAN(NSString *ssid, int signal)
{
    WLAN *w = [[WLAN alloc] init];
    [w setSsid:ssid];
    [w setSignalStrength:signal];
    return w;
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    NSArray<WLAN *> *cached = @[MakeWLAN(@"HomeNet", -40), MakeWLAN(@"Neighbor", -70)];

    /* --- the bug this test pins --- */
    {
        NSArray<WLAN *> *result = [WLANMenuListPolicy networkListAfterScan:@[]
                                                                   cachedList:cached
                                                                    connected:YES];
        PASS([result count] == 2, "an empty scan while connected keeps the cached list, not an empty menu");
        PASS_EQUAL(result, cached, "the exact cached list survives an empty connected scan");
    }

    /* --- an empty scan while disconnected also keeps the cache --- */
    {
        NSArray<WLAN *> *result = [WLANMenuListPolicy networkListAfterScan:@[]
                                                                   cachedList:cached
                                                                    connected:NO];
        PASS([result count] == 2, "an empty scan while disconnected also keeps the cached list");
    }

    /* --- a real scan result replaces the cache, connected or not --- */
    {
        NSArray<WLAN *> *fresh = @[MakeWLAN(@"HomeNet", -35), MakeWLAN(@"CoffeeShop", -55), MakeWLAN(@"Neighbor", -72)];
        NSArray<WLAN *> *result = [WLANMenuListPolicy networkListAfterScan:fresh
                                                                   cachedList:cached
                                                                    connected:YES];
        PASS([result count] == 3, "a scan that found networks replaces the stale cache");
        PASS_EQUAL(result, fresh, "the fresh scan result is what gets shown, not a merge with the old one");
    }

    /* --- no cache yet and an empty scan: an empty menu, not a crash --- */
    {
        NSArray<WLAN *> *result = [WLANMenuListPolicy networkListAfterScan:@[]
                                                                   cachedList:nil
                                                                    connected:NO];
        PASS(result != nil && [result count] == 0, "with nothing cached yet, an empty scan yields an empty (not nil) list");
    }

    [arp release];
    return 0;
}
