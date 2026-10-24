/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUMockStorageBackend.h"

/* A backend whose discovery result the test controls, so a refresh can be made
 * to return exactly the tree it wants. Everything else is the mock backend's,
 * which keeps the DUStorageBackend protocol satisfied without a second full
 * implementation. */
@interface DUControllableBackend : DUMockStorageBackend

// What -discoverStorageObjects: returns. nil means "return the mock's own
// pristine hierarchy", so a test only sets it to make a poll lie.
@property (nonatomic, copy) NSArray<DUStorageObject *> *nextDiscovery;

// When YES, the next discovery fails, as a wedged geom would.
@property (nonatomic) BOOL failNextDiscovery;

@end
