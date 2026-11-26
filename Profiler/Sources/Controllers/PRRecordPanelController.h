/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "PRRecorder.h"

@class PRProcessMonitor;
@class PRLiveGraphView;

/* Asks what should be measured and how: a running program to attach to or
   a program to start, CPU time or heap memory, and the sampling details.
   Runs modally and hands back a filled in request. */
@interface PRRecordPanelController : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>
{
    NSWindow *_panel;
    NSButton *_attachRadio;
    NSButton *_launchRadio;
    NSTableView *_processTable;
    NSSearchField *_filterField;
    NSTextField *_launchField;
    NSTextField *_argumentsField;
    NSPopUpButton *_modePopUp;
    NSPopUpButton *_frequencyPopUp;
    NSPopUpButton *_callGraphPopUp;
    NSPopUpButton *_memoryCostPopUp;
    NSButton *_durationCheck;
    NSTextField *_durationField;
    NSTextField *_noteField;
    NSButton *_recordButton;
    PRLiveGraphView *_liveGraph;
    PRProcessMonitor *_monitor;
    NSArray *_processes;
    NSArray *_visibleProcesses;
    NSTimer *_refreshTimer;
    PRRecordRequest *_result;
}

/* Returns the request to record, or nil when the user cancelled. */
- (PRRecordRequest *)runModal;

@end
