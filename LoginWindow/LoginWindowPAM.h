/*
 * Copyright (c) 2025-26 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef _LOGINWINDOW_PAM_H_
#define _LOGINWINDOW_PAM_H_

#import <Foundation/Foundation.h>
#include <security/pam_appl.h>

@interface LoginWindowPAM : NSObject
{
    @public
    pam_handle_t *pam_handle;
    struct pam_conv pam_conversation;
    NSString *_storedUsername;
    NSString *_storedPassword;
    BOOL authenticationInProgress;
}

@property (readonly) NSString *storedUsername;
@property (readonly) NSString *storedPassword;
@property (readonly) NSString *lastErrorMessage;

- (id)init;
- (void)dealloc;
- (BOOL)authenticateUser:(NSString *)username password:(NSString *)password;
- (BOOL)openSessionForUser:(NSString *)username;
- (BOOL)openSession;
- (BOOL)openSessionAsUser;
- (void)closeSession;
- (void)clearCredentials;
- (char **)getEnvironmentList;
- (NSString *)getLastError;

@end

// C function for PAM conversation callback
int loginwindow_pam_conv(int num_msg, const struct pam_message **msg,
                        struct pam_response **resp, void *appdata_ptr);

#endif /* _LOGINWINDOW_PAM_H_ */
