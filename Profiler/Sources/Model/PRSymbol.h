/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* One resolved frame of a call stack: a function or method in a binary.
   Symbols are interned by PRProfile, so pointer equality is identity. */
@interface PRSymbol : NSObject
{
    NSUInteger _index;
    NSString *_rawName;
    NSString *_displayName;
    NSString *_className;
    NSString *_moduleName;
    NSString *_modulePath;
    BOOL _isKernel;
    BOOL _isUnknown;
}

- (id)initWithIndex:(NSUInteger)index
            rawName:(NSString *)rawName
         modulePath:(NSString *)modulePath;

@property (nonatomic, readonly) NSUInteger index;

/* The name as the profiler tool reported it, e.g.
   "_i_NSRunLoop__acceptInputForMode_beforeDate_". */
@property (nonatomic, readonly, copy) NSString *rawName;

/* The name shown to the user: Objective-C methods appear in source form,
   e.g. "-[NSRunLoop acceptInputForMode:beforeDate:]". */
@property (nonatomic, readonly, copy) NSString *displayName;

/* Objective-C class this symbol belongs to, or nil for plain C functions. */
@property (nonatomic, readonly, copy) NSString *className;

/* Last path component of the binary, e.g. "libgnustep-base.so.1.31.1". */
@property (nonatomic, readonly, copy) NSString *moduleName;
@property (nonatomic, readonly, copy) NSString *modulePath;

@property (nonatomic, readonly) BOOL isKernel;
@property (nonatomic, readonly) BOOL isUnknown;

@end
