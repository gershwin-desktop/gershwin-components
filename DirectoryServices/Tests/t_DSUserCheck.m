/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Whether dscli may create a user, decided against injected lookups; no
 * real account is read or created. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "DSUserCheck.h"

static DSNameLookup Names(NSDictionary *table)
{
    return [[^DSLookupResult(NSString *n) {
        return table[n] ? (DSLookupResult)[table[n] integerValue] : DSLookupNotFound;
    } copy] autorelease];
}

static DSUIDLookup UIDs(NSDictionary *table)
{
    return [[^DSLookupResult(uid_t u) {
        NSNumber *k = @(u);
        return table[k] ? (DSLookupResult)[table[k] integerValue] : DSLookupNotFound;
    } copy] autorelease];
}

int main(void)
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    NSDictionary *none = @{};
    NSDictionary *found = @{@"alice": @(DSLookupFound)};
    NSDictionary *failed = @{@"alice": @(DSLookupFailed)};

    PASS([DSUserCheck errorForNewUserName:@"bob" uid:6000
                               nameLookup:Names(found) uidLookup:UIDs(none)] == nil,
         "free name and free UID pass");

    NSString *e = [DSUserCheck errorForNewUserName:@"alice" uid:6000
                                        nameLookup:Names(found) uidLookup:UIDs(none)];
    PASS(e != nil && [e rangeOfString:@"already exists"].location != NSNotFound,
         "name known to the system database is refused");

    e = [DSUserCheck errorForNewUserName:@"alice" uid:0
                              nameLookup:Names(failed) uidLookup:UIDs(none)];
    PASS(e != nil && [e rangeOfString:@"Cannot check"].location != NSNotFound,
         "failed name lookup is an error, not 'free'");

    e = [DSUserCheck errorForNewUserName:@"bob" uid:1000
                              nameLookup:Names(none)
                               uidLookup:UIDs(@{@1000: @(DSLookupFound)})];
    PASS(e != nil && [e rangeOfString:@"UID 1000"].location != NSNotFound,
         "UID used elsewhere is refused");

    e = [DSUserCheck errorForNewUserName:@"bob" uid:1000
                              nameLookup:Names(none)
                               uidLookup:UIDs(@{@1000: @(DSLookupFailed)})];
    PASS(e != nil && [e rangeOfString:@"Cannot check"].location != NSNotFound,
         "failed UID lookup is an error");

    PASS([DSUserCheck errorForNewUserName:@"bob" uid:0
                               nameLookup:Names(none)
                                uidLookup:UIDs(@{@0: @(DSLookupFound)})] == nil,
         "UID 0 means not chosen and is not looked up");

    NSDictionary *taken = @{@5001: @(DSLookupFound), @5002: @(DSLookupFound)};
    PASS([DSUserCheck firstFreeUIDFrom:5001 uidLookup:UIDs(taken)] == 5003,
         "auto UID skips UIDs used elsewhere");
    PASS([DSUserCheck firstFreeUIDFrom:5001 uidLookup:UIDs(none)] == 5001,
         "auto UID keeps a free candidate");
    PASS([DSUserCheck firstFreeUIDFrom:5001
                             uidLookup:UIDs(@{@5001: @(DSLookupFailed)})] == 0,
         "auto UID fails on a failed lookup");

    /* The real lookups: root exists on every system, the other name cannot. */
    PASS([DSUserCheck systemNameLookup](@"root") == DSLookupFound,
         "system lookup finds root");
    PASS([DSUserCheck systemNameLookup](@"no-such-user-dscli-test") == DSLookupNotFound,
         "system lookup does not find an absent name");
    PASS([DSUserCheck systemUIDLookup](0) == DSLookupFound,
         "system lookup finds UID 0");

    [pool release];
    return 0;
}
