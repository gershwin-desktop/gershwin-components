/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRSymbol.h"
#import "PRObjCDemangler.h"

@implementation PRSymbol

@synthesize index = _index;
@synthesize rawName = _rawName;
@synthesize displayName = _displayName;
@synthesize className = _className;
@synthesize moduleName = _moduleName;
@synthesize modulePath = _modulePath;
@synthesize isKernel = _isKernel;
@synthesize isUnknown = _isUnknown;

- (id)initWithIndex:(NSUInteger)index
            rawName:(NSString *)rawName
         modulePath:(NSString *)modulePath
{
    self = [super init];
    if (self == nil)
        return nil;

    _index = index;
    _rawName = [rawName copy];
    _modulePath = [modulePath copy];

    NSString *className = nil;
    _displayName = [[PRObjCDemangler demangle:rawName className:&className] copy];
    _className = [className copy];

    _isKernel = [modulePath hasPrefix:@"[kernel"] ||
                [modulePath hasPrefix:@"[vdso"] ||
                [modulePath hasPrefix:@"/boot/"] ||
                [modulePath hasSuffix:@".ko"];
    _isUnknown = [rawName isEqualToString:@"[unknown]"] || [rawName length] == 0;

    /* perf appends " (deleted)" to the path of a binary that was replaced
       while the program ran; the name the user knows is the file name. */
    NSString *path = _modulePath;
    if ([path hasSuffix:@" (deleted)"])
        path = [path substringToIndex:[path length] - 10];
    NSString *base = [path lastPathComponent];
    _moduleName = [([base length] ? base : @"[unknown]") copy];

    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ (%@)", _displayName, _moduleName];
}

@end
