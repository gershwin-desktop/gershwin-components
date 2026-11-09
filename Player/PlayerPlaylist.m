/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PlayerPlaylist.h"
#include <stdlib.h>

@implementation PlayerPlaylist

@synthesize repeat = _repeat;
@synthesize currentIndex = _currentIndex;

- (instancetype)init
{
    self = [super init];
    if (self) {
        _items = [[NSMutableArray alloc] init];
        _order = [[NSMutableArray alloc] init];
        _currentIndex = NSNotFound;
        _position = NSNotFound;
    }
    return self;
}

- (void)dealloc
{
    [_items release];
    [_order release];
    [super dealloc];
}

- (NSUInteger)count
{
    return [_items count];
}

- (NSArray *)items
{
    return [NSArray arrayWithArray:_items];
}

- (NSString *)itemAtIndex:(NSUInteger)index
{
    return (index < [_items count]) ? [_items objectAtIndex:index] : nil;
}

- (NSString *)currentItem
{
    return [self itemAtIndex:_currentIndex];
}

- (NSUInteger)addItem:(NSString *)item
{
    // Paths are compared in their standard form so "/a/./b" and "/a/b" are
    // one track; URLs must stay untouched.
    if ([item rangeOfString:@"://"].location == NSNotFound) {
        item = [item stringByStandardizingPath];
    }
    NSUInteger existing = [_items indexOfObject:item];
    if (existing != NSNotFound) {
        return existing;
    }

    NSUInteger index = [_items count];
    [_items addObject:item];
    NSNumber *n = [NSNumber numberWithUnsignedInteger:index];
    if (_shuffle && _position != NSNotFound) {
        // Somewhere among the tracks not played yet, so it still comes once
        NSUInteger upcoming = [_order count] - _position;
        [_order insertObject:n atIndex:_position + 1 + (NSUInteger)(random() % upcoming)];
    } else {
        [_order addObject:n];
    }
    return index;
}

- (void)removeAllItems
{
    [_items removeAllObjects];
    [_order removeAllObjects];
    _currentIndex = NSNotFound;
    _position = NSNotFound;
}

- (void)setCurrentIndex:(NSUInteger)index
{
    if (index >= [_items count]) {
        _currentIndex = NSNotFound;
        _position = NSNotFound;
        return;
    }

    NSNumber *n = [NSNumber numberWithUnsignedInteger:index];
    NSUInteger pos = [_order indexOfObject:n];
    if (_shuffle && _position != NSNotFound && ![self isNeighbourPosition:pos]) {
        // A track picked by hand while shuffling plays now; the tracks that
        // were still to come keep their turn after it.
        [_order removeObjectAtIndex:pos];
        if (pos < _position) {
            _position--;
        }
        pos = _position + 1;
        [_order insertObject:n atIndex:pos];
    }
    _currentIndex = index;
    _position = pos;
}

// Next and previous (including the wrap-around of repeat) move along the
// order; anything else is a jump.
- (BOOL)isNeighbourPosition:(NSUInteger)pos
{
    NSUInteger last = [_order count] - 1;
    return pos == _position || pos == _position + 1 || pos + 1 == _position
        || (_position == last && pos == 0) || (_position == 0 && pos == last);
}

- (BOOL)shuffle
{
    return _shuffle;
}

- (void)setShuffle:(BOOL)shuffle
{
    if (shuffle == _shuffle) {
        return;
    }
    _shuffle = shuffle;

    NSUInteger count = [_items count];
    [_order removeAllObjects];
    NSUInteger i;
    for (i = 0; i < count; i++) {
        [_order addObject:[NSNumber numberWithUnsignedInteger:i]];
    }
    if (shuffle) {
        [self shuffleOrderKeepingCurrentFirst];
    }
    _position = (_currentIndex == NSNotFound) ? NSNotFound
        : [_order indexOfObject:[NSNumber numberWithUnsignedInteger:_currentIndex]];
}

- (void)shuffleOrderKeepingCurrentFirst
{
    NSUInteger count = [_order count];
    NSUInteger i;
    // Fisher-Yates
    for (i = count; i > 1; i--) {
        NSUInteger j = (NSUInteger)(random() % i);
        [_order exchangeObjectAtIndex:i - 1 withObjectAtIndex:j];
    }
    // The track that plays now opens the shuffled run, so every other one
    // is still ahead of it.
    if (_currentIndex != NSNotFound) {
        NSNumber *cur = [NSNumber numberWithUnsignedInteger:_currentIndex];
        [_order removeObject:cur];
        [_order insertObject:cur atIndex:0];
    }
}

- (NSUInteger)indexAfterCurrent
{
    NSUInteger count = [_order count];
    if (count == 0) {
        return NSNotFound;
    }
    if (_position == NSNotFound) {
        return [[_order objectAtIndex:0] unsignedIntegerValue];
    }
    if (_position + 1 < count) {
        return [[_order objectAtIndex:_position + 1] unsignedIntegerValue];
    }
    return _repeat ? [[_order objectAtIndex:0] unsignedIntegerValue] : NSNotFound;
}

- (NSUInteger)indexBeforeCurrent
{
    NSUInteger count = [_order count];
    if (count == 0 || _position == NSNotFound) {
        return NSNotFound;
    }
    if (_position > 0) {
        return [[_order objectAtIndex:_position - 1] unsignedIntegerValue];
    }
    return _repeat ? [[_order lastObject] unsignedIntegerValue] : NSNotFound;
}

@end
