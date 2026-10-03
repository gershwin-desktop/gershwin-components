/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWRepository.h"

@implementation SWRepository

@synthesize name = _name;
@synthesize url = _url;
@synthesize pin = _pin;
@synthesize restartRequired = _restartRequired;
@synthesize currentBranch = _currentBranch;
@synthesize targetBranch = _targetBranch;
@synthesize hasDevBranch = _hasDevBranch;
@synthesize commits = _commits;
@synthesize buildStatus = _buildStatus;
@synthesize dirty = _dirty;
@synthesize modifiedFileCount = _modifiedFileCount;
@synthesize unreachableReason = _unreachableReason;
@synthesize selected = _selected;
@synthesize pinAdvanced = _pinAdvanced;

- (instancetype)initWithPlistEntry:(NSDictionary *)entry
{
  self = [super init];
  if (self) {
    _name = [[entry objectForKey:@"Name"] copy];
    _url = [[entry objectForKey:@"URL"] copy];
    _pin = [[entry objectForKey:@"Pin"] copy];
    _restartRequired = [[entry objectForKey:@"RestartRequired"] boolValue];
    _buildStatus = SWBuildStatusUnknown;
    _commits = @[];
  }
  return self;
}

- (BOOL)isPinned
{
  return _pin != nil;
}

- (NSUInteger)commitCount
{
  return [_commits count];
}

- (BOOL)isReachable
{
  return _unreachableReason == nil;
}

- (BOOL)hasUpdate
{
  return [self isPinned] ? _pinAdvanced : [_commits count] > 0;
}

@end
