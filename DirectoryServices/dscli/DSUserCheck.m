/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DSUserCheck.h"
#import <errno.h>
#import <pwd.h>

// getpwnam/getpwuid return NULL both for "no such user" and for a failure;
// only errno tells them apart, and the libcs differ in which "not found"
// errno values they leave behind.
static DSLookupResult resultForPasswd(struct passwd *pw)
{
    if (pw != NULL) {
        return DSLookupFound;
    }
    switch (errno) {
    case 0:
    case ENOENT:
    case ESRCH:
    case EBADF:
    case EPERM:
    case ENOTTY:
        return DSLookupNotFound;
    default:
        return DSLookupFailed;
    }
}

@implementation DSUserCheck

+ (NSString *)errorForNewUserName:(NSString *)name
                              uid:(uid_t)uid
                       nameLookup:(DSNameLookup)nameLookup
                        uidLookup:(DSUIDLookup)uidLookup
{
    switch (nameLookup(name)) {
    case DSLookupFound:
        return [NSString stringWithFormat:
            @"User already exists in the system user database: %@", name];
    case DSLookupFailed:
        return [NSString stringWithFormat:
            @"Cannot check whether user exists in the system user database: %@",
            name];
    case DSLookupNotFound:
        break;
    }
    if (uid != 0) {
        switch (uidLookup(uid)) {
        case DSLookupFound:
            return [NSString stringWithFormat:
                @"UID %u is already used in the system user database",
                (unsigned)uid];
        case DSLookupFailed:
            return [NSString stringWithFormat:
                @"Cannot check whether UID %u is used in the system user database",
                (unsigned)uid];
        case DSLookupNotFound:
            break;
        }
    }
    return nil;
}

+ (uid_t)firstFreeUIDFrom:(uid_t)candidate uidLookup:(DSUIDLookup)uidLookup
{
    for (uid_t uid = candidate; uid != 0; uid++) {
        switch (uidLookup(uid)) {
        case DSLookupNotFound:
            return uid;
        case DSLookupFailed:
            return 0;
        case DSLookupFound:
            break;
        }
    }
    return 0;
}

+ (DSNameLookup)systemNameLookup
{
    return ^DSLookupResult(NSString *name) {
        errno = 0;
        return resultForPasswd(getpwnam([name UTF8String]));
    };
}

+ (DSUIDLookup)systemUIDLookup
{
    return ^DSLookupResult(uid_t uid) {
        errno = 0;
        return resultForPasswd(getpwuid(uid));
    };
}

@end
