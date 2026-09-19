/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "RadioManager.h"
#import "PlayerAsync.h"
#import "RadioStation.h"
#import "RadioBrowser.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>

static const int kMaxCacheEntries = 200;
static const int kMaxDownloadRetries = 3;

@implementation RadioManager

@synthesize delegate = _delegate;
@synthesize volume = _volume;
@synthesize muted = _muted;
@synthesize stations = _stations;
@synthesize currentStationName = _currentStationName;
@synthesize currentStreamURL = _currentStreamURL;

+ (instancetype)sharedManager
{
    static RadioManager *shared = nil;
    @synchronized(self) {
        if (shared == nil) {
            shared = [[self alloc] init];
        }
    }
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _player = [[StreamPlayer sharedPlayer] retain];
        [_player setDelegate:self];
        _stations = [[NSArray alloc] init];
        _stationImages = [[NSMutableDictionary alloc] init];
        _iconIndex = [[NSMutableDictionary alloc] init];
        _downloadingKeys = [[NSMutableSet alloc] init];
        _maxCacheEntries = kMaxCacheEntries;
        // At most three icon downloads at a time
        _iconQueue = [[NSOperationQueue alloc] init];
        [_iconQueue setMaxConcurrentOperationCount:3];
        _volume = 1.0f;
        _muted = NO;

        // Setup on-disk icon cache directory
        NSString *base = [@"~/Library/Caches/Player/RadioIcons" stringByExpandingTildeInPath];
        _iconCachePath = [base retain];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:_iconCachePath]) {
            [fm createDirectoryAtPath:_iconCachePath
          withIntermediateDirectories:YES
                           attributes:nil
                                error:NULL];
        }

        [self loadIconIndex];
        [self pruneCacheIfNeeded];
    }
    return self;
}

- (void)dealloc
{
    [_player setDelegate:nil];
    [_player release];
    [_stations release];
    [_stationImages release];
    [_iconIndex release];
    [_downloadingKeys release];
    [_iconCachePath release];
    [_currentStationName release];
    [_currentStreamURL release];
    [_iconQueue cancelAllOperations];
    [_iconQueue release];
    [super dealloc];
}

#pragma mark - Properties

- (BOOL)isPlaying
{
    return [_player isPlaying];
}

- (void)setVolume:(float)volume
{
    _volume = volume;
    [_player setVolume:volume];
}

- (void)setMuted:(BOOL)muted
{
    _muted = muted;
    [_player setMuted:muted];
}

#pragma mark - Public API

- (void)loadLocalStations
{
    NSLog(@"[RadioManager] loadLocalStations called, delegate=%@", _delegate);
    if (_delegate != nil && [_delegate respondsToSelector:@selector(radioManagerDidUpdateStatus:status:)]) {
        [_delegate radioManagerDidUpdateStatus:self status:@"Loading stations..."];
    }

    [[RadioBrowser sharedBrowser] localStationsWithCompletion:
     ^(NSArray *stations, NSError *error) {
        if (stations) {
            [self->_stations release];
            self->_stations = [[self limitStations:stations] retain];
            [self->_stationImages removeAllObjects];

            // Notify delegate FIRST so the UI updates before any downloads
            if (self->_delegate != nil &&
                [self->_delegate respondsToSelector:@selector(radioManagerDidUpdateStations:)]) {
                [self->_delegate radioManagerDidUpdateStations:self];
            }
            if (self->_delegate != nil &&
                [self->_delegate respondsToSelector:@selector(radioManagerDidUpdateStatus:status:)]) {
                [self->_delegate radioManagerDidUpdateStatus:self status:
                    [NSString stringWithFormat:@"%tu stations loaded", [self->_stations count]]];
            }

            // Start prefetching icons for the first few stations
            NSUInteger prefetchCount = MIN(8, [self->_stations count]);
            for (NSUInteger i = 0; i < prefetchCount; i++) {
                [self prefetchIconForStationAtIndex:i];
            }
        } else {
            NSString *errMsg = error ? [error localizedDescription] : @"Unknown error";
            if (self->_delegate != nil &&
                [self->_delegate respondsToSelector:@selector(radioManager:didFailWithError:)]) {
                [self->_delegate radioManager:self didFailWithError:errMsg];
            }
        }
    }];
}

- (void)searchStations:(NSString *)query
{
    if ([query length] == 0) {
        [self loadLocalStations];
        return;
    }

    if (_delegate != nil && [_delegate respondsToSelector:@selector(radioManagerDidUpdateStatus:status:)]) {
        [_delegate radioManagerDidUpdateStatus:self status:[NSString stringWithFormat:@"Searching: %@", query]];
    }

    [[RadioBrowser sharedBrowser] searchStations:query
                                      completion:^(NSArray *stations, NSError *error) {
        if (stations) {
            [self->_stations release];
            self->_stations = [[self limitStations:stations] retain];
            [self->_stationImages removeAllObjects];

            // Notify delegate FIRST so the UI updates before any downloads
            if (self->_delegate != nil &&
                [self->_delegate respondsToSelector:@selector(radioManagerDidUpdateStations:)]) {
                [self->_delegate radioManagerDidUpdateStations:self];
            }
            if (self->_delegate != nil &&
                [self->_delegate respondsToSelector:@selector(radioManagerDidUpdateStatus:status:)]) {
                [self->_delegate radioManagerDidUpdateStatus:self status:
                    [NSString stringWithFormat:@"Found %tu stations", [self->_stations count]]];
            }

            // Start prefetching icons for the first few stations
            NSUInteger prefetchCount = MIN(8, [self->_stations count]);
            for (NSUInteger i = 0; i < prefetchCount; i++) {
                [self prefetchIconForStationAtIndex:i];
            }
        } else {
            NSString *errMsg = error ? [error localizedDescription] : @"Search failed";
            if (self->_delegate != nil &&
                [self->_delegate respondsToSelector:@selector(radioManager:didFailWithError:)]) {
                [self->_delegate radioManager:self didFailWithError:errMsg];
            }
        }
    }];
}

- (void)playStation:(RadioStation *)station
{
    if (!station) return;

    NSString *urlString = [station streamURL];
    if (!urlString) urlString = [station tuneURL];
    if (!urlString || [urlString length] == 0) return;

    [_currentStationName release];
    _currentStationName = [[station name] copy];
    [_currentStreamURL release];
    _currentStreamURL = [urlString copy];

    if (_delegate != nil && [_delegate respondsToSelector:@selector(radioManagerDidUpdateStatus:status:)]) {
        [_delegate radioManagerDidUpdateStatus:self status:[NSString stringWithFormat:@"Connecting to %@...", [station name]]];
    }

    // Handle tune URLs (TuneIn playlist resolution) by resolving first
    if ([urlString rangeOfString:@"Tune.ashx" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [urlString hasSuffix:@".m3u"] || [urlString hasSuffix:@".m3u8"]) {
        [self resolveStreamURL:urlString completion:^(NSString *resolved) {
            if (resolved) {
                [self->_currentStreamURL release];
                self->_currentStreamURL = [resolved copy];
                [station setStreamURL:resolved];
                [self openAndPlayURL:resolved];
            } else {
                if (self->_delegate != nil &&
                    [self->_delegate respondsToSelector:@selector(radioManager:didFailWithError:)]) {
                    [self->_delegate radioManager:self didFailWithError:@"Failed to resolve stream URL"];
                }
            }
        }];
    } else {
        [self openAndPlayURL:urlString];
    }
}

- (void)playURL:(NSString *)urlString
{
    if (!urlString || [urlString length] == 0) return;

    [_currentStationName release];
    _currentStationName = [[urlString lastPathComponent] copy];
    [_currentStreamURL release];
    _currentStreamURL = [urlString copy];

    if (_delegate != nil && [_delegate respondsToSelector:@selector(radioManagerDidUpdateStatus:status:)]) {
        [_delegate radioManagerDidUpdateStatus:self status:@"Connecting..."];
    }

    [self openAndPlayURL:urlString];
}

- (void)stop
{
    [_player stop];
    [_player close];
    [_currentStationName release];
    _currentStationName = nil;
    [_currentStreamURL release];
    _currentStreamURL = nil;

    if (_delegate != nil && [_delegate respondsToSelector:@selector(radioManagerDidStop:)]) {
        [_delegate radioManagerDidStop:self];
    }
    if (_delegate != nil && [_delegate respondsToSelector:@selector(radioManagerDidUpdateStatus:status:)]) {
        [_delegate radioManagerDidUpdateStatus:self status:@"Stopped"];
    }
}

#pragma mark - Stream URL Resolution

- (void)resolveStreamURL:(NSString *)tuneURL completion:(void(^)(NSString *resolved))completion
{
    NSURL *url = [NSURL URLWithString:tuneURL];
    if (!url) {
        if (completion) completion(nil);
        return;
    }

    PlayerRunInBackground(^{
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        [req setHTTPMethod:@"GET"];
        [req setTimeoutInterval:15.0];

        NSError *error = nil;
        NSHTTPURLResponse *response = nil;
        NSData *data = [NSURLConnection sendSynchronousRequest:req
                                             returningResponse:&response
                                                         error:&error];

        if (error || !data || [data length] == 0) {
            PlayerRunOnMainThread(^{
                if (completion) completion(nil);
            });
            return;
        }

        // Try to parse as text (m3u, plain URL)
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (text) {
            __block NSString *found = nil;
            [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
                NSString *trim = [line stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if ([trim hasPrefix:@"#"]) return;
                if ([trim hasPrefix:@"http://"] || [trim hasPrefix:@"https://"]) {
                    // Owned: the line is gone with the enumeration's pool
                    found = [trim copy];
                    *stop = YES;
                }
            }];
            [text release];

            if (found) {
                PlayerRunOnMainThread(^{
                    if (completion) completion(found);
                    [found release];
                });
                return;
            }
        }

        // Check if response URL contains the final location
        if (response && [response URL]) {
            NSString *finalURL = [[response URL] absoluteString];
            if (![finalURL isEqualToString:tuneURL]) {
                PlayerRunOnMainThread(^{
                    if (completion) completion(finalURL);
                });
                return;
            }
        }

        PlayerRunOnMainThread(^{
            if (completion) completion(nil);
        });
    });
}

#pragma mark - Playback Internals

- (void)openAndPlayURL:(NSString *)urlString
{
    NSError *error = nil;
    BOOL success = [_player openURL:urlString error:&error];

    if (success) {
        [_player play];
    } else {
        NSString *errMsg = error ? [error localizedDescription] : @"Failed to open stream";
        if (_delegate != nil && [_delegate respondsToSelector:@selector(radioManager:didFailWithError:)]) {
            [_delegate radioManager:self didFailWithError:errMsg];
        }
        if (_delegate != nil && [_delegate respondsToSelector:@selector(radioManagerDidUpdateStatus:status:)]) {
            [_delegate radioManagerDidUpdateStatus:self status:@"Error"];
        }
    }
}

#pragma mark - StreamPlayerDelegate

- (void)streamPlayerDidStartPlaying:(StreamPlayer *)player
{
    // Find the station matching this stream URL
    RadioStation *currentStation = nil;
    for (RadioStation *s in _stations) {
        if (_currentStationName && [[s name] isEqualToString:_currentStationName]) {
            currentStation = s;
            break;
        }
    }

    if (_delegate != nil && [_delegate respondsToSelector:@selector(radioManagerDidStartPlaying:station:)]) {
        [_delegate radioManagerDidStartPlaying:self station:currentStation];
    }
    if (_delegate != nil && [_delegate respondsToSelector:@selector(radioManagerDidUpdateStatus:status:)]) {
        [_delegate radioManagerDidUpdateStatus:self status:
            _currentStationName ? [NSString stringWithFormat:@"Playing: %@", _currentStationName] : @"Playing"];
    }
}

- (void)streamPlayerDidStop:(StreamPlayer *)player
{
    // Only notify delegate if we aren't already playing a new stream
    // StreamPlayer delivers this asynchronously on the main thread, so this callback
    // can arrive after a new stream has already started playing
    if (![_player isPlaying]) {
        if (_delegate != nil && [_delegate respondsToSelector:@selector(radioManagerDidStop:)]) {
            [_delegate radioManagerDidStop:self];
        }
    }
}

- (void)streamPlayer:(StreamPlayer *)player didFailWithError:(NSError *)error
{
    if (_delegate != nil && [_delegate respondsToSelector:@selector(radioManager:didFailWithError:)]) {
        [_delegate radioManager:self didFailWithError:[error localizedDescription]];
    }
}

- (void)streamPlayer:(StreamPlayer *)player didUpdateStatus:(NSString *)status
{
    if (_delegate != nil && [_delegate respondsToSelector:@selector(radioManagerDidUpdateStatus:status:)]) {
        [_delegate radioManagerDidUpdateStatus:self status:status];
    }
}

- (void)streamPlayer:(StreamPlayer *)player didUpdateMetadata:(NSDictionary *)metadata
{
    // Forward the full metadata dictionary so the UI can display StreamTitle, icy-url, etc.
    if (_delegate != nil &&
        [_delegate respondsToSelector:@selector(radioManager:didUpdateMetadata:)]) {
        [_delegate radioManager:self didUpdateMetadata:metadata];
    }
    // Also forward just the StreamTitle for backward compatibility
    NSString *radioText = [metadata objectForKey:@"StreamTitle"];
    if ([radioText length] > 0 && _delegate != nil &&
        [_delegate respondsToSelector:@selector(radioManager:didUpdateRadioText:)]) {
        [_delegate radioManager:self didUpdateRadioText:radioText];
    }
}

#pragma mark - Icon Caching

- (NSImage *)imageForStation:(RadioStation *)station
{
    if (!station) return nil;
    NSString *key = [station stationId] ?: [station name];
    if (!key) return nil;
    NSImage *img = [_stationImages objectForKey:key];
    if (img) return img;

    // Generate a text placeholder on-the-fly so the user sees station names
    return [self textPlaceholderForStation:station];
}

- (NSImage *)textPlaceholderForStation:(RadioStation *)station
{
    NSString *name = [station name] ?: @"Radio Station";
    NSSize size = NSMakeSize(200, 200);

    NSImage *image = [[NSImage alloc] initWithSize:size];
    [image lockFocus];

    // Dark grey background
    [[NSColor colorWithCalibratedWhite:0.25 alpha:1.0] setFill];
    [NSBezierPath fillRect:NSMakeRect(0, 0, size.width, size.height)];

    // Draw a simple radio tower icon (triangle + antenna)
    [[NSColor colorWithCalibratedWhite:0.55 alpha:1.0] set];
    CGFloat cx = size.width / 2.0;
    CGFloat iconMidY = size.height * 0.58;

    // Base triangle (broadcast tower)
    NSBezierPath *base = [NSBezierPath bezierPath];
    [base moveToPoint:NSMakePoint(cx - 18, iconMidY - 12)];
    [base lineToPoint:NSMakePoint(cx + 18, iconMidY - 12)];
    [base lineToPoint:NSMakePoint(cx, iconMidY + 12)];
    [base closePath];
    [base fill];

    // Antenna mast going up from center
    [base removeAllPoints];
    [base setLineWidth:2.0];
    [base moveToPoint:NSMakePoint(cx, iconMidY + 8)];
    [base lineToPoint:NSMakePoint(cx, iconMidY + 30)];
    [base stroke];

    // Broadcast bars (simple horizontal lines radiating from top)
    [base setLineWidth:1.5];
    CGFloat tipY = iconMidY + 30;
    [base moveToPoint:NSMakePoint(cx - 8, tipY - 4)];
    [base lineToPoint:NSMakePoint(cx + 8, tipY - 4)];
    [base stroke];
    [base moveToPoint:NSMakePoint(cx - 14, tipY - 10)];
    [base lineToPoint:NSMakePoint(cx + 14, tipY - 10)];
    [base stroke];
    [base moveToPoint:NSMakePoint(cx - 20, tipY - 16)];
    [base lineToPoint:NSMakePoint(cx + 20, tipY - 16)];
    [base stroke];

    // Station name centered below the icon
    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    [para setAlignment:NSTextAlignmentCenter];
    [para setLineBreakMode:NSLineBreakByTruncatingTail];

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13.0],
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSParagraphStyleAttributeName: para
    };
    [para release];

    CGFloat textY = size.height * 0.24;
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:name
                                                             attributes:attrs];
    NSRect textRect = NSMakeRect(8, textY, size.width - 16, 44);
    [as drawInRect:textRect];
    [as release];

    // Subtext in lighter grey below the name
    NSString *sub = [station subtext];
    if ([sub length] > 0) {
        NSDictionary *subAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:10.0],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.7 alpha:1.0],
            NSParagraphStyleAttributeName: para
        };
        NSAttributedString *subAS = [[NSAttributedString alloc] initWithString:sub
                                                                    attributes:subAttrs];
        [subAS drawInRect:NSMakeRect(8, textY - 18, size.width - 16, 16)];
        [subAS release];
    }

    [image unlockFocus];
    return [image autorelease];
}

- (void)prefetchIconForStationAtIndex:(NSUInteger)index
{
    if (index >= [_stations count]) return;

    RadioStation *station = [_stations objectAtIndex:index];
    NSString *key = [station stationId] ?: [station name];
    if (!key) return;

    // Already in memory
    if ([_stationImages objectForKey:key]) return;

    // Check disk cache
    NSString *cachePath = [self cachePathForKey:key];
    if (cachePath) {
        NSData *data = [NSData dataWithContentsOfFile:cachePath];
        if (data && [data length] > 0) {
            NSImage *image = [[NSImage alloc] initWithData:data];
            if (image) {
                [_stationImages setObject:image forKey:key];
                [image release];

                // Update last access; downloads update the index concurrently
                @synchronized(self) {
                    NSMutableDictionary *entry = [[_iconIndex objectForKey:key] mutableCopy];
                    if (!entry) entry = [[NSMutableDictionary alloc] init];
                    [entry setObject:@((unsigned long long)[[NSDate date] timeIntervalSince1970])
                              forKey:@"lastAccess"];
                    [_iconIndex setObject:entry forKey:key];
                    [entry release];
                    [self saveIconIndex];
                }

                // Notify delegate
                if (_delegate != nil &&
                    [_delegate respondsToSelector:@selector(radioManager:didLoadIconAtIndex:)]) {
                    [_delegate radioManager:self didLoadIconAtIndex:index];
                }
                return;
            }
        }
    }

    // Need to download - check if already downloading
    @synchronized(_downloadingKeys) {
        if ([_downloadingKeys containsObject:key]) return;
        [_downloadingKeys addObject:key];
    }

    NSString *imageURL = [station imageURL];
    if (!imageURL || [imageURL length] == 0) return;

    [self downloadImageWithURL:imageURL key:key station:station attempt:1];
}

- (void)downloadImageWithURL:(NSString *)urlStr key:(NSString *)key
                     station:(RadioStation *)station attempt:(int)attempt
{
    if (!urlStr || [urlStr length] == 0) {
        @synchronized(_downloadingKeys) {
            [_downloadingKeys removeObject:key];
        }
        return;
    }

    if (attempt > kMaxDownloadRetries) {
        @synchronized(_downloadingKeys) {
            [_downloadingKeys removeObject:key];
        }
        return;
    }

    [_iconQueue addOperationWithBlock:^{
        @autoreleasepool {
            // Build candidate URLs - try the original first, then fallback
            NSMutableArray *candidates = [NSMutableArray array];
            [candidates addObject:urlStr];

            // If the original URL came from cdn-profiles, also try cdn-radiotime-logos
            // (different CDN may have the image in a different format)
            NSURL *u = [NSURL URLWithString:urlStr];
            if (u && [u host] &&
                [[u host] rangeOfString:@"cdn-profiles.tunein.com"].location != NSNotFound) {
                NSString *path = [u path];
                NSArray *components = [path pathComponents];
                NSString *stationId = nil;
                for (NSString *comp in components) {
                    if ([comp hasPrefix:@"s"] && [comp length] > 1) {
                        stationId = comp;
                        break;
                    }
                }
                if (stationId) {
                    NSString *alt = [NSString stringWithFormat:@"http://cdn-radiotime-logos.tunein.com/%@q.png",
                                     stationId];
                    [candidates addObject:alt];
                }
            }

            BOOL success = NO;
            for (NSString *candidate in candidates) {
                NSURL *url = [NSURL URLWithString:candidate];
                if (!url) continue;

                // Log every URL we attempt
                NSLog(@"[RadioManager] Icon GET %@", [url absoluteString]);

                // Use raw POSIX sockets for HTTP download - GNUstep's NSURLConnection
                // chokes on Cloudflare response headers ("Bad encoded word" from
                // NSHTTPHeader's RFC 2047 parser), causing timeouts on port 80 and
                // stalls on port 443. Raw sockets bypass this entirely.
                NSData *data = [self socketDownloadDataFromURL:url timeout:15.0];
                if (!data) {
                    continue;
                }

                // Validate with magic bytes (the only reliable check cross-platform)
                if (![self dataLooksLikeImage:data]) {
                    // Log what we actually got to help debug server responses
                    NSUInteger showLen = MIN([data length], 200);
                    const unsigned char *bytes = [data bytes];
                    NSMutableString *hex = [NSMutableString string];
                    for (NSUInteger i = 0; i < showLen; i++) {
                        [hex appendFormat:@"%02x ", bytes[i]];
                    }
                    NSString *asText = nil;
                    if (showLen > 0) {
                        asText = [[[NSString alloc] initWithBytes:bytes
                                                           length:showLen
                                                         encoding:NSUTF8StringEncoding] autorelease];
                        // Only include if it looks like plausible text
                        if (!asText || [asText rangeOfString:@"�"].location != NSNotFound) {
                            asText = nil;
                        }
                    }
                    if (asText) {
                        NSLog(@"[RadioManager] Skipping unrecognized format for %@ - got %tu bytes (hex: %@) text: %@",
                              [url absoluteString], [data length], hex, asText);
                    } else {
                        NSLog(@"[RadioManager] Skipping unrecognized format for %@ - got %tu bytes (hex: %@)",
                              [url absoluteString], [data length], hex);
                    }
                    continue;
                }

                NSLog(@"[RadioManager] Icon downloaded OK size=%tu for %@",
                      [data length], [url absoluteString]);

                // Save valid image to disk cache; downloads run concurrently
                @synchronized(self) {
                    NSString *cachePath = [self cachePathForKey:key];
                    if (cachePath) {
                        NSString *fname = [cachePath lastPathComponent];
                        [data writeToFile:cachePath options:NSDataWritingAtomic error:NULL];

                        // Update index
                        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                        [entry setObject:fname forKey:@"filename"];
                        [entry setObject:@((unsigned long long)[[NSDate date] timeIntervalSince1970])
                                  forKey:@"lastAccess"];
                        [entry setObject:@([data length]) forKey:@"size"];
                        [_iconIndex setObject:entry forKey:key];
                        [self saveIconIndex];
                        [self pruneCacheIfNeeded];
                    }
                }

                // Decode image on main thread
                PlayerRunOnMainThread(^{
                    NSImage *image = [[NSImage alloc] initWithData:data];
                    if (image) {
                        [_stationImages setObject:image forKey:key];
                        [image release];

                        NSUInteger idx = [_stations indexOfObject:station];
                        if (idx != NSNotFound && _delegate != nil &&
                            [_delegate respondsToSelector:@selector(radioManager:didLoadIconAtIndex:)]) {
                            [_delegate radioManager:self didLoadIconAtIndex:idx];
                        }
                    } else {
                        NSLog(@"[RadioManager] Image DECODE FAILED for %@ (key=%@)",
                              [station name] ?: @"?", key);
                    }
                    @synchronized(self->_downloadingKeys) {
                        [self->_downloadingKeys removeObject:key];
                    }
                });

                success = YES;
                break;
            }

            if (!success && attempt < kMaxDownloadRetries) {
                double delay = pow(2.0, attempt);
                PlayerRunOnMainThreadAfter(delay, ^{
                    [self downloadImageWithURL:urlStr key:key station:station attempt:attempt + 1];
                });
            } else if (!success) {
                @synchronized(self->_downloadingKeys) {
                    [self->_downloadingKeys removeObject:key];
                }
            }

        }
    }];
}

- (NSString *)cachePathForKey:(NSString *)key
{
    if (!key || [key length] == 0 || !_iconCachePath) return nil;

    // FNV-1a 64-bit hash
    const char *s = [key UTF8String];
    unsigned long long hash = 14695981039346656037ULL;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        hash ^= (unsigned long long)(*p);
        hash *= 1099511628211ULL;
    }
    NSString *fname = [NSString stringWithFormat:@"%016llx.img", hash];

    // Check if index has a different filename
    NSString *idxFname;
    @synchronized(self) {
        idxFname = [[[[_iconIndex objectForKey:key] objectForKey:@"filename"] retain] autorelease];
    }
    if (idxFname && [idxFname length] > 0) {
        return [_iconCachePath stringByAppendingPathComponent:idxFname];
    }

    return [_iconCachePath stringByAppendingPathComponent:fname];
}

- (NSString *)indexFilePath
{
    return [_iconCachePath stringByAppendingPathComponent:@"index.json"];
}

- (void)loadIconIndex
{
    NSString *idxPath = [self indexFilePath];
    NSData *data = [NSData dataWithContentsOfFile:idxPath];
    if (!data) {
        _iconIndex = [[NSMutableDictionary alloc] init];
        return;
    }

    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![json isKindOfClass:[NSDictionary class]]) {
        _iconIndex = [[NSMutableDictionary alloc] init];
        return;
    }
    [_iconIndex release];
    _iconIndex = [[NSMutableDictionary alloc] initWithDictionary:json];
}

- (void)saveIconIndex
{
    NSString *idxPath = [self indexFilePath];
    if (!idxPath) return;

    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:_iconIndex
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&error];
    if (data) {
        [data writeToFile:idxPath options:NSDataWritingAtomic error:NULL];
    }
}

- (void)pruneCacheIfNeeded
{
    const unsigned long long kMaxCacheSize = 50ULL * 1024ULL * 1024ULL; // 50 MB
    if (!_iconIndex) return;

    unsigned long long total = 0;
    NSMutableArray *entries = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *key in _iconIndex) {
        NSDictionary *entry = [_iconIndex objectForKey:key];
        NSString *fname = [entry objectForKey:@"filename"];
        if (!fname) continue;
        NSString *path = [_iconCachePath stringByAppendingPathComponent:fname];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
        unsigned long long size = [attrs fileSize];
        total += size;
        NSMutableDictionary *e = [[entry mutableCopy] autorelease];
        [e setObject:@(size) forKey:@"size"];
        [e setObject:path forKey:@"path"];
        [entries addObject:e];
    }

    if (total <= kMaxCacheSize) return;

    // Sort by lastAccess ascending (oldest first)
    [entries sortUsingComparator:^NSComparisonResult(id a, id b) {
        NSNumber *la = [a objectForKey:@"lastAccess"];
        NSNumber *lb = [b objectForKey:@"lastAccess"];
        return [la compare:lb];
    }];

    for (NSDictionary *entry in entries) {
        if (total <= kMaxCacheSize) break;
        NSString *path = [entry objectForKey:@"path"];
        if ([fm removeItemAtPath:path error:NULL]) {
            total -= [[entry objectForKey:@"size"] unsignedLongLongValue];
            NSString *fname = [path lastPathComponent];
            NSString *keyToRemove = nil;
            for (NSString *k in _iconIndex) {
                if ([[[_iconIndex objectForKey:k] objectForKey:@"filename"] isEqualToString:fname]) {
                    keyToRemove = k;
                    break;
                }
            }
            if (keyToRemove) {
                [_iconIndex removeObjectForKey:keyToRemove];
            }
        }
    }
    [self saveIconIndex];
}

#pragma mark - Helpers


- (NSArray *)limitStations:(NSArray *)stations
{
    if ([stations count] > 50) {
        return [stations subarrayWithRange:NSMakeRange(0, 50)];
    }
    return stations;
}

/// Check the first bytes of data to see if it looks like a known image format.
/// Avoids passing XML/HTML error pages to NSImage which spams TIFF warnings.
- (BOOL)dataLooksLikeImage:(NSData *)data
{
    if (!data || [data length] < 8) return NO;

    const unsigned char *bytes = [data bytes];
    NSUInteger len = [data length];
    // JPEG: 0xFF 0xD8 0xFF
    if (len >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) return YES;
    // PNG: 0x89 'P' 'N' 'G'
    if (len >= 4 && bytes[0] == 0x89 && bytes[1] == 'P' &&
        bytes[2] == 'N' && bytes[3] == 'G') return YES;
    // GIF: 'G' 'I' 'F'
    if (len >= 3 && bytes[0] == 'G' && bytes[1] == 'I' && bytes[2] == 'F') return YES;
    // BMP: 'B' 'M'
    if (len >= 2 && bytes[0] == 'B' && bytes[1] == 'M') return YES;
    // WebP: 'R' 'I' 'F' 'F' .... 'W' 'E' 'B' 'P'
    if (len >= 12 && bytes[0] == 'R' && bytes[1] == 'I' && bytes[2] == 'F' && bytes[3] == 'F' &&
        bytes[8] == 'W' && bytes[9] == 'E' && bytes[10] == 'B' && bytes[11] == 'P') return YES;
    // TIFF: 0x49 0x49 or 0x4D 0x4D
    if (len >= 2 && ((bytes[0] == 0x49 && bytes[1] == 0x49) ||
                     (bytes[0] == 0x4D && bytes[1] == 0x4D))) return YES;

    return NO;
}


/// Download data from an HTTP URL using raw POSIX sockets.
/// Bypasses NSURLConnection entirely because GNUstep's NSHTTPHeader parser
/// chokes on Cloudflare response headers (e.g. "Bad encoded word" from
/// priority: u=4;i=?0,...) which causes timeouts and stalls.
/// Returns the response body NSData, or nil on failure.
- (NSData *)socketDownloadDataFromURL:(NSURL *)url timeout:(NSTimeInterval)timeout
{
    if (!url) return nil;

    // Determine host, port, path
    NSString *host = [url host];
    if (!host || [host length] == 0) return nil;

    // Use HTTP even for HTTPS URLs - both TuneIn CDNs serve on port 80.
    // For truly HTTPS-only servers this won't work, but in practice
    // Cloudflare CDNs respond on both ports and we avoid the header parser.
    int port = 80;

    NSString *path = [url path];
    if ([url query]) {
        path = [NSString stringWithFormat:@"%@?%@", path, [url query]];
    }
    if ([url fragment]) {
        path = [NSString stringWithFormat:@"%@#%@", path, [url fragment]];
    }
    if (!path || [path length] == 0) path = @"/";

    NSLog(@"[RadioManager] Socket GET http://%@:%d%@", host, port, path);

    // --- Resolve hostname ---
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;   // IPv4 or IPv6
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_NUMERICSERV;
    char portStr[16];
    snprintf(portStr, sizeof(portStr), "%d", port);

    int gaiErr = getaddrinfo([host UTF8String], portStr, &hints, &res);
    if (gaiErr || !res) {
        NSLog(@"[RadioManager] getaddrinfo failed for %@: %s", host, gai_strerror(gaiErr));
        return nil;
    }

    // --- Create socket ---
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        NSLog(@"[RadioManager] socket() failed: %s", strerror(errno));
        freeaddrinfo(res);
        return nil;
    }

    // --- Set send/receive timeouts ---
    struct timeval tv;
    tv.tv_sec = (int)timeout;
    tv.tv_usec = (int)((timeout - (int)timeout) * 1000000);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    // --- Connect ---
    if (connect(fd, res->ai_addr, res->ai_addrlen) < 0) {
        NSLog(@"[RadioManager] connect() to %@:%d failed: %s",
              host, port, strerror(errno));
        close(fd);
        freeaddrinfo(res);
        return nil;
    }
    freeaddrinfo(res);

    // --- Send HTTP GET (HTTP/1.0 with Connection: close for simplicity) ---
    // HTTP/1.0 avoids chunked encoding complexity: server closes connection
    // when done, and Content-Length tells us how much to expect.
    NSString *request = [NSString stringWithFormat:
        @"GET %@ HTTP/1.0\r\n"
        @"Host: %@\r\n"
        @"Connection: close\r\n"
        @"User-Agent: GershwinPlayer/1.0\r\n"
        @"Accept: */*\r\n"
        @"\r\n", path, host];
    const char *reqC = [request UTF8String];
    size_t reqLen = strlen(reqC);

    ssize_t sentTotal = 0;
    while (sentTotal < (ssize_t)reqLen) {
        ssize_t n = write(fd, reqC + sentTotal, reqLen - sentTotal);
        if (n < 0) {
            if (errno == EINTR) continue;
            NSLog(@"[RadioManager] write() failed: %s", strerror(errno));
            close(fd);
            return nil;
        }
        sentTotal += n;
    }

    // --- Read response in chunks ---
    NSMutableData *response = [NSMutableData data];
    char buf[8192];
    ssize_t nRead;

    // Read until EOF (server closes connection with HTTP/1.0 + Connection: close)
    // If read returns < 0 (timeout/error), use whatever data we already got.
    while ((nRead = read(fd, buf, sizeof(buf))) > 0) {
        [response appendBytes:buf length:nRead];
    }
    close(fd);

    if ([response length] == 0) {
        NSLog(@"[RadioManager] Empty response for %@", [url absoluteString]);
        return nil;
    }

    // --- Parse response: split headers from body at \r\n\r\n ---
    const unsigned char *bytes = [response bytes];
    NSUInteger totalLen = [response length];
    NSUInteger headerEnd = NSNotFound;
    for (NSUInteger i = 0; i + 3 < totalLen; i++) {
        if (bytes[i] == '\r' && bytes[i+1] == '\n' &&
            bytes[i+2] == '\r' && bytes[i+3] == '\n') {
            headerEnd = i;
            break;
        }
    }
    if (headerEnd == NSNotFound) {
        NSLog(@"[RadioManager] No header separator in response for %@", [url absoluteString]);
        return nil;
    }

    // Extract status line from headers
    NSString *headerStr = [[[NSString alloc] initWithBytes:bytes
                                                    length:headerEnd
                                                  encoding:NSUTF8StringEncoding] autorelease];
    if (!headerStr || [headerStr length] == 0) {
        return nil;
    }

    // Check HTTP status line: "HTTP/1.x NNN ..."
    BOOL statusOK = NO;
    NSArray *lines = [headerStr componentsSeparatedByString:@"\r\n"];
    if ([lines count] > 0) {
        NSString *statusLine = [lines objectAtIndex:0];
        // Find the space-separated status code
        NSRange firstSpace = [statusLine rangeOfString:@" "];
        if (firstSpace.location != NSNotFound) {
            NSString *codeStr = [statusLine substringFromIndex:firstSpace.location + 1];
            NSRange secondSpace = [codeStr rangeOfString:@" "];
            if (secondSpace.location != NSNotFound) {
                codeStr = [codeStr substringToIndex:secondSpace.location];
            }
            int statusCode = [codeStr intValue];
            statusOK = (statusCode >= 200 && statusCode < 300);
            if (!statusOK) {
                // Log the error body for debugging
                NSData *body = [NSData dataWithBytes:bytes + headerEnd + 4
                                              length:totalLen - headerEnd - 4];
                NSString *bodyStr = [[[NSString alloc] initWithData:body
                                                           encoding:NSUTF8StringEncoding] autorelease];
                NSLog(@"[RadioManager] HTTP %d for %@ - body: %.200s",
                      statusCode, [url absoluteString],
                      bodyStr ? [bodyStr UTF8String] : "(binary)");
            }
        }
    }

    if (!statusOK) {
        return nil;
    }

    // Return body data
    NSUInteger bodyLen = totalLen - headerEnd - 4;
    NSData *bodyData = [NSData dataWithBytes:bytes + headerEnd + 4 length:bodyLen];
    return bodyData;
}

@end
