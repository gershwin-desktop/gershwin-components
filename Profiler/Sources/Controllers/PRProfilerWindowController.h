/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "PRTypes.h"
#import "PRRecorder.h"
#import "PRFlameGraphView.h"
#import "PRTimelineView.h"
#import "PRLegendView.h"

@class PRProfile;
@class PRCallTreeController;
@class PRFlatTableController;

/* The window that shows one profile: where the cost went, seen as a flame
   graph, as call trees in both directions and as a flat list. */
@interface PRProfilerWindowController : NSWindowController
    <PRRecorderDelegate, PRFlameGraphViewDelegate, PRTimelineViewDelegate,
     NSTextFieldDelegate>
{
    PRProfile *_profile;
    PRRecorder *_recorder;
    PRTimeRange _range;
    int32_t _thread;

    NSButton *_recordButton;
    NSButton *_stopButton;
    NSPopUpButton *_threadPopUp;
    NSPopUpButton *_costPopUp;
    NSSearchField *_searchField;
    NSTextField *_matchedLabel;
    NSTextField *_statusLabel;
    NSTextField *_headerLabel;

    PRTimelineView *_timeline;
    NSTabView *_tabView;

    NSScrollView *_flameScroll;
    PRFlameGraphView *_flameGraph;
    NSButton *_callersRadio;
    NSButton *_hotFramesRadio;
    NSTextField *_zoomLabel;
    PRLegendView *_legend;

    NSOutlineView *_topDownOutline;
    NSOutlineView *_bottomUpOutline;
    PRCallTreeController *_topDownController;
    PRCallTreeController *_bottomUpController;

    NSTableView *_flatTable;
    PRFlatTableController *_flatController;
    NSPopUpButton *_groupingPopUp;

    NSTextView *_summaryView;
}

- (void)startRecording:(id)sender;
- (void)stopRecording:(id)sender;
- (void)openFoldedStacks:(id)sender;
/* Reads a file of folded stacks. Returns NO when it holds no stacks. */
- (BOOL)openProfileAtPath:(NSString *)path;
- (void)exportFoldedStacks:(id)sender;
/* Ends a running recording so that no sampling tool is left behind. */
- (void)stopEverything;

@end
