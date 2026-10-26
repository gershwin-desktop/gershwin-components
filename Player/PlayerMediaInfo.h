/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef PlayerMediaInfo_h
#define PlayerMediaInfo_h

#import <Foundation/Foundation.h>

/**
 * The tags and the cover picture of a local media file, read with the
 * FFmpeg that also plays it, so what is shown matches what plays on every
 * platform.
 */
@interface PlayerMediaInfo : NSObject
{
    NSDictionary *_tags;
    NSData *_artwork;
}

/// nil for a file that cannot be read, and for stream URLs: probing them
/// would wait on the network.
+ (instancetype)infoForItem:(NSString *)item;

- (NSString *)title;
- (NSString *)artist;
- (NSString *)album;
- (NSString *)genre;
- (NSString *)composer;
/// The embedded cover picture (JPEG or PNG data), nil if there is none.
- (NSData *)artwork;

@end

#endif /* PlayerMediaInfo_h */
