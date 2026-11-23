/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* CUPS lets a member of its admin group change printers only after the member
 * has given a password, and libcups asks for it on a terminal, which a desktop
 * program does not have.  This hands it the password from the session's
 * SUDO_ASKPASS program, the window every other privileged step of the desktop
 * asks in. */
@interface CupsAuthentication : NSObject

/* Makes libcups ask through the SUDO_ASKPASS program of the environment. */
+ (void)install;

/* The password the helper at helperPath prints for the prompt; nil when there
 * is no helper, it fails or the answer is empty (the user cancelled). */
+ (NSString *)passwordFromHelper:(NSString *)helperPath prompt:(NSString *)prompt;

@end
