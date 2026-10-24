/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/*
 * Where Todo keeps the two pieces of account state it needs: which gist
 * holds the lists, and the personal access token used to talk to it.
 *
 * The token lives in NSUserDefaults for now, in plain text - there is no
 * secure secret store on Gershwin yet. Keychain.app is being written in
 * parallel; once it ships, this is the class to point at it instead (the
 * rest of Todo only ever calls +token/+setToken:, so the storage can
 * change without touching TDStore or TDGistClient).
 */
@interface TDPreferences : NSObject

+ (NSString *)gistId;
+ (void)setGistId: (NSString *)gistId;

+ (NSString *)token;
+ (void)setToken: (NSString *)token;

@end
