/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Turns the feed's license strings into something a person can read, and
// finds the license text when the feed pointed at one.
@interface AGLicenseFormatter : NSObject

// Nil and NOASSERTION mean the publisher never said; the proprietary
// references collapse to one word; the two GPL-3.0 spellings are the same
// license. Everything else is already an identifier and is shown as it is.
+ (NSString *)displayStringForLicense:(NSString *)raw;

// The address after "=" in a LicenseRef value, else nil, so the detail page
// links the license only when there is somewhere to go.
+ (NSURL *)licenseURLForLicense:(NSString *)raw;

// YES when the feed said nothing useful: no license, an empty one, or
// NOASSERTION. Those are the items worth asking GitHub about.
+ (BOOL)isUnknownLicense:(NSString *)raw;

@end
