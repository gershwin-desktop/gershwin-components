/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PlayerAsync.h"

@interface PlayerBlockRunner : NSObject
{
    PlayerBlock _block;
}
- (instancetype)initWithBlock:(PlayerBlock)block;
- (void)run;
- (void)runAfter:(NSNumber *)delay;
@end

@implementation PlayerBlockRunner

- (instancetype)initWithBlock:(PlayerBlock)block
{
    self = [super init];
    if (self) {
        _block = [block copy];
    }
    return self;
}

- (void)dealloc
{
    [_block release];
    [super dealloc];
}

- (void)run
{
    @autoreleasepool {
        _block();
    }
}

- (void)runAfter:(NSNumber *)delay
{
    [self performSelector:@selector(run) withObject:nil afterDelay:[delay doubleValue]];
}

@end

NSArray *PlayerRunLoopModes(void)
{
    return @[NSDefaultRunLoopMode, @"NSModalPanelRunLoopMode", @"NSEventTrackingRunLoopMode"];
}

void PlayerRunInBackground(PlayerBlock block)
{
    PlayerBlockRunner *runner = [[[PlayerBlockRunner alloc] initWithBlock:block] autorelease];
    [NSThread detachNewThreadSelector:@selector(run) toTarget:runner withObject:nil];
}

void PlayerRunOnMainThread(PlayerBlock block)
{
    PlayerBlockRunner *runner = [[[PlayerBlockRunner alloc] initWithBlock:block] autorelease];
    [runner performSelectorOnMainThread:@selector(run)
                             withObject:nil
                          waitUntilDone:NO
                                  modes:PlayerRunLoopModes()];
}

void PlayerRunOnMainThreadAfter(NSTimeInterval delay, PlayerBlock block)
{
    PlayerBlockRunner *runner = [[[PlayerBlockRunner alloc] initWithBlock:block] autorelease];
    // The timer must live in the main run loop, whichever thread asks
    [runner performSelectorOnMainThread:@selector(runAfter:)
                             withObject:[NSNumber numberWithDouble:delay]
                          waitUntilDone:NO
                                  modes:PlayerRunLoopModes()];
}
