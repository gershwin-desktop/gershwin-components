/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class PRCensusClient;
@class PRCensusSnapshot;

/* Watches how many objects of every class a program holds, so that a leak
   can be read as "NSImage, 1204 more than a minute ago" instead of being
   hunted through call stacks. */
@interface PRObjectCensusController : NSWindowController
    <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>
{
    PRCensusClient *_client;
    PRCensusSnapshot *_current;
    PRCensusSnapshot *_baseline;
    NSArray *_rows;
    NSTimer *_timer;
    NSString *_sortKey;

    NSTextField *_programField;
    NSButton *_startButton;
    NSButton *_stopButton;
    NSButton *_markButton;
    NSSearchField *_searchField;
    NSTextField *_statusLabel;
    NSTextField *_summaryLabel;
    NSTableView *_table;
}

- (void)startWatching:(id)sender;
- (void)stopWatching:(id)sender;
/* Ends a watched program so that none is left behind when the app quits. */
- (void)stopEverything;

@end
