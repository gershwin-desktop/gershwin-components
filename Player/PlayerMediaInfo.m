/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PlayerMediaInfo.h"

#include <libavformat/avformat.h>

// Tags as FFmpeg names them, whatever the container (ID3, Vorbis comments,
// MP4 atoms, RIFF INFO)
static void addTags(AVDictionary *metadata, NSMutableDictionary *tags)
{
    AVDictionaryEntry *entry = NULL;
    while ((entry = av_dict_get(metadata, "", entry, AV_DICT_IGNORE_SUFFIX)) != NULL) {
        NSString *key = [[NSString stringWithUTF8String:entry->key] lowercaseString];
        NSString *value = [NSString stringWithUTF8String:entry->value];
        // The container's tags win over those of a single stream
        if (key && [value length] > 0 && ![tags objectForKey:key]) {
            [tags setObject:value forKey:key];
        }
    }
}

@implementation PlayerMediaInfo

+ (instancetype)infoForItem:(NSString *)item
{
    if ([item rangeOfString:@"://"].location != NSNotFound && ![item hasPrefix:@"file://"]) {
        return nil;
    }
    AVFormatContext *ctx = NULL;
    if (avformat_open_input(&ctx, [item fileSystemRepresentation], NULL, NULL) < 0) {
        return nil;
    }

    NSMutableDictionary *tags = [NSMutableDictionary dictionary];
    NSData *artwork = nil;
    addTags(ctx->metadata, tags);
    unsigned int i;
    for (i = 0; i < ctx->nb_streams; i++) {
        AVStream *stream = ctx->streams[i];
        // Ogg and Opus keep their tags on the audio stream
        addTags(stream->metadata, tags);
        if ((stream->disposition & AV_DISPOSITION_ATTACHED_PIC)
            && artwork == nil && stream->attached_pic.size > 0) {
            artwork = [NSData dataWithBytes:stream->attached_pic.data
                                     length:stream->attached_pic.size];
        }
    }
    avformat_close_input(&ctx);

    PlayerMediaInfo *info = [[[self alloc] init] autorelease];
    info->_tags = [tags copy];
    info->_artwork = [artwork retain];
    return info;
}

- (void)dealloc
{
    [_tags release];
    [_artwork release];
    [super dealloc];
}

- (NSString *)title { return [_tags objectForKey:@"title"]; }
- (NSString *)artist { return [_tags objectForKey:@"artist"] ?: [_tags objectForKey:@"album_artist"]; }
- (NSString *)album { return [_tags objectForKey:@"album"]; }
- (NSString *)genre { return [_tags objectForKey:@"genre"]; }
- (NSString *)composer { return [_tags objectForKey:@"composer"]; }
- (NSData *)artwork { return _artwork; }

@end
