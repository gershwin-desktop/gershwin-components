/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <sys/types.h>

typedef NS_ENUM(NSInteger, DSLookupResult) {
    DSLookupNotFound = 0,
    DSLookupFound,
    // The source could not be queried (e.g. an unreachable NIS or LDAP
    // server); the answer "not found" cannot be trusted then.
    DSLookupFailed
};

typedef DSLookupResult (^DSNameLookup)(NSString *name);
typedef DSLookupResult (^DSUIDLookup)(uid_t uid);

/* Decides whether a new user may be created, given lookups against every
 * source NSS knows (files, NIS, LDAP, ...). The lookups are injected so the
 * decision can be tested without real accounts. */
@interface DSUserCheck : NSObject

// nil if the name and the UID (0 = not chosen yet) are free, else the
// message to print. A failed lookup is an error, never "free".
+ (NSString *)errorForNewUserName:(NSString *)name
                              uid:(uid_t)uid
                       nameLookup:(DSNameLookup)nameLookup
                        uidLookup:(DSUIDLookup)uidLookup;

// First UID >= candidate that no source uses; returns 0 on a failed lookup.
+ (uid_t)firstFreeUIDFrom:(uid_t)candidate uidLookup:(DSUIDLookup)uidLookup;

// Lookups through getpwnam/getpwuid, i.e. everything in nsswitch.conf.
+ (DSNameLookup)systemNameLookup;
+ (DSUIDLookup)systemUIDLookup;

@end
