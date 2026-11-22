/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

/* Asks for the user name and password a scanner or scan server requires */
@interface SCPasswordPanel : NSObject

/* Runs modally on the main thread; may be called from any thread */
+ (BOOL) askForResource: (NSString *)resource
                   user: (NSString **)user
               password: (NSString **)password;

@end
