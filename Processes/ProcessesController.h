/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "ProcessInfo.h"
#import "ProcessHealth.h"
#import "SparklineView.h"

@interface ProcessesController : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSTextFieldDelegate>
{
    NSMutableArray *_processes;
    /* What the table shows: _processes after the filters, sorted. */
    NSArray *_visibleProcesses;
    NSTimer *_refreshTimer;
    NSTimeInterval _refreshInterval;
    NSLock *_processesLock;

    // UI References
    NSWindow *_mainWindow;
    NSSearchField *_searchField;
    NSButton *_problemsOnlyCheckbox;
    NSTextField *_summaryLabel;
    NSTableView *_processesTableView;

    // Inspector drawer
    NSDrawer *_infoDrawer;
    NSView *_drawerContentView;
    NSTextField *_drawerTitleLabel;
    NSTextField *_drawerStatusLabel;
    SparklineView *_memorySparkline;
    SparklineView *_cpuSparkline;
    NSScrollView *_explanationScrollView;
    NSTextView *_explanationTextView;
    NSButton *_quitButton;
    NSButton *_forceQuitButton;
    NSButton *_suspendButton;
    NSButton *_resumeButton;

    NSArray *_sortDescriptors;
    /* Remembers what every process did, and judges it. */
    ProcessHistory *_history;
    long _totalMemoryKB;
    BOOL _isRefreshing;
    BOOL _problemsOnly;
    NSString *_searchFilter;
}

@property (nonatomic, strong) NSMutableArray *processes;

+ (ProcessesController *)sharedController;

// Process management
- (void)refreshProcesses;
- (void)startMonitoring;
- (void)stopMonitoring;

// Returns whether a refresh is currently running
- (BOOL)isRefreshing;

// UI Actions
- (void)setupMenu;
- (IBAction)showProcessInfo:(id)sender;
- (IBAction)quitProcess:(id)sender;
- (IBAction)forceQuitProcess:(id)sender;
- (IBAction)suspendProcess:(id)sender;
- (IBAction)resumeProcess:(id)sender;
- (IBAction)refreshNow:(id)sender;
- (IBAction)toggleProblemsOnly:(id)sender;
- (void)clearSearchFilter;

// Called by the drawer's content view whenever the drawer is resized
- (void)layoutDrawerContent;

// Sorting
- (void)sortProcesses;

// Table view data source
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView;
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row;

// Table view delegate
- (void)tableViewSelectionDidChange:(NSNotification *)notification;
- (void)tableView:(NSTableView *)tableView didClickTableColumn:(NSTableColumn *)tableColumn;
- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray *)oldDescriptors;

@end
