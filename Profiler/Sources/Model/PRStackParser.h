/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class PRProfile;

/* Common base for the line oriented parsers: every recording tool is asked
   to print its samples as text, which is fed here line by line as it
   arrives so that a long recording does not have to be held in memory
   twice. */
@interface PRStackParser : NSObject
{
    PRProfile *_profile;
}

- (id)initWithProfile:(PRProfile *)profile;
@property (nonatomic, readonly, strong) PRProfile *profile;

- (void)parseLine:(NSString *)line;
- (void)finish;

/* Feeds a whole text at once. */
- (void)parseString:(NSString *)text;

@end

/* Parses the output of "perf script" (Linux). */
@interface PRPerfScriptParser : PRStackParser
@end

/* Parses folded stacks, "frame;frame;frame weight", as produced by
   heaptrack_print --print-flamegraph and by the FlameGraph scripts. */
@interface PRFoldedStackParser : PRStackParser
@end

/* Parses DTrace ustack() aggregations printed with printa("%k%@d\n", @).
   Used by the FreeBSD and NetBSD backends. */
@interface PRDTraceStackParser : PRStackParser
@end
