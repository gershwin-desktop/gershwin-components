/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class PRProcessMonitor;
@class PRMemoryMap;

/* Shows where the memory of a running program actually sits: the heap, the
   stacks, the program and its libraries, files read through memory and what
   was shared with others. Nothing is recorded and nothing is injected, so
   any program can be looked at, including one that has been running for
   days. */
@interface PRMemoryWindowController : NSWindowController
    <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>
{
    PRProcessMonitor *_monitor;
    NSArray *_processes;
    NSArray *_visibleProcesses;
    PRMemoryMap *_map;
    NSArray *_rows;
    pid_t _pid;
    NSTimer *_timer;

    NSSearchField *_searchField;
    NSTableView *_processTable;
    NSTableView *_regionTable;
    NSPopUpButton *_groupingPopUp;
    NSTextField *_summaryLabel;
    NSTextField *_statusLabel;
}

/* Stops the refreshing when the window is done with. */
- (void)stopEverything;

@end
