/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DKList.h"
#import "DKTask.h"

@implementation DKList

@synthesize name = _name;

- (instancetype)init
{
  self = [super init];
  if (self)
    {
      _name = @"";
      _tasks = [[NSMutableArray alloc] init];
    }
  return self;
}

+ (instancetype)listWithName: (NSString *)name
{
  DKList *list = [[[self alloc] init] autorelease];
  [list setName: name];
  return list;
}

- (NSMutableArray *)tasks
{
  return _tasks;
}

- (NSString *)gistFilename
{
  /* Gist filenames are a flat namespace; fold path separators out of the
   * list name so a list can never escape into another gist file. */
  NSString *safe = [_name stringByReplacingOccurrencesOfString: @"/" withString: @"-"];
  return [safe stringByAppendingPathExtension: @"md"];
}

- (void)dealloc
{
  [_name release];
  [_tasks release];
  [super dealloc];
}

- (id)copyWithZone: (NSZone *)zone
{
  DKList *copy = [[DKList allocWithZone: zone] init];
  [copy setName: _name];
  for (DKTask *task in _tasks)
    {
      [[copy tasks] addObject: [[task copy] autorelease]];
    }
  return copy;
}

- (BOOL)isEqual: (id)other
{
  if (self == other)
    {
      return YES;
    }
  if (![other isKindOfClass: [DKList class]])
    {
      return NO;
    }
  DKList *o = (DKList *)other;
  if (![_name isEqual: o->_name])
    {
      return NO;
    }
  return [_tasks isEqual: o->_tasks];
}

- (NSUInteger)hash
{
  return [_name hash];
}

@end
