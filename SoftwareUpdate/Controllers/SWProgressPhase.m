/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWProgressPhase.h"

@implementation SWProgressItem
@end

@implementation SWProgressPhase

- (instancetype)init
{
  self = [super init];
  if (self) {
    _items = [NSMutableArray array];
  }
  return self;
}

@end
