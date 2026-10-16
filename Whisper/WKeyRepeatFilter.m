/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WKeyRepeatFilter.h"

@implementation WKeyRepeatFilter

- (id)init
{
    if ((self = [super init])) {
        held = [[NSMutableIndexSet alloc] init];
        lastUp = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [held release];
    [lastUp release];
    [super dealloc];
}

- (BOOL)noteKeyDown:(unsigned short)keyCode at:(NSTimeInterval)time
{
    if ([held containsIndex:keyCode])
        return YES;
    [held addIndex:keyCode];
    NSNumber *up = [lastUp objectForKey:[NSNumber numberWithUnsignedShort:keyCode]];
    return up != nil && [up doubleValue] == time;
}

- (void)noteKeyUp:(unsigned short)keyCode at:(NSTimeInterval)time
{
    [held removeIndex:keyCode];
    [lastUp setObject:[NSNumber numberWithDouble:time]
               forKey:[NSNumber numberWithUnsignedShort:keyCode]];
}

- (void)reset
{
    [held removeAllIndexes];
    [lastUp removeAllObjects];
}

@end
