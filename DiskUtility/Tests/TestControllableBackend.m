/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "TestControllableBackend.h"

#import "DUErrors.h"

@implementation DUControllableBackend

- (NSArray<DUStorageObject *> *)discoverStorageObjects:(NSError **)error
{
    if (self.failNextDiscovery) {
        self.failNextDiscovery = NO;
        if (error != NULL) {
            *error = [NSError errorWithDomain:DUStorageErrorDomain
                                         code:DUErrorDiscoveryFailed
                                     userInfo:nil];
        }
        return nil;
    }
    return self.nextDiscovery ?: [super discoverStorageObjects:NULL];
}

@end
