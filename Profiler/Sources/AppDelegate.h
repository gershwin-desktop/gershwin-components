/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class PRProfilerWindowController;
@class PRObjectCensusController;
@class PRMemoryWindowController;

@interface AppDelegate : NSObject <NSApplicationDelegate>
{
    PRProfilerWindowController *_windowController;
    PRObjectCensusController *_censusController;
    PRMemoryWindowController *_memoryController;
}
@end
