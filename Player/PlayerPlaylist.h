/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef PlayerPlaylist_h
#define PlayerPlaylist_h

#import <Foundation/Foundation.h>

/**
 * The ordered list of files and URLs Player plays, and the rules for which
 * one comes next.  Knows nothing about playback, so the order rules can be
 * tested on their own.
 *
 * With shuffle on, the tracks are played in a random order in which every
 * track comes exactly once; previous goes back along that order.
 */
@interface PlayerPlaylist : NSObject
{
    NSMutableArray *_items;
    NSMutableArray *_order;       // playing order, as NSNumber indices into _items
    NSUInteger _position;         // position of the current item in _order
    NSUInteger _currentIndex;
    BOOL _repeat;
    BOOL _shuffle;
}

@property (nonatomic, assign) BOOL repeat;
@property (nonatomic, assign) BOOL shuffle;
/// Index of the item that is loaded, NSNotFound if none.
@property (nonatomic, assign) NSUInteger currentIndex;

- (NSUInteger)count;
- (NSArray *)items;
- (NSString *)itemAtIndex:(NSUInteger)index;
- (NSString *)currentItem;

/// Adds the item unless it is already there; returns its index either way.
- (NSUInteger)addItem:(NSString *)item;
- (void)removeAllItems;

/// The index to play for "Next" and when a track ends, NSNotFound at the end.
- (NSUInteger)indexAfterCurrent;
/// The index to play for "Previous", NSNotFound at the start.
- (NSUInteger)indexBeforeCurrent;

@end

#endif /* PlayerPlaylist_h */
