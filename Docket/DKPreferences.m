/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DKPreferences.h"

static NSString * const DKGistIdDefaultsKey = @"GistId";
static NSString * const DKTokenDefaultsKey = @"GitHubPersonalAccessToken";

@implementation DKPreferences

+ (NSString *)gistId
{
  return [[NSUserDefaults standardUserDefaults] stringForKey: DKGistIdDefaultsKey];
}

+ (void)setGistId: (NSString *)gistId
{
  NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];

  [defs setObject: gistId forKey: DKGistIdDefaultsKey];
  [defs synchronize];
}

+ (NSString *)token
{
  return [[NSUserDefaults standardUserDefaults] stringForKey: DKTokenDefaultsKey];
}

+ (void)setToken: (NSString *)token
{
  NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];

  [defs setObject: token forKey: DKTokenDefaultsKey];
  [defs synchronize];
}

@end
