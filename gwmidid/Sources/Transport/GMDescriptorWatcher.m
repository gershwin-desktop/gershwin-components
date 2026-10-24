/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "GMDescriptorWatcher.h"

@interface GMDescriptorWatcher () <RunLoopEvents>
@end

@implementation GMDescriptorWatcher
{
  int _fd;
  void (^_handler)(void);
  NSRunLoop *_runLoop;
}

- (instancetype) initWithDescriptor: (int)fd handler: (void (^)(void))handler
{
  if ((self = [super init]) != nil)
    {
      _fd = fd;
      _handler = [handler copy];
      _runLoop = [NSRunLoop currentRunLoop];
      [_runLoop addEvent: (void *)(intptr_t)fd
                    type: ET_RDESC
                 watcher: self
                 forMode: NSDefaultRunLoopMode];
    }
  return self;
}

- (void) invalidate
{
  if (_fd < 0) return;
  [_runLoop removeEvent: (void *)(intptr_t)_fd
                   type: ET_RDESC
                forMode: NSDefaultRunLoopMode
                    all: YES];
  _fd = -1;
  _handler = nil;
}

- (void) dealloc
{
  /* The run loop does not retain its watchers. */
  [self invalidate];
}

- (void) receivedEvent: (void *)data
                  type: (RunLoopEventType)type
                 extra: (void *)extra
               forMode: (NSString *)mode
{
  void (^h)(void) = _handler;
  if (h != nil) h();
}

@end
