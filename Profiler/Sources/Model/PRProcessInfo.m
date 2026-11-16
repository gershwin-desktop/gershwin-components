/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRProcessInfo.h"
#include <unistd.h>

@implementation PRProcessInfo

- (BOOL)isOwnProcess
{
    return [self user] == getuid();
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"%d %@", [self pid], [self name]];
}

@end
