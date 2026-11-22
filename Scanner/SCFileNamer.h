/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/*
 * Picks file names for scans from a pattern such as "Scan-####": the run of
 * '#' becomes a zero-padded number one higher than the highest number
 * already in the folder, so scans keep their order and existing files are
 * never overwritten. A pattern without '#' gets "-####" appended.
 */
@interface SCFileNamer : NSObject

- (instancetype) initWithDirectory: (NSString *)directory
                           pattern: (NSString *)pattern
                         extension: (NSString *)extension;

- (NSString *) nextPath;

@end
