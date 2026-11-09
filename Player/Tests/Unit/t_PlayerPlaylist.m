/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_PlayerPlaylist.m - which track comes next, before, and after a track
 * ends, with and without repeat and shuffle.  Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../../PlayerPlaylist.m"

static PlayerPlaylist *playlistWith(NSUInteger n)
{
  PlayerPlaylist *p = [[[PlayerPlaylist alloc] init] autorelease];
  NSUInteger i;
  for (i = 0; i < n; i++)
    {
      [p addItem: [NSString stringWithFormat: @"/music/%lu.mp3", (unsigned long)i]];
    }
  return p;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("empty playlist")
    PlayerPlaylist *p = playlistWith(0);
    PASS([p count] == 0, "starts empty");
    PASS([p currentIndex] == NSNotFound, "has no current item");
    PASS([p currentItem] == nil, "current item is nil");
    PASS([p indexAfterCurrent] == NSNotFound, "nothing comes next");
    PASS([p indexBeforeCurrent] == NSNotFound, "nothing comes before");
  END_SET("empty playlist")

  START_SET("adding items")
    PlayerPlaylist *p = playlistWith(0);
    PASS([p addItem: @"/music/a.mp3"] == 0, "first item gets index 0");
    PASS([p addItem: @"/music/b.mp3"] == 1, "second item gets index 1");
    PASS([p addItem: @"/music/./a.mp3"] == 0,
         "the same file again is not added twice, its index is returned");
    PASS([p count] == 2, "duplicates are not added");
    PASS([p currentIndex] == NSNotFound, "adding does not pick a current item");
    PASS([p addItem: @"http://example.com/live"] == 2, "URLs can be added");
    PASS_EQUAL([p itemAtIndex: 2], @"http://example.com/live",
               "URLs are kept verbatim");
    [p setCurrentIndex: 1];
    PASS_EQUAL([p currentItem], @"/music/b.mp3", "current item follows the index");
    [p removeAllItems];
    PASS([p count] == 0 && [p currentIndex] == NSNotFound,
         "removing all items also clears the current item");
  END_SET("adding items")

  START_SET("in order without repeat")
    PlayerPlaylist *p = playlistWith(3);
    PASS([p indexAfterCurrent] == 0, "with no current item the first comes next");
    [p setCurrentIndex: 0];
    PASS([p indexAfterCurrent] == 1, "after the first comes the second");
    PASS([p indexBeforeCurrent] == NSNotFound, "nothing before the first");
    [p setCurrentIndex: 2];
    PASS([p indexAfterCurrent] == NSNotFound, "nothing after the last");
    PASS([p indexBeforeCurrent] == 1, "before the last comes the middle one");
  END_SET("in order without repeat")

  START_SET("in order with repeat")
    PlayerPlaylist *p = playlistWith(3);
    [p setRepeat: YES];
    [p setCurrentIndex: 2];
    PASS([p indexAfterCurrent] == 0, "after the last the first comes again");
    [p setCurrentIndex: 0];
    PASS([p indexBeforeCurrent] == 2, "before the first comes the last");
    PlayerPlaylist *one = playlistWith(1);
    [one setRepeat: YES];
    [one setCurrentIndex: 0];
    PASS([one indexAfterCurrent] == 0, "a single track repeats itself");
  END_SET("in order with repeat")

  START_SET("shuffle plays every track once")
    PlayerPlaylist *p = playlistWith(10);
    [p setCurrentIndex: 4];
    [p setShuffle: YES];
    NSMutableIndexSet *seen = [NSMutableIndexSet indexSetWithIndex: 4];
    NSMutableArray *visited = [NSMutableArray arrayWithObject: @4];
    NSUInteger next;
    while ((next = [p indexAfterCurrent]) != NSNotFound && [visited count] < 20)
      {
        [seen addIndex: next];
        [visited addObject: [NSNumber numberWithUnsignedInteger: next]];
        [p setCurrentIndex: next];
      }
    PASS([visited count] == 10, "the shuffled run has as many steps as tracks");
    PASS([seen count] == 10, "every track is visited exactly once");
    NSUInteger last = [[visited lastObject] unsignedIntegerValue];
    NSUInteger beforeLast = [[visited objectAtIndex: 8] unsignedIntegerValue];
    PASS([p indexBeforeCurrent] == beforeLast,
         "previous goes back along the shuffled order (%lu)", (unsigned long)last);
    [p setRepeat: YES];
    PASS([p indexAfterCurrent] != NSNotFound, "with repeat the shuffle starts over");
  END_SET("shuffle plays every track once")

  START_SET("shuffle off restores the album order")
    PlayerPlaylist *p = playlistWith(5);
    [p setCurrentIndex: 2];
    [p setShuffle: YES];
    [p setShuffle: NO];
    PASS([p indexAfterCurrent] == 3, "next is the following track again");
    PASS([p indexBeforeCurrent] == 1, "previous is the preceding track again");
  END_SET("shuffle off restores the album order")

  START_SET("items added while shuffling are played too")
    PlayerPlaylist *p = playlistWith(3);
    [p setCurrentIndex: 0];
    [p setShuffle: YES];
    [p addItem: @"/music/new.mp3"];
    NSMutableIndexSet *seen = [NSMutableIndexSet indexSetWithIndex: 0];
    NSUInteger next, steps = 0;
    while ((next = [p indexAfterCurrent]) != NSNotFound && steps++ < 10)
      {
        [seen addIndex: next];
        [p setCurrentIndex: next];
      }
    PASS([seen count] == 4, "the added track is part of the shuffled run");
  END_SET("items added while shuffling are played too")

  START_SET("picking a track while shuffling")
    PlayerPlaylist *p = playlistWith(6);
    [p setCurrentIndex: 0];
    [p setShuffle: YES];
    NSMutableIndexSet *seen = [NSMutableIndexSet indexSetWithIndex: 0];
    NSUInteger second = [p indexAfterCurrent];
    [p setCurrentIndex: second];
    [seen addIndex: second];
    /* pick the track that would come last */
    NSUInteger picked = NSNotFound, probe;
    PlayerPlaylist *copy = p;
    for (probe = 0; probe < 6; probe++)
      if (![seen containsIndex: probe]) picked = probe;
    [copy setCurrentIndex: picked];
    [seen addIndex: picked];
    PASS([p indexBeforeCurrent] == second,
         "previous returns to the track played before the pick");
    NSUInteger next, steps = 0;
    while ((next = [p indexAfterCurrent]) != NSNotFound && steps++ < 10)
      {
        PASS(![seen containsIndex: next], "no track plays twice (%lu)", (unsigned long)next);
        [seen addIndex: next];
        [p setCurrentIndex: next];
      }
    PASS([seen count] == 6, "the tracks not played yet still all come");
    [p setRepeat: YES];
    NSUInteger first = [p indexAfterCurrent];
    [p setCurrentIndex: first];
    PASS([p indexAfterCurrent] != first, "repeat continues the run after wrapping");
  END_SET("picking a track while shuffling")

  [arp release];
  return 0;
}
