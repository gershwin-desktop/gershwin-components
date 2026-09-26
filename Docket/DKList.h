/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/*
 * One to-do list.  Corresponds to exactly one file in the backing gist
 * (<name>.md); see DKMarkdownCodec for the file format.
 */
@interface DKList : NSObject <NSCopying>
{
  NSString *_name;
  NSMutableArray *_tasks; /* array of DKTask */
}

@property (nonatomic, copy) NSString *name;
@property (nonatomic, readonly) NSMutableArray *tasks;

+ (instancetype)listWithName: (NSString *)name;

/* The gist filename this list round-trips to/from ("<name>.md"; spaces and
 * slashes are replaced since gist filenames are flat). */
- (NSString *)gistFilename;

@end
