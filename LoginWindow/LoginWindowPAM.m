/*
 * Copyright (c) 2025-26 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "LoginWindowPAM.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>
#if defined(__linux__)
#include <shadow.h>
#endif

// C function for PAM conversation callback
int loginwindow_pam_conv(int num_msg, const struct pam_message **msg,
                        struct pam_response **resp, void *appdata_ptr)
{
    NSDebugLLog(@"gwcomp", @"[PAM] Conversation callback invoked with %d messages", num_msg);
    LoginWindowPAM *pamObj = (__bridge LoginWindowPAM *)appdata_ptr;
    *resp = (struct pam_response *)calloc(num_msg, sizeof(struct pam_response));
    
    if (!*resp) {
        NSDebugLLog(@"gwcomp", @"[PAM] calloc failed for pam_response");
        return PAM_BUF_ERR;
    }
    
    int result = PAM_SUCCESS;
    
    for (int i = 0; i < num_msg; i++) {
        (*resp)[i].resp = NULL;
        (*resp)[i].resp_retcode = 0;
        NSDebugLLog(@"gwcomp", @"[PAM] Message %d: style=%d, msg='%s'", i, msg[i]->msg_style, msg[i]->msg);
        switch (msg[i]->msg_style) {
            case PAM_PROMPT_ECHO_ON:
                NSDebugLLog(@"gwcomp", @"[PAM] Prompt for username");
                if ([pamObj storedUsername]) {
                    (*resp)[i].resp = strdup([[pamObj storedUsername] UTF8String]);
                    NSDebugLLog(@"gwcomp", @"[PAM] Responded with username: %@", [pamObj storedUsername]);
                } else {
                    NSDebugLLog(@"gwcomp", @"[PAM] No username stored");
                }
                break;
            case PAM_PROMPT_ECHO_OFF:
                NSDebugLLog(@"gwcomp", @"[PAM] Prompt for password");
                if ([pamObj storedPassword]) {
                    (*resp)[i].resp = strdup([[pamObj storedPassword] UTF8String]);
                    NSDebugLLog(@"gwcomp", @"[PAM] Responded with password (hidden)");
                } else {
                    NSDebugLLog(@"gwcomp", @"[PAM] No password stored");
                }
                break;
            case PAM_ERROR_MSG:
            case PAM_TEXT_INFO:
                NSDebugLLog(@"gwcomp", @"[PAM] Info/Error: %s", msg[i]->msg);
                break;
            default:
                NSDebugLLog(@"gwcomp", @"[PAM] Unknown message style: %d", msg[i]->msg_style);
                result = PAM_CONV_ERR;
                break;
        }
        if (result != PAM_SUCCESS) {
            NSDebugLLog(@"gwcomp", @"[PAM] Conversation error at message %d", i);
            break;
        }
    }
    if (result != PAM_SUCCESS) {
        for (int i = 0; i < num_msg; i++) {
            if ((*resp)[i].resp) {
                free((*resp)[i].resp);
                (*resp)[i].resp = NULL;
            }
        }
        free(*resp);
        *resp = NULL;
        NSDebugLLog(@"gwcomp", @"[PAM] Conversation failed, responses freed");
    }
    return result;
}

@implementation LoginWindowPAM

@synthesize storedUsername = _storedUsername;
@synthesize storedPassword = _storedPassword;
@synthesize lastErrorMessage = _lastErrorMessage;

- (id)init
{
    self = [super init];
    if (self) {
        pam_handle = NULL;
        pam_conversation.conv = loginwindow_pam_conv;
        pam_conversation.appdata_ptr = (__bridge void *)self;
        _storedUsername = nil;
        _storedPassword = nil;
        _lastErrorMessage = nil;
        authenticationInProgress = NO;
        NSDebugLLog(@"gwcomp", @"[PAM] LoginWindowPAM initialized");
    }
    return self;
}

- (void)dealloc
{
    NSDebugLLog(@"gwcomp", @"[PAM] Dealloc called");
    if (pam_handle) {
        pam_end(pam_handle, PAM_SUCCESS);
        pam_handle = NULL;
        NSDebugLLog(@"gwcomp", @"[PAM] pam_end called in dealloc");
    }
    [_storedUsername release];
    [_storedPassword release];
    [_lastErrorMessage release];
    [super dealloc];
}

- (BOOL)authenticateUser:(NSString *)username password:(NSString *)password
{
    NSDebugLLog(@"gwcomp", @"[PAM] Starting authentication for user: %@", username);
    if (authenticationInProgress) {
        NSDebugLLog(@"gwcomp", @"[PAM] Authentication already in progress");
        return NO;
    }
    authenticationInProgress = YES;
    [_storedUsername release];
    [_storedPassword release];
    _storedUsername = [username copy];
    _storedPassword = [password copy];
    NSDebugLLog(@"gwcomp", @"[PAM] Credentials stored: username=%@ password=%@", _storedUsername, _storedPassword ? @"(hidden)" : @"(nil)");
    
    BOOL passwordProvided = (_storedPassword && [_storedPassword length] > 0);
    
    // Determine if the account is passwordless (no password set).
    // pam_unix.so nullok would accept ANY password for such accounts,
    // so we reject non-empty passwords here and skip the verify step
    // for empty ones to avoid the nullok pitfall.
    BOOL accountIsPasswordless = NO;
#if defined(__linux__)
    struct spwd *sp = getspnam([username UTF8String]);
    if (sp && sp->sp_pwdp && sp->sp_pwdp[0] == '\0') {
        accountIsPasswordless = YES;
    } else if (!sp) {
        // No shadow entry (e.g. user has * in passwd but no shadow).
        // Without a shadow entry PAM has no hash to verify against,
        // so nullok accepts any password - treat as passwordless.
        accountIsPasswordless = YES;
    }
#endif
    if (accountIsPasswordless && passwordProvided) {
        NSDebugLLog(@"gwcomp", @"[PAM] Account has no password; rejecting non-empty password");
        [_lastErrorMessage release];
        _lastErrorMessage = [@"Authentication failure" retain];
        [_storedPassword release];
        _storedPassword = nil;
        authenticationInProgress = NO;
        return NO;
    }
    
    // Use standard "login" PAM service
    NSDebugLLog(@"gwcomp", @"[PAM] Calling pam_start with service='login', user='%s'", [username UTF8String]);
    int result = pam_start("login", [username UTF8String], &pam_conversation, &pam_handle);
    NSDebugLLog(@"gwcomp", @"[PAM] pam_start returned: %d", result);
    if (pam_handle != NULL) {
        NSDebugLLog(@"gwcomp", @"[PAM] pam_start error message: %s", pam_strerror(pam_handle, result));
    } else {
        NSDebugLLog(@"gwcomp", @"[PAM] pam_start failed and pam_handle is NULL");
    }
    if (result != PAM_SUCCESS) {
        const char *error = pam_handle ? pam_strerror(pam_handle, result) : "unknown error";
        NSDebugLLog(@"gwcomp", @"[PAM] pam_start FAILED with code %d: %s (errno=%d: %s)", result, error, errno, strerror(errno));
        [_lastErrorMessage release];
        _lastErrorMessage = [[NSString stringWithFormat:@"PAM initialization failed: %s", error] retain];
        authenticationInProgress = NO;
        return NO;
    }
    result = pam_set_item(pam_handle, PAM_TTY, ttyname(STDIN_FILENO));
    NSDebugLLog(@"gwcomp", @"[PAM] pam_set_item PAM_TTY result: %d (%s)", result, pam_strerror(pam_handle, result));
    
    char hostname[256];
    if (gethostname(hostname, sizeof(hostname)) == 0) {
        pam_set_item(pam_handle, PAM_RHOST, hostname);
        NSDebugLLog(@"gwcomp", @"[PAM] pam_set_item PAM_RHOST: %s", hostname);
    } else {
        NSDebugLLog(@"gwcomp", @"[PAM] gethostname failed");
    }
    if (passwordProvided || !accountIsPasswordless) {
        result = pam_authenticate(pam_handle, 0);
        NSDebugLLog(@"gwcomp", @"[PAM] pam_authenticate result: %d (%s)", result, pam_strerror(pam_handle, result));
        if (result != PAM_SUCCESS) {
            const char *error = pam_strerror(pam_handle, result);
            NSDebugLLog(@"gwcomp", @"[PAM] pam_authenticate failed: %s", error);
            [_lastErrorMessage release];
            _lastErrorMessage = [[NSString stringWithFormat:@"Authentication failed: %s", error] retain];
            pam_end(pam_handle, result);
            pam_handle = NULL;
            authenticationInProgress = NO;
            [_storedPassword release];
            _storedPassword = nil;
            return NO;
        }
    } else {
        NSDebugLLog(@"gwcomp", @"[PAM] Passwordless account with empty password - skipping pam_authenticate");
    }
    result = pam_acct_mgmt(pam_handle, PAM_SILENT);
    NSDebugLLog(@"gwcomp", @"[PAM] pam_acct_mgmt result: %d (%s)", result, pam_strerror(pam_handle, result));
    if (result != PAM_SUCCESS) {
        const char *error = pam_strerror(pam_handle, result);
        NSDebugLLog(@"gwcomp", @"[PAM] pam_acct_mgmt failed: %s", error);
        [_lastErrorMessage release];
        _lastErrorMessage = [[NSString stringWithFormat:@"Account management failed: %s", error] retain];
        pam_end(pam_handle, result);
        pam_handle = NULL;
        authenticationInProgress = NO;
        [_storedPassword release];
        _storedPassword = nil;
        return NO;
    }
    authenticationInProgress = NO;
    [_storedPassword release];
    _storedPassword = nil;
    NSDebugLLog(@"gwcomp", @"[PAM] Authentication succeeded for user: %@", username);
    return YES;
}

- (BOOL)openSession
{
    NSDebugLLog(@"gwcomp", @"[PAM] openSession called (as root - DEPRECATED, should use openSessionAsUser after setuid)");
    if (!pam_handle) {
        NSDebugLLog(@"gwcomp", @"[PAM] openSession failed: pam_handle is NULL");
        return NO;
    }
    int result = pam_setcred(pam_handle, PAM_ESTABLISH_CRED);
    NSDebugLLog(@"gwcomp", @"[PAM] pam_setcred result: %d (%s)", result, pam_strerror(pam_handle, result));
    if (result != PAM_SUCCESS) {
        const char *error = pam_strerror(pam_handle, result);
        NSDebugLLog(@"gwcomp", @"[PAM] pam_setcred failed: %s", error);
        [_lastErrorMessage release];
        _lastErrorMessage = [[NSString stringWithFormat:@"Failed to establish credentials: %s", error] retain];
        return NO;
    }
    result = pam_open_session(pam_handle, 0);
    NSDebugLLog(@"gwcomp", @"[PAM] pam_open_session result: %d (%s)", result, pam_strerror(pam_handle, result));
    if (result != PAM_SUCCESS) {
        const char *error = pam_strerror(pam_handle, result);
        NSDebugLLog(@"gwcomp", @"[PAM] pam_open_session failed: %s", error);
        [_lastErrorMessage release];
        _lastErrorMessage = [[NSString stringWithFormat:@"Failed to open session: %s", error] retain];
        pam_setcred(pam_handle, PAM_DELETE_CRED);
        return NO;
    }
    NSDebugLLog(@"gwcomp", @"[PAM] Session opened successfully");
    return YES;
}

- (BOOL)openSessionAsUser
{
    NSDebugLLog(@"gwcomp", @"[PAM] openSessionAsUser called (after setuid)");
    if (!pam_handle) {
        NSDebugLLog(@"gwcomp", @"[PAM] openSessionAsUser failed: pam_handle is NULL");
        return NO;
    }
    
    uid_t uid = getuid();
    NSDebugLLog(@"gwcomp", @"[PAM] Current uid: %d", uid);
    
    int result = pam_setcred(pam_handle, PAM_ESTABLISH_CRED);
    NSDebugLLog(@"gwcomp", @"[PAM] pam_setcred (ESTABLISH) result: %d (%s)", result, pam_strerror(pam_handle, result));
    if (result != PAM_SUCCESS) {
        const char *error = pam_strerror(pam_handle, result);
        NSDebugLLog(@"gwcomp", @"[PAM] pam_setcred (ESTABLISH) failed: %s", error);
        [_lastErrorMessage release];
        _lastErrorMessage = [[NSString stringWithFormat:@"Failed to establish credentials: %s", error] retain];
        return NO;
    }
    
    result = pam_open_session(pam_handle, 0);
    NSDebugLLog(@"gwcomp", @"[PAM] pam_open_session result: %d (%s)", result, pam_strerror(pam_handle, result));
    if (result != PAM_SUCCESS) {
        const char *error = pam_strerror(pam_handle, result);
        NSDebugLLog(@"gwcomp", @"[PAM] pam_open_session failed: %s", error);
        [_lastErrorMessage release];
        _lastErrorMessage = [[NSString stringWithFormat:@"Failed to open session: %s", error] retain];
        pam_setcred(pam_handle, PAM_DELETE_CRED);
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"[PAM] Session opened successfully as user %d", uid);
    return YES;
}

- (void)closeSession
{
    NSDebugLLog(@"gwcomp", @"[PAM] closeSession called");
    if (!pam_handle) {
        NSDebugLLog(@"gwcomp", @"[PAM] closeSession: pam_handle is NULL");
        return;
    }
    int result = pam_close_session(pam_handle, 0);
    NSDebugLLog(@"gwcomp", @"[PAM] pam_close_session result: %d (%s)", result, pam_strerror(pam_handle, result));
    if (result != PAM_SUCCESS) {
        NSDebugLLog(@"gwcomp", @"[PAM] pam_close_session failed: %s", pam_strerror(pam_handle, result));
    }
    result = pam_setcred(pam_handle, PAM_DELETE_CRED);
    NSDebugLLog(@"gwcomp", @"[PAM] pam_setcred (delete) result: %d (%s)", result, pam_strerror(pam_handle, result));
    if (result != PAM_SUCCESS) {
        NSDebugLLog(@"gwcomp", @"[PAM] pam_setcred (delete) failed: %s", pam_strerror(pam_handle, result));
    }
    pam_end(pam_handle, PAM_SUCCESS);
    pam_handle = NULL;
    NSDebugLLog(@"gwcomp", @"[PAM] PAM transaction ended");
}

- (void)clearCredentials
{
    [_storedUsername release];
    _storedUsername = nil;
    [_storedPassword release];
    _storedPassword = nil;
}

- (char **)getEnvironmentList
{
    NSDebugLLog(@"gwcomp", @"[PAM] getEnvironmentList called");
    if (!pam_handle) {
        NSDebugLLog(@"gwcomp", @"[PAM] getEnvironmentList: pam_handle is NULL");
        return NULL;
    }
    return pam_getenvlist(pam_handle);
}

- (BOOL)openSessionForUser:(NSString *)username
{
    NSDebugLLog(@"gwcomp", @"[PAM] openSessionForUser called for user: %@", username);
    if (authenticationInProgress) {
        NSDebugLLog(@"gwcomp", @"[PAM] Authentication already in progress");
        return NO;
    }
    authenticationInProgress = YES;
    
    [_storedUsername release];
    [_storedPassword release];
    _storedUsername = [username copy];
    _storedPassword = nil; // No password for auto-login
    
    NSDebugLLog(@"gwcomp", @"[PAM] Starting PAM session for auto-login user: %@", username);
    
    // Use standard "login" PAM service
    NSDebugLLog(@"gwcomp", @"[PAM] Calling pam_start with service='login', user='%s'", [username UTF8String]);
    int result = pam_start("login", [username UTF8String], &pam_conversation, &pam_handle);
    NSDebugLLog(@"gwcomp", @"[PAM] pam_start returned: %d", result);
    if (pam_handle != NULL) {
        NSDebugLLog(@"gwcomp", @"[PAM] pam_start error message: %s", pam_strerror(pam_handle, result));
    } else {
        NSDebugLLog(@"gwcomp", @"[PAM] pam_start failed and pam_handle is NULL");
    }
    if (result != PAM_SUCCESS) {
        const char *error = pam_handle ? pam_strerror(pam_handle, result) : "unknown error";
        NSDebugLLog(@"gwcomp", @"[PAM] pam_start FAILED for auto-login with code %d: %s (errno=%d: %s)", result, error, errno, strerror(errno));
        [_lastErrorMessage release];
        _lastErrorMessage = [[NSString stringWithFormat:@"PAM initialization failed for auto-login: %s", error] retain];
        authenticationInProgress = NO;
        return NO;
    }
    
    result = pam_set_item(pam_handle, PAM_TTY, ttyname(STDIN_FILENO));
    NSDebugLLog(@"gwcomp", @"[PAM] pam_set_item PAM_TTY result for auto-login: %d (%s)", result, pam_strerror(pam_handle, result));
    
    char hostname[256];
    if (gethostname(hostname, sizeof(hostname)) == 0) {
        pam_set_item(pam_handle, PAM_RHOST, hostname);
        NSDebugLLog(@"gwcomp", @"[PAM] pam_set_item PAM_RHOST for auto-login: %s", hostname);
    } else {
        NSDebugLLog(@"gwcomp", @"[PAM] gethostname failed for auto-login");
    }
    
    // For auto-login, skip authentication but still do account management
    NSDebugLLog(@"gwcomp", @"[PAM] Skipping authentication for auto-login, proceeding to account management");
    
    result = pam_acct_mgmt(pam_handle, PAM_SILENT);
    NSDebugLLog(@"gwcomp", @"[PAM] pam_acct_mgmt result for auto-login: %d (%s)", result, pam_strerror(pam_handle, result));
    if (result != PAM_SUCCESS) {
        const char *error = pam_strerror(pam_handle, result);
        NSDebugLLog(@"gwcomp", @"[PAM] pam_acct_mgmt failed for auto-login: %s", error);
        [_lastErrorMessage release];
        _lastErrorMessage = [[NSString stringWithFormat:@"Account management failed for auto-login: %s", error] retain];
        pam_end(pam_handle, result);
        pam_handle = NULL;
        authenticationInProgress = NO;
        return NO;
    }
    
    // Open the session directly
    result = pam_setcred(pam_handle, PAM_ESTABLISH_CRED);
    NSDebugLLog(@"gwcomp", @"[PAM] pam_setcred result for auto-login: %d (%s)", result, pam_strerror(pam_handle, result));
    if (result != PAM_SUCCESS) {
        const char *error = pam_strerror(pam_handle, result);
        NSDebugLLog(@"gwcomp", @"[PAM] pam_setcred failed for auto-login: %s", error);
        [_lastErrorMessage release];
        _lastErrorMessage = [[NSString stringWithFormat:@"Failed to establish credentials for auto-login: %s", error] retain];
        pam_end(pam_handle, result);
        pam_handle = NULL;
        authenticationInProgress = NO;
        return NO;
    }
    
    result = pam_open_session(pam_handle, 0);
    NSDebugLLog(@"gwcomp", @"[PAM] pam_open_session result for auto-login: %d (%s)", result, pam_strerror(pam_handle, result));
    if (result != PAM_SUCCESS) {
        const char *error = pam_strerror(pam_handle, result);
        NSDebugLLog(@"gwcomp", @"[PAM] pam_open_session failed for auto-login: %s", error);
        [_lastErrorMessage release];
        _lastErrorMessage = [[NSString stringWithFormat:@"Failed to open session for auto-login: %s", error] retain];
        pam_setcred(pam_handle, PAM_DELETE_CRED);
        pam_end(pam_handle, result);
        pam_handle = NULL;
        authenticationInProgress = NO;
        return NO;
    }
    
    authenticationInProgress = NO;
    NSDebugLLog(@"gwcomp", @"[PAM] Auto-login session opened successfully for user: %@", username);
    return YES;
}

- (NSString *)getLastError
{
    if (_lastErrorMessage) {
        return [[_lastErrorMessage copy] autorelease];
    }
    return @"Unknown PAM error";
}

@end
