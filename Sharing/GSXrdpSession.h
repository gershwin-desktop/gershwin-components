/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* Makes xrdp start the Gershwin session for a user.
 *
 * xrdp's sesman runs ~/startwm.sh in preference to the system-wide
 * startwm.sh (EnableUserWindowManager/UserWindowManager in sesman.ini). The
 * system one hands over to the distribution's default session, which does not
 * start Gershwin. A per-user wrapper changes only what that user gets over
 * RDP; /etc and the sessions of other users and of the local login are left
 * alone, so no privileges are needed. */
@interface GSXrdpSession : NSObject

/* Path of the session script that Gershwin logins run. */
+ (NSString *)defaultSessionScript;

/* YES if homeDirectory/startwm.sh is the wrapper written by this class. */
+ (BOOL)isConfiguredInHome:(NSString *)homeDirectory;

/* Installs the wrapper. A startwm.sh the user already has is moved to
 * startwm.sh.gershwin-backup first. Idempotent. Fails (and writes nothing) if
 * the session script is not executable, or if a foreign startwm.sh and a
 * backup both already exist. */
+ (BOOL)configureInHome:(NSString *)homeDirectory
          sessionScript:(NSString *)sessionScript
                  error:(NSError **)error;

/* Removes the wrapper and brings back the backed up startwm.sh, if any.
 * Fails on a startwm.sh that is not ours. */
+ (BOOL)restoreInHome:(NSString *)homeDirectory error:(NSError **)error;

@end
