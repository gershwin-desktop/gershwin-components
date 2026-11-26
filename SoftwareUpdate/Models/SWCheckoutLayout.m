/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWCheckoutLayout.h"

NSString *const SWDeveloperRepositoryName = @"gershwin-developer";

static NSString *const kOSSupportRelativePath = @"Library/OSSupport";

@implementation SWCheckoutLayout

@synthesize developerDirectory = _developerDirectory;
@synthesize sourcesDirectory = _sourcesDirectory;

+ (instancetype)systemLayout
{
  return [[self alloc] initWithDeveloperDirectory:@"/Developer"
                                 sourcesDirectory:@"/Developer/Library/Sources"];
}

- (instancetype)initWithDeveloperDirectory:(NSString *)developerDirectory
                          sourcesDirectory:(NSString *)sourcesDirectory
{
  self = [super init];
  if (self) {
    _developerDirectory = [developerDirectory copy];
    _sourcesDirectory = [sourcesDirectory copy];
  }
  return self;
}

- (NSString *)repositoriesCSVPath
{
  return [_developerDirectory stringByAppendingPathComponent:@"Library/Repositories.csv"];
}

- (NSString *)scriptsDirectory
{
  return [_developerDirectory stringByAppendingPathComponent:@"Library/Scripts"];
}

- (NSString *)installScriptPath
{
  return [[self scriptsDirectory] stringByAppendingPathComponent:@"install-system-domain.sh"];
}

- (NSString *)patchesDirectory
{
  return [_developerDirectory stringByAppendingPathComponent:@"Library/Patches"];
}

- (NSString *)osSupportDirectory
{
  return [_developerDirectory stringByAppendingPathComponent:kOSSupportRelativePath];
}

+ (NSString *)packageListPathForOSIdentifier:(NSString *)osIdentifier
{
  return [kOSSupportRelativePath stringByAppendingPathComponent:
    [osIdentifier stringByAppendingPathExtension:@"txt"]];
}

- (NSString *)pathForRepositoryNamed:(NSString *)name
{
  if ([name isEqualToString:SWDeveloperRepositoryName]) return _developerDirectory;
  return [_sourcesDirectory stringByAppendingPathComponent:name];
}

@end
