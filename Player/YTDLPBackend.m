/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "YTDLPBackend.h"

/**
 * yt-dlp output format (via --print):
 *   Line 1: resolved stream URL
 *   Line 2: title
 *   Line 3: thumbnail URL
 *   Line 4: duration (seconds as float)
 *
 * A blank line means that field was unavailable.
 */

static NSString *const kDefaultFormat = @"best/best";

@interface YTDLPBackend ()
- (void)_taskCompletedWithOutput:(NSString *)stdoutOutput
                     errorOutput:(NSString *)stderrOutput;
- (void)_taskFailedWithError:(NSString *)error;
- (void)_taskCancelled;
@end

@implementation YTDLPBackend

@synthesize delegate = _delegate;
@synthesize formatSpec = _formatSpec;
@synthesize ytdlpPath = _ytdlpPath;
@synthesize running = _isRunning;

- (instancetype)init
{
    self = [super init];
    if (self) {
        _formatSpec = [kDefaultFormat retain];
        _ytdlpPath = [@"yt-dlp" retain];
        _isRunning = NO;
    }
    return self;
}

- (void)dealloc
{
    [self cancel];
    [_formatSpec release];
    [_ytdlpPath release];
    [super dealloc];
}

#pragma mark - Public API

- (void)resolveURL:(NSString *)url
{
    if (_isRunning) {
        [self cancel];
    }
    if (!url || [url length] == 0) {
        [self _taskFailedWithError:@"Empty URL"];
        return;
    }

    NSLog( @"[YTDLPBackend] resolveURL: %@", url);
    NSLog( @"[YTDLPBackend]   format: %@, path: %@", _formatSpec, _ytdlpPath);

    // Formats with '+' request separate DASH streams (e.g. bestvideo+bestaudio)
    // which can't produce a single URL via --print url. Fall back to best.
    NSString *effectiveFormat = _formatSpec;
    if ([effectiveFormat rangeOfString:@"+"].location != NSNotFound) {
        NSLog(@"[YTDLPBackend]   format contains '+', falling back to best/best for URL resolution");
        effectiveFormat = @"best/best";
    }

    // Build arguments:
    // yt-dlp --print url --print title --print thumbnail --print duration -f <format> <url>
    NSMutableArray *args = [NSMutableArray array];
    [args addObject:@"--print"];
    [args addObject:@"url"];
    [args addObject:@"--print"];
    [args addObject:@"title"];
    [args addObject:@"--print"];
    [args addObject:@"thumbnail"];
    [args addObject:@"--print"];
    [args addObject:@"duration"];

    // No-warnings to keep output clean
    [args addObject:@"--no-warnings"];

    // Don't download anything, just print metadata
    [args addObject:@"--skip-download"];

    if ([effectiveFormat length] > 0) {
        [args addObject:@"-f"];
        [args addObject:effectiveFormat];
    }

    [args addObject:url];

    NSLog( @"[YTDLPBackend]   command: %@ %@", _ytdlpPath,
                [args componentsJoinedByString:@" "]);

    // Set up task
    _task = [[NSTask alloc] init];
    [_task setLaunchPath:_ytdlpPath];
    [_task setArguments:args];

    // Set up pipes
    _outputPipe = [[NSPipe alloc] init];
    _errorPipe = [[NSPipe alloc] init];
    [_task setStandardOutput:_outputPipe];
    [_task setStandardError:_errorPipe];

    _isRunning = YES;

    // Register for termination notification
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_taskTerminated:)
                                                 name:NSTaskDidTerminateNotification
                                               object:_task];

    @try {
        [_task launch];

        // Read output in background to avoid deadlock on large output
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *outData = [[[_task standardOutput] fileHandleForReading] readDataToEndOfFile];
            NSData *errData = [[[_task standardError] fileHandleForReading] readDataToEndOfFile];

            NSString *outStr = [[[NSString alloc] initWithData:outData
                                                      encoding:NSUTF8StringEncoding] autorelease];
            NSString *errStr = [[[NSString alloc] initWithData:errData
                                                      encoding:NSUTF8StringEncoding] autorelease];

            // Wait for the task to finish
            [_task waitUntilExit];

            dispatch_async(dispatch_get_main_queue(), ^{
                if (_isRunning) {
                    int status = [_task terminationStatus];
                    if (status == 0) {
                        [self _taskCompletedWithOutput:outStr errorOutput:errStr];
                    } else {
                        NSString *errorMsg = errStr;
                        if (!errorMsg || [errorMsg length] == 0) {
                            errorMsg = [NSString stringWithFormat:
                                @"yt-dlp exited with status %d", status];
                        }
                        [self _taskFailedWithError:errorMsg];
                    }
                }
                // else: was cancelled, delegate already notified
            });
        });
    } @catch (NSException *exception) {
        _isRunning = NO;
        [self _taskFailedWithError:
            [NSString stringWithFormat:@"Failed to launch yt-dlp: %@",
                [exception reason]]];
    }
}

- (void)cancel
{
    if (!_isRunning) {
        NSLog( @"[YTDLPBackend] cancel - not running, ignoring");
        return;
    }

    NSLog( @"[YTDLPBackend] cancel - terminating task");

    _isRunning = NO;

    @try {
        if (_task && [_task isRunning]) {
            [_task terminate];
        }
    } @catch (NSException *e) {
        // Ignore errors during termination
    }

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSTaskDidTerminateNotification
                                                  object:_task];

    [_task release]; _task = nil;
    [_outputPipe release]; _outputPipe = nil;
    [_errorPipe release]; _errorPipe = nil;

    if ([_delegate respondsToSelector:@selector(ytdlpBackendDidCancel:)]) {
        [_delegate ytdlpBackendDidCancel:self];
    }
}

- (BOOL)checkAvailability
{
    NSLog( @"[YTDLPBackend] checkAvailability - path: %@", _ytdlpPath);
    @try {
        NSTask *task = [[[NSTask alloc] init] autorelease];
        [task setLaunchPath:_ytdlpPath];
        [task setArguments:@[@"--version"]];
        NSPipe *pipe = [[[NSPipe alloc] init] autorelease];
        [task setStandardOutput:pipe];
        [task setStandardError:pipe];
        [task launch];
        [task waitUntilExit];
        BOOL available = ([task terminationStatus] == 0);
        NSLog( @"[YTDLPBackend] checkAvailability - %@: %@",
                    _ytdlpPath, available ? @"available" : @"not found");
        return available;
    } @catch (NSException *e) {
        NSLog( @"[YTDLPBackend] checkAvailability - exception: %@", [e reason]);
        return NO;
    }
}

+ (NSString *)extractVideoIDFromURL:(NSString *)url
{
    if (!url) return nil;

    // YouTube: youtube.com/watch?v=ID or youtu.be/ID
    NSRange vRange = [url rangeOfString:@"v="];
    if (vRange.location != NSNotFound) {
        NSString *afterV = [url substringFromIndex:vRange.location + 2];
        NSRange amp = [afterV rangeOfString:@"&"];
        if (amp.location != NSNotFound) {
            return [afterV substringToIndex:amp.location];
        }
        NSRange hash = [afterV rangeOfString:@"#"];
        if (hash.location != NSNotFound) {
            return [afterV substringToIndex:hash.location];
        }
        // Heuristic: video IDs are 11 characters
        if ([afterV length] >= 11) {
            return [afterV substringToIndex:11];
        }
        return afterV;
    }

    // Short URL: youtu.be/ID
    NSRange beRange = [url rangeOfString:@"youtu.be/"];
    if (beRange.location != NSNotFound) {
        NSString *after = [url substringFromIndex:beRange.location + 9];
        NSRange q = [after rangeOfString:@"?"];
        if (q.location != NSNotFound) {
            return [after substringToIndex:q.location];
        }
        NSRange slash = [after rangeOfString:@"/"];
        if (slash.location != NSNotFound) {
            return [after substringToIndex:slash.location];
        }
        if ([after length] >= 11) {
            return [after substringToIndex:11];
        }
        return after;
    }

    // Vimeo: vimeo.com/ID
    NSRange vimeoRange = [url rangeOfString:@"vimeo.com/"];
    if (vimeoRange.location != NSNotFound) {
        NSString *after = [url substringFromIndex:vimeoRange.location + 10];
        NSRange q = [after rangeOfString:@"?"];
        if (q.location != NSNotFound) {
            return [after substringToIndex:q.location];
        }
        NSRange slash = [after rangeOfString:@"/"];
        if (slash.location != NSNotFound) {
            return [after substringToIndex:slash.location];
        }
        return after;
    }

    return nil;
}

#pragma mark - Internal

- (void)_taskTerminated:(NSNotification *)note
{
    // Cleanup is handled in the dispatch_async block in resolveURL:
    // This notification is just to know the task ended.
}

- (void)_taskCompletedWithOutput:(NSString *)stdoutOutput
                     errorOutput:(NSString *)stderrOutput
{
    _isRunning = NO;

    NSLog( @"[YTDLPBackend] _taskCompletedWithOutput:");
    NSLog( @"[YTDLPBackend]   stdout (%tu bytes): %@",
                [stdoutOutput length], stdoutOutput);
    if ([stderrOutput length] > 0) {
        NSLog( @"[YTDLPBackend]   stderr (%tu bytes): %@",
                    [stderrOutput length], stderrOutput);
    }

    // Parse output: lines are url, title, thumbnail, duration
    NSArray *lines = [stdoutOutput componentsSeparatedByString:@"\n"];
    NSString *url     = ([lines count] > 0) ? [[lines objectAtIndex:0] stringByTrimmingCharactersInSet:
                                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    NSString *title   = ([lines count] > 1) ? [[lines objectAtIndex:1] stringByTrimmingCharactersInSet:
                                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    NSString *thumb   = ([lines count] > 2) ? [[lines objectAtIndex:2] stringByTrimmingCharactersInSet:
                                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    NSString *durStr  = ([lines count] > 3) ? [[lines objectAtIndex:3] stringByTrimmingCharactersInSet:
                                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";

    NSTimeInterval duration = [durStr doubleValue];

    NSLog( @"[YTDLPBackend]   parsed - url: %@", url);
    NSLog( @"[YTDLPBackend]   parsed - title: %@", title);
    NSLog( @"[YTDLPBackend]   parsed - thumbnail: %@", thumb);
    NSLog( @"[YTDLPBackend]   parsed - duration: %.1fs", duration);

    // Cleanup task resources
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSTaskDidTerminateNotification
                                                  object:_task];
    [_task release]; _task = nil;
    [_outputPipe release]; _outputPipe = nil;
    [_errorPipe release]; _errorPipe = nil;

    if (!url || [url length] == 0) {
        NSString *errorMsg = stderrOutput;
        if (!errorMsg || [errorMsg length] == 0) {
            errorMsg = @"yt-dlp returned no stream URL";
        }
        [self _taskFailedWithError:errorMsg];
        return;
    }

    if ([_delegate respondsToSelector:@selector(ytdlpBackend:didResolveURL:title:thumbnail:duration:)]) {
        [_delegate ytdlpBackend:self didResolveURL:url
                          title:title
                     thumbnail:thumb
                      duration:duration];
    }
}

- (void)_taskFailedWithError:(NSString *)error
{
    NSLog( @"[YTDLPBackend] _taskFailedWithError: %@", error);
    _isRunning = NO;

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSTaskDidTerminateNotification
                                                  object:_task];
    [_task release]; _task = nil;
    [_outputPipe release]; _outputPipe = nil;
    [_errorPipe release]; _errorPipe = nil;

    if ([_delegate respondsToSelector:@selector(ytdlpBackend:didFailWithError:)]) {
        [_delegate ytdlpBackend:self didFailWithError:error];
    }
}

- (void)_taskCancelled
{
    NSLog( @"[YTDLPBackend] _taskCancelled");
    _isRunning = NO;

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSTaskDidTerminateNotification
                                                  object:_task];
    [_task release]; _task = nil;
    [_outputPipe release]; _outputPipe = nil;
    [_errorPipe release]; _errorPipe = nil;

    if ([_delegate respondsToSelector:@selector(ytdlpBackendDidCancel:)]) {
        [_delegate ytdlpBackendDidCancel:self];
    }
}

@end
