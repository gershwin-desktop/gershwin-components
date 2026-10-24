/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "TDTask.h"

@implementation TDTask

@synthesize title = _title;
@synthesize done = _done;
@synthesize important = _important;
@synthesize dueDate = _dueDate;
@synthesize notes = _notes;

- (instancetype)init
{
  self = [super init];
  if (self)
    {
      _title = @"";
      _subtasks = [[NSMutableArray alloc] init];
    }
  return self;
}

+ (instancetype)taskWithTitle: (NSString *)title
{
  TDTask *task = [[[self alloc] init] autorelease];
  [task setTitle: title];
  return task;
}

- (NSMutableArray *)subtasks
{
  return _subtasks;
}

- (void)dealloc
{
  [_title release];
  [_dueDate release];
  [_notes release];
  [_subtasks release];
  [super dealloc];
}

- (id)copyWithZone: (NSZone *)zone
{
  TDTask *copy = [[TDTask allocWithZone: zone] init];
  [copy setTitle: _title];
  [copy setDone: _done];
  [copy setImportant: _important];
  [copy setDueDate: _dueDate];
  [copy setNotes: _notes];
  for (TDTask *sub in _subtasks)
    {
      [[copy subtasks] addObject: [[sub copy] autorelease]];
    }
  return copy;
}

- (BOOL)isEqual: (id)other
{
  if (self == other)
    {
      return YES;
    }
  if (![other isKindOfClass: [TDTask class]])
    {
      return NO;
    }
  TDTask *o = (TDTask *)other;

  if (_done != o->_done || _important != o->_important)
    {
      return NO;
    }
  if ((_title != o->_title) && ![_title isEqual: o->_title])
    {
      return NO;
    }
  if (_dueDate != o->_dueDate && ![_dueDate isEqual: o->_dueDate])
    {
      return NO;
    }
  if (_notes != o->_notes && ![_notes isEqual: o->_notes])
    {
      return NO;
    }
  if (![_subtasks isEqual: o->_subtasks])
    {
      return NO;
    }
  return YES;
}

- (NSUInteger)hash
{
  return [_title hash] ^ (_done ? 1 : 0) ^ (_important ? 2 : 0);
}

@end
