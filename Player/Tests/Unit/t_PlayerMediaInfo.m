/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_PlayerMediaInfo.m - title, artist and album come from the file's tags,
 * read with the same FFmpeg that plays it.  Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "PlayerMediaInfo.h"
#import "TestMedia.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSDictionary *tags = @{@"INAM": @"Url Tone", @"IART": @"Uitest Band",
                         @"IPRD": @"Uitest Album", @"IGNR": @"Test Genre"};
  NSString *tagged = TestMediaWriteTaggedWAV(@"infotag", 0.5, tags);
  NSString *plain = TestMediaWriteSilentWAV(@"infoplain", 0.5);

  START_SET("tags")
    PlayerMediaInfo *info = [PlayerMediaInfo infoForItem: tagged];
    PASS_EQUAL([info title], @"Url Tone", "the title tag is read");
    PASS_EQUAL([info artist], @"Uitest Band", "the artist tag is read");
    PASS_EQUAL([info album], @"Uitest Album", "the album tag is read");
    PASS_EQUAL([info genre], @"Test Genre", "the genre tag is read");
    PASS([info artwork] == nil, "a file without a picture has no artwork");
  END_SET("tags")

  START_SET("no tags")
    PlayerMediaInfo *info = [PlayerMediaInfo infoForItem: plain];
    PASS(info != nil, "a file without tags still has info");
    PASS([info title] == nil && [info artist] == nil, "but no title or artist");
    PASS([PlayerMediaInfo infoForItem: @"/nonexistent/x.mp3"] == nil,
         "a missing file has none");
    PASS([PlayerMediaInfo infoForItem: @"http://radio.example/live"] == nil,
         "streams are not probed (that would block on the network)");
  END_SET("no tags")

  [[NSFileManager defaultManager] removeItemAtPath: tagged error: NULL];
  [[NSFileManager defaultManager] removeItemAtPath: plain error: NULL];
  [arp release];
  return 0;
}
