/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "TDPreferences.h"

static NSString * const TDGistIdDefaultsKey = @"GistId";
static NSString * const TDTokenDefaultsKey = @"GitHubPersonalAccessToken";

@implementation TDPreferences

+ (NSString *)gistId
{
  return [[NSUserDefaults standardUserDefaults] stringForKey: TDGistIdDefaultsKey];
}

+ (void)setGistId: (NSString *)gistId
{
  NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];

  [defs setObject: gistId forKey: TDGistIdDefaultsKey];
  [defs synchronize];
}

+ (NSString *)token
{
  return [[NSUserDefaults standardUserDefaults] stringForKey: TDTokenDefaultsKey];
}

+ (void)setToken: (NSString *)token
{
  NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];

  [defs setObject: token forKey: TDTokenDefaultsKey];
  [defs synchronize];
}

@end
