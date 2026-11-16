/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/*
 * Three-way, line-based merge for one list's Markdown file: base is the
 * text as it stood at the last successful pull, local is the text with
 * the user's edits since then, remote is what a fresh pull just returned.
 *
 * A base-only line is unchanged in the winning side and copied through.
 * A line changed on exactly one side is applied as-is (no conflict). A
 * base range changed differently on both sides is never silently
 * resolved either way: it is wrapped in git-style conflict markers
 * ("<<<<<<< local" / "=======" / ">>>>>>> remote") so both versions
 * survive and a person (or a future smarter merge) can pick between
 * them - the store never overwrites one side's edit with the other's.
 */
@interface TDLineMerge : NSObject

+ (NSString *)mergeBase: (NSString *)base
                   local: (NSString *)local
                  remote: (NSString *)remote
                conflict: (BOOL *)hasConflict;

@end
