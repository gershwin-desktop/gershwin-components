/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * OnDemand — GNUstep bundle loaded into every GUI app via GSAppKitUserBundles.
 * When an app launches, checks whether it ships a Resources/Dependencies.plist
 * and offers to install missing packages via OnDemand.app.
 */

#import <Foundation/Foundation.h>

@interface OnDemand : NSObject
{
}

+ (void)load;

/* For a bundle that wants packages when the user asks for a feature, instead of
   when it is selected: the packages the plist names for this system that are
   not installed (empty when all are, or when the system's base ships them),
   and a dialog that offers to install them.  The second returns YES when
   nothing is missing afterwards.  The plist has the shape of a
   Dependencies.plist. */
+ (NSArray *)missingPackagesFromPlistAtPath:(NSString *)plistPath;
+ (BOOL)installPackagesFromPlistAtPath:(NSString *)plistPath title:(NSString *)title;

@end
