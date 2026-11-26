/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWCurlMeterReader - the stderr side of GWAppImageDownloader.
 *
 * curl writes its progress meter to stderr as one update per tick, each
 * starting with a carriage return and ending in a percent:
 *
 *     \r####...#### 42.0%
 *
 * Everything else on that stream is curl talking: its own diagnostics, of
 * which "curl: (22) The requested URL returned error: 403" is the one a
 * caller needs to see. The downloader hands the stream to this reader, which
 * answers with installDidProgress: reports for the meter and
 * installDidOutputLine: for the text. It is a class rather than a loop
 * inside the downloader because updates arrive split at arbitrary byte
 * boundaries and the state that survives between two chunks deserves a test
 * of its own.
 */

#import <Foundation/Foundation.h>

@protocol GWInstallProgressHandler;

@interface GWCurlMeterReader : NSObject

/* progress receives every update that carries a percent, with message.
 * firstValue..lastValue is the slice of the caller's own 0..1 scale the
 * transfer owns, so a download that runs to 100 % ends just below whatever
 * phase follows it instead of claiming the run is over while it is not. */
- (instancetype)initWithProgress:(id<GWInstallProgressHandler>)progress
                         message:(NSString *)message
                           first:(float)firstValue
                             last:(float)lastValue NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/* Hand over the next chunk of curl's stderr as it arrives. */
- (void)ingestData:(NSData *)data;

/* The stream ended: report an update that was still waiting for the
 * carriage return that would have closed it. */
- (void)finish;

/* The text side of one segment, trimmed, or nil when there is nothing to
 * say: an empty segment, or the meter's own glyphs in its no-percent form
 * (a spinner), which is a picture and not a sentence. This is the rule
 * consumeSegment: applies before it forwards a segment, offered separately
 * so a caller with no meter to read, and a test, can both apply it. */
+ (nullable NSString *)outputLineForSegment:(NSString *)segment;

/* Read a pipe of curl's stderr to the end while the process writes it and
 * hand every line of text to progress. For the curls that run silent (the
 * release lookup), where no meter ever arrives. Reading is not optional
 * there either: a pipe nobody reads blocks curl for good once 64 KB has
 * piled up in it. */
+ (void)forwardStderrOfPipe:(NSPipe *)pipe
                 toProgress:(nullable id<GWInstallProgressHandler>)progress;

@end
