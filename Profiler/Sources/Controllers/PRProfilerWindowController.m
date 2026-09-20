/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRProfilerWindowController.h"
#import "PRRecordPanelController.h"
#import "PRRecorderFactory.h"
#import "PRProfile.h"
#import "PRCallNode.h"
#import "PRSymbol.h"
#import "PRStackParser.h"
#import "PRCallTreeController.h"
#import "PRFlatTableController.h"
#import "PRAppearance.h"
#import "AppearanceMetrics.h"

static const CGFloat kWindowWidth = 1120.0;
static const CGFloat kWindowHeight = 780.0;
static const CGFloat kTimelineHeight = 56.0;
static const CGFloat kRowHeight = 22.0;

@implementation PRProfilerWindowController

- (id)init
{
    NSRect frame = NSMakeRect(0, 0, kWindowWidth, kWindowHeight);
    NSWindow *window = [[NSWindow alloc]
                        initWithContentRect:frame
                                  styleMask:(NSTitledWindowMask |
                                             NSClosableWindowMask |
                                             NSMiniaturizableWindowMask |
                                             NSResizableWindowMask)
                                    backing:NSBackingStoreBuffered
                                      defer:NO];
    [window setTitle:@"Profiler"];
    [window setMinSize:NSMakeSize(820, 560)];

    self = [super initWithWindow:window];
    if (self == nil)
        return nil;

    _range = PRTimeRangeAll();
    _thread = PR_ALL_THREADS;
    _topDownController = [[PRCallTreeController alloc] init];
    _bottomUpController = [[PRCallTreeController alloc] init];
    _flatController = [[PRFlatTableController alloc] init];

    [self buildInterface];
    [window center];
    return self;
}

/* Small helpers */

- (NSTextField *)labelWithString:(NSString *)string
                           frame:(NSRect)frame
                       alignment:(NSTextAlignment)alignment
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    [label setStringValue:string];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setBordered:NO];
    [label setDrawsBackground:NO];
    [label setAlignment:alignment];
    [label setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    return label;
}

- (NSButton *)buttonWithTitle:(NSString *)title
                       action:(SEL)action
                        frame:(NSRect)frame
{
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    [button setTitle:title];
    [button setBezelStyle:NSRoundedBezelStyle];
    [button setTarget:self];
    [button setAction:action];
    return button;
}

/* Two buttons instead of an NSMatrix: each one is a widget of its own, so
   the interface can be driven and tested by name. */
- (NSButton *)radioWithTitle:(NSString *)title frame:(NSRect)frame
{
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    [button setButtonType:NSRadioButton];
    [button setTitle:title];
    [button setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [button setTarget:self];
    [button setAction:@selector(directionChanged:)];
    [button setAutoresizingMask:NSViewMinYMargin];
    return button;
}

- (NSScrollView *)scrollViewWithFrame:(NSRect)frame
{
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:frame];
    [scroll setHasVerticalScroller:YES];
    [scroll setHasHorizontalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    [scroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    return scroll;
}

/* Layout */

- (void)buildInterface
{
    NSView *content = [[self window] contentView];
    CGFloat margin = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat width = kWindowWidth - 2 * margin;
    CGFloat y = kWindowHeight - METRICS_CONTENT_TOP_MARGIN - kRowHeight;

    _recordButton = [self buttonWithTitle:@"Record..."
                                   action:@selector(startRecording:)
                                    frame:NSMakeRect(margin, y + 1, 110,
                                                     METRICS_BUTTON_HEIGHT)];
    [_recordButton setAutoresizingMask:NSViewMinYMargin];
    [content addSubview:_recordButton];

    _stopButton = [self buttonWithTitle:@"Stop"
                                 action:@selector(stopRecording:)
                                  frame:NSMakeRect(margin + 110 +
                                                   METRICS_BUTTON_HORIZ_INTERSPACE,
                                                   y + 1, 80,
                                                   METRICS_BUTTON_HEIGHT)];
    [_stopButton setAutoresizingMask:NSViewMinYMargin];
    [_stopButton setEnabled:NO];
    [content addSubview:_stopButton];

    CGFloat searchWidth = 220;
    _searchField = [[NSTextField alloc] initWithFrame:
                    NSMakeRect(kWindowWidth - margin - searchWidth, y,
                               searchWidth, kRowHeight)];
    [_searchField setTarget:self];
    [_searchField setAction:@selector(searchChanged:)];
    /* Highlighting while typing is what makes the search useful: the graph
       shows at once how much of the profile a name accounts for. */
    [_searchField setDelegate:self];
    [[_searchField cell] setPlaceholderString:@"Find a function"];
    [_searchField setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [content addSubview:_searchField];

    CGFloat threadX = margin + 110 + 80 + 2 * METRICS_BUTTON_HORIZ_INTERSPACE;
    _threadPopUp = [[NSPopUpButton alloc] initWithFrame:
                    NSMakeRect(threadX, y, 230, kRowHeight) pullsDown:NO];
    [_threadPopUp setTarget:self];
    [_threadPopUp setAction:@selector(threadChanged:)];
    [_threadPopUp addItemWithTitle:@"All threads"];
    [_threadPopUp setAutoresizingMask:NSViewMinYMargin];
    [content addSubview:_threadPopUp];

    _costPopUp = [[NSPopUpButton alloc] initWithFrame:
                  NSMakeRect(threadX + 230 + METRICS_SPACE_8, y, 210, kRowHeight)
                                            pullsDown:NO];
    [_costPopUp addItemWithTitle:@"Memory held at the peak"];
    [_costPopUp addItemWithTitle:@"Memory never freed"];
    [_costPopUp addItemWithTitle:@"Number of allocations"];
    [_costPopUp addItemWithTitle:@"Short lived allocations"];
    [_costPopUp setTarget:self];
    [_costPopUp setAction:@selector(memoryCostChanged:)];
    [_costPopUp setAutoresizingMask:NSViewMinYMargin];
    [_costPopUp setHidden:YES];
    [content addSubview:_costPopUp];

    /* What was recorded. */
    y -= METRICS_SPACE_8 + 18;
    _headerLabel = [self labelWithString:@"No profile yet. Press Record to "
                                          @"measure a program."
                                   frame:NSMakeRect(margin, y, width - 160, 18)
                               alignment:NSLeftTextAlignment];
    [_headerLabel setFont:METRICS_FONT_SYSTEM_BOLD_11];
    [_headerLabel setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [content addSubview:_headerLabel];

    _matchedLabel = [self labelWithString:@""
                                    frame:NSMakeRect(kWindowWidth - margin - 160,
                                                     y, 160, 18)
                                alignment:NSRightTextAlignment];
    [_matchedLabel setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [content addSubview:_matchedLabel];

    /* Cost over time. */
    y -= METRICS_SPACE_8 + kTimelineHeight;
    _timeline = [[PRTimelineView alloc] initWithFrame:
                 NSMakeRect(margin, y, width, kTimelineHeight)];
    [_timeline setDelegate:self];
    [_timeline setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [content addSubview:_timeline];

    /* Status line at the bottom, tabs in between. */
    CGFloat statusY = METRICS_CONTENT_BOTTOM_MARGIN;
    _statusLabel = [self labelWithString:@"Ready."
                                   frame:NSMakeRect(margin, statusY, width, 18)
                               alignment:NSLeftTextAlignment];
    [_statusLabel setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    [content addSubview:_statusLabel];

    CGFloat tabsTop = y - METRICS_SPACE_8;
    CGFloat tabsBottom = statusY + 18 + METRICS_SPACE_8;
    _tabView = [[NSTabView alloc] initWithFrame:
                NSMakeRect(margin, tabsBottom, width, tabsTop - tabsBottom)];
    [_tabView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [content addSubview:_tabView];

    [self buildFlameTab];
    [self buildTreeTabs];
    [self buildFlatTab];
    [self buildSummaryTab];
}

- (NSView *)addTabWithLabel:(NSString *)label
{
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:label];
    [item setLabel:label];

    NSRect contentRect = [_tabView contentRect];
    NSView *view = [[NSView alloc] initWithFrame:
                    NSMakeRect(0, 0, NSWidth(contentRect), NSHeight(contentRect))];
    [view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [item setView:view];
    [_tabView addTabViewItem:item];
    return view;
}

- (void)buildFlameTab
{
    NSView *view = [self addTabWithLabel:@"Flame Graph"];
    CGFloat width = NSWidth([view bounds]);
    CGFloat y = NSHeight([view bounds]) - METRICS_SPACE_8 - kRowHeight;

    _callersRadio = [self radioWithTitle:@"Callers at the top"
                                   frame:NSMakeRect(METRICS_SPACE_8, y, 150,
                                                    METRICS_RADIO_BUTTON_SIZE)];
    [_callersRadio setState:NSOnState];
    [view addSubview:_callersRadio];

    _hotFramesRadio = [self radioWithTitle:@"Hot frames at the top"
                                     frame:NSMakeRect(METRICS_SPACE_8 + 150, y,
                                                      170,
                                                      METRICS_RADIO_BUTTON_SIZE)];
    [view addSubview:_hotFramesRadio];

    NSButton *reset = [self buttonWithTitle:@"Whole Profile"
                                     action:@selector(resetZoom:)
                                      frame:NSMakeRect(336, y + 1, 120,
                                                       METRICS_BUTTON_HEIGHT)];
    [reset setAutoresizingMask:NSViewMinYMargin];
    [view addSubview:reset];

    _zoomLabel = [self labelWithString:@"Click a frame to zoom into it, right "
                                        @"click to leave it again."
                                 frame:NSMakeRect(468, y, width - 476, 18)
                             alignment:NSLeftTextAlignment];
    [_zoomLabel setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [view addSubview:_zoomLabel];

    _flameScroll = [self scrollViewWithFrame:
                    NSMakeRect(0, 0, width, y - METRICS_SPACE_8)];
    [_flameScroll setHasHorizontalScroller:NO];
    _flameGraph = [[PRFlameGraphView alloc] initWithFrame:
                   [[_flameScroll contentView] bounds]];
    [_flameGraph setDelegate:self];
    [_flameScroll setDocumentView:_flameGraph];
    [view addSubview:_flameScroll];

    /* The graph is as tall as the tree is deep, so it has to be resized
       whenever the visible area changes. */
    [[_flameScroll contentView] setPostsFrameChangedNotifications:YES];
    [[NSNotificationCenter defaultCenter]
     addObserver:self
        selector:@selector(flameScrollResized:)
            name:NSViewFrameDidChangeNotification
          object:[_flameScroll contentView]];
}

- (void)buildTreeTabs
{
    NSView *topDown = [self addTabWithLabel:@"Top Down"];
    NSScrollView *topScroll = [self scrollViewWithFrame:[topDown bounds]];
    _topDownOutline = [[NSOutlineView alloc] initWithFrame:
                       [[topScroll contentView] bounds]];
    [_topDownController configureOutlineView:_topDownOutline];
    [topScroll setDocumentView:_topDownOutline];
    [topDown addSubview:topScroll];

    NSView *bottomUp = [self addTabWithLabel:@"Bottom Up"];
    NSScrollView *bottomScroll = [self scrollViewWithFrame:[bottomUp bounds]];
    _bottomUpOutline = [[NSOutlineView alloc] initWithFrame:
                        [[bottomScroll contentView] bounds]];
    [_bottomUpController configureOutlineView:_bottomUpOutline];
    [bottomScroll setDocumentView:_bottomUpOutline];
    [bottomUp addSubview:bottomScroll];
}

- (void)buildFlatTab
{
    NSView *view = [self addTabWithLabel:@"Functions"];
    CGFloat width = NSWidth([view bounds]);
    CGFloat y = NSHeight([view bounds]) - METRICS_SPACE_8 - kRowHeight;

    [view addSubview:[self labelWithString:@"Add up by:"
                                     frame:NSMakeRect(METRICS_SPACE_8, y, 70, kRowHeight)
                                 alignment:NSLeftTextAlignment]];

    _groupingPopUp = [[NSPopUpButton alloc] initWithFrame:
                      NSMakeRect(82, y, 220, kRowHeight) pullsDown:NO];
    [_groupingPopUp addItemWithTitle:@"Function"];
    [_groupingPopUp addItemWithTitle:@"Objective-C class"];
    [_groupingPopUp addItemWithTitle:@"Binary"];
    [_groupingPopUp addItemWithTitle:@"Thread"];
    [_groupingPopUp setTarget:self];
    [_groupingPopUp setAction:@selector(groupingChanged:)];
    [_groupingPopUp setAutoresizingMask:NSViewMinYMargin];
    [view addSubview:_groupingPopUp];

    NSScrollView *scroll = [self scrollViewWithFrame:
                            NSMakeRect(0, 0, width, y - METRICS_SPACE_8)];
    _flatTable = [[NSTableView alloc] initWithFrame:[[scroll contentView] bounds]];
    [_flatController configureTableView:_flatTable];
    [scroll setDocumentView:_flatTable];
    [view addSubview:scroll];
}

- (void)buildSummaryTab
{
    NSView *view = [self addTabWithLabel:@"Summary"];
    NSScrollView *scroll = [self scrollViewWithFrame:[view bounds]];
    [scroll setHasHorizontalScroller:NO];

    _summaryView = [[NSTextView alloc] initWithFrame:
                    [[scroll contentView] bounds]];
    [_summaryView setEditable:NO];
    [_summaryView setRichText:NO];
    [_summaryView setFont:[NSFont userFixedPitchFontOfSize:11]];
    [_summaryView setMinSize:NSMakeSize(0, 0)];
    [_summaryView setMaxSize:NSMakeSize(FLT_MAX, FLT_MAX)];
    [_summaryView setVerticallyResizable:YES];
    [_summaryView setHorizontallyResizable:NO];
    [[_summaryView textContainer] setWidthTracksTextView:YES];
    [scroll setDocumentView:_summaryView];
    [view addSubview:scroll];
}

/* Recording */

- (void)startRecording:(id)sender
{
    (void)sender;
    PRRecordPanelController *panel = [[PRRecordPanelController alloc] init];
    PRRecordRequest *request = [panel runModal];
    if (request == nil)
        return;

    Class recorderClass = [PRRecorderFactory recorderClassForMode:[request mode]];
    _recorder = [[recorderClass alloc] init];
    [_recorder setDelegate:self];

    NSError *error = nil;
    if (![_recorder startWithRequest:request error:&error]) {
        _recorder = nil;
        [self showError:error];
        return;
    }

    [_recordButton setEnabled:NO];
    [_stopButton setEnabled:YES];
    [_headerLabel setStringValue:[NSString stringWithFormat:
                                  @"Recording %@ with %@...",
                                  [request targetName],
                                  [recorderClass toolName]]];
    [_statusLabel setStringValue:
     [request duration] > 0 ?
     [NSString stringWithFormat:@"Recording for %.0f seconds. Use the program "
      @"the way that makes it slow.", [request duration]] :
     @"Recording. Use the program the way that makes it slow, then press Stop."];
}

- (void)stopRecording:(id)sender
{
    (void)sender;
    [_stopButton setEnabled:NO];
    [_recorder stopRecording];
}

- (void)stopEverything
{
    /* The sampling tool runs as root and would keep going after the window
       is gone, so quitting has to take it down. */
    [_recorder cancel];
    _recorder = nil;
}

- (void)showError:(NSError *)error
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"The profile could not be recorded"];
    [alert setInformativeText:error ? [error localizedDescription] :
     @"The profiling tool stopped without saying why."];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)recorder:(PRRecorder *)recorder didReportStatus:(NSString *)status
{
    (void)recorder;
    [_statusLabel setStringValue:status];
}

- (void)recorder:(PRRecorder *)recorder
    didFinishWithProfile:(PRProfile *)profile
                   error:(NSError *)error
{
    (void)recorder;
    [_recordButton setEnabled:YES];
    [_stopButton setEnabled:NO];

    if (profile == nil) {
        [_headerLabel setStringValue:@"The recording failed."];
        [_statusLabel setStringValue:@"Ready."];
        [self showError:error];
        return;
    }

    [self showProfile:profile];
}

- (void)memoryCostChanged:(id)sender
{
    (void)sender;
    if (_recorder == nil)
        return;
    if ([_recorder reanalyzeWithMemoryCost:
         (PRMemoryCost)[_costPopUp indexOfSelectedItem]])
        [_statusLabel setStringValue:@"Reading the recording again..."];
}

/* Showing a profile */

- (NSUInteger)frequency
{
    return [[_recorder request] frequency] > 0 ?
        [[_recorder request] frequency] : 999;
}

- (void)showProfile:(PRProfile *)profile
{
    _profile = profile;
    _range = PRTimeRangeAll();
    _thread = PR_ALL_THREADS;

    PRCostUnit unit = [profile costUnit];
    NSUInteger frequency = [self frequency];
    [_flameGraph setCostUnit:unit];
    [_flameGraph setFrequency:frequency];
    [_timeline setCostUnit:unit];
    [_timeline setFrequency:frequency];
    [_topDownController setCostUnit:unit];
    [_topDownController setFrequency:frequency];
    [_bottomUpController setCostUnit:unit];
    [_bottomUpController setFrequency:frequency];
    [_flatController setCostUnit:unit];
    [_flatController setFrequency:frequency];
    [_costPopUp setHidden:unit == PRCostUnitSamples];

    [self rebuildThreadPopUp];

    if ([profile memoryTimeline] != nil)
        [_timeline setCurve:[profile memoryTimeline] caption:@"Heap in use"];
    else
        [_timeline setBuckets:[profile timelineWithBucketCount:240]
                    startTime:[profile startTime]
                      endTime:[profile endTime]];

    [_summaryView setString:[profile summaryText] ? [profile summaryText] : @""];
    [self reloadViews];

    NSString *name = [profile title] ? [profile title] : @"Profile";
    NSString *cost = [PRAppearance stringForWeight:[profile totalWeight]
                                              unit:unit
                                         frequency:frequency];
    NSString *headline;

    unsigned long stacks = (unsigned long)[profile sampleCount];
    NSString *paths = stacks == 1 ? @"one call path" :
        [NSString stringWithFormat:@"%lu call paths", stacks];

    switch (unit) {
        case PRCostUnitBytes:
            headline = [NSString stringWithFormat:@"%@ - %@ on %@",
                        name, cost, paths];
            break;
        case PRCostUnitAllocations:
            headline = [NSString stringWithFormat:
                        @"%@ - %@ allocation calls on %@", name, cost, paths];
            break;
        case PRCostUnitSamples:
        default:
            headline = [NSString stringWithFormat:
                        @"%@ - %@ of CPU time in %.0f samples on %@",
                        name, cost, [profile totalWeight], paths];
            break;
    }
    [_headerLabel setStringValue:headline];
    [_statusLabel setStringValue:@"Point at a frame to see what it cost. "
                                 @"Drag across the graph above to look at one "
                                 @"stretch of the recording only."];
}

- (void)rebuildThreadPopUp
{
    [_threadPopUp removeAllItems];
    [_threadPopUp addItemWithTitle:@"All threads"];
    [[_threadPopUp lastItem] setTag:PR_ALL_THREADS];

    for (NSNumber *thread in [_profile threads]) {
        int32_t identifier = [thread intValue];
        NSString *name = [_profile nameForThread:identifier];
        double weight = [_profile weightOfThread:identifier];
        NSString *title = [NSString stringWithFormat:@"%@ (%d) - %@",
                           name ? name : @"thread", identifier,
                           [PRAppearance percentOf:weight
                                             total:[_profile totalWeight]]];
        [_threadPopUp addItemWithTitle:title];
        [[_threadPopUp lastItem] setTag:(NSInteger)identifier];
    }
    /* Threads make no sense for allocation stacks, which carry none. */
    [_threadPopUp setEnabled:[_profile costUnit] == PRCostUnitSamples];
}

- (BOOL)showsHotFramesAtTop
{
    return [_hotFramesRadio state] == NSOnState;
}

- (void)reloadViews
{
    if (_profile == nil)
        return;

    PRCallNode *flameRoot = [_profile callTreeInverted:[self showsHotFramesAtTop]
                                                 range:_range
                                                thread:_thread];
    [_flameGraph setRoot:flameRoot];
    [self updateFlameGraphSize];
    [self updateMatchedLabel];

    [_topDownController setRoot:[_profile callTreeInverted:NO
                                                     range:_range
                                                    thread:_thread]
                  inOutlineView:_topDownOutline];
    [_bottomUpController setRoot:[_profile callTreeInverted:YES
                                                      range:_range
                                                     thread:_thread]
                   inOutlineView:_bottomUpOutline];
    [self groupingChanged:nil];
    [self updateZoomLabel];
}

- (void)groupingChanged:(id)sender
{
    (void)sender;
    if (_profile == nil)
        return;

    PRGrouping grouping = (PRGrouping)[_groupingPopUp indexOfSelectedItem];
    NSArray *rows = [_profile aggregateByGrouping:grouping
                                            range:_range
                                           thread:_thread];
    [_flatController setRows:rows
                       total:[_profile weightInRange:_range thread:_thread]
                 inTableView:_flatTable];
}

- (void)directionChanged:(id)sender
{
    if (sender == _callersRadio || sender == _hotFramesRadio) {
        [_callersRadio setState:sender == _callersRadio ? NSOnState : NSOffState];
        [_hotFramesRadio setState:sender == _hotFramesRadio ? NSOnState : NSOffState];
    }
    [self reloadViews];
}

- (void)threadChanged:(id)sender
{
    (void)sender;
    _thread = (int32_t)[[_threadPopUp selectedItem] tag];
    [self reloadViews];
}

- (void)resetZoom:(id)sender
{
    (void)sender;
    [_flameGraph resetZoom];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
    if ([notification object] == _searchField)
        [self searchChanged:_searchField];
}

- (void)searchChanged:(id)sender
{
    (void)sender;
    [_flameGraph setSearchString:[_searchField stringValue]];
    [self updateMatchedLabel];
}

- (void)updateMatchedLabel
{
    if ([[_searchField stringValue] length] == 0 || _profile == nil) {
        [_matchedLabel setStringValue:@""];
        return;
    }

    /* Drawing computes which frames match, so ask the view for the result. */
    [_flameGraph display];
    double total = [_profile weightInRange:_range thread:_thread];
    [_matchedLabel setStringValue:[NSString stringWithFormat:@"%@ matched",
                                   [PRAppearance percentOf:[_flameGraph matchedWeight]
                                                     total:total]]];
}

- (void)updateFlameGraphSize
{
    NSSize visible = [[_flameScroll contentView] bounds].size;
    CGFloat height = [_flameGraph requiredHeight];
    if (height < visible.height)
        height = visible.height;
    [_flameGraph setFrameSize:NSMakeSize(visible.width, height)];
    [_flameGraph setNeedsDisplay:YES];
}

- (void)flameScrollResized:(NSNotification *)notification
{
    (void)notification;
    [self updateFlameGraphSize];
}

- (void)updateZoomLabel
{
    PRCallNode *node = [_flameGraph zoomNode];
    if (node == nil || [node parent] == nil) {
        [_zoomLabel setStringValue:@"Click a frame to zoom into it, right "
                                    @"click to leave it again."];
        return;
    }

    /* Only the last few callers fit, and they are the ones that say where
       in the program this is. */
    NSMutableArray *path = [NSMutableArray array];
    for (PRCallNode *step = node; step != nil && [path count] < 3;
         step = [step parent])
        if ([step symbol] != nil)
            [path insertObject:[[step symbol] displayName] atIndex:0];

    BOOL shortened = [node parent] != nil &&
                     [[[node parent] parent] parent] != nil;
    [_zoomLabel setStringValue:[NSString stringWithFormat:@"Showing %@%@",
                                shortened ? @"... > " : @"",
                                [path componentsJoinedByString:@" > "]]];
}

/* View delegates */

- (void)flameGraphView:(PRFlameGraphView *)view didHoverNode:(PRCallNode *)node
{
    (void)view;
    if (node == nil) {
        [_statusLabel setStringValue:@""];
        return;
    }
    [_statusLabel setStringValue:[_flameGraph describeNode:node]];
}

- (void)flameGraphView:(PRFlameGraphView *)view didZoomToNode:(PRCallNode *)node
{
    (void)view;
    (void)node;
    [self updateFlameGraphSize];
    [self updateZoomLabel];
}

- (void)timelineView:(PRTimelineView *)view didSelectRange:(PRTimeRange)range
{
    (void)view;
    _range = range;
    [self reloadViews];

    if (PRTimeRangeIsAll(range)) {
        [_statusLabel setStringValue:@"Showing the whole recording."];
        return;
    }
    [_statusLabel setStringValue:[NSString stringWithFormat:
                                  @"Showing %.2f s to %.2f s of the recording.",
                                  range.start - [_profile startTime],
                                  range.end - [_profile startTime]]];
}

/* Keeping a profile */

- (void)openFoldedStacks:(id)sender
{
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setTitle:@"Open Folded Stacks"];
    [panel setAllowsMultipleSelection:NO];
    if ([panel runModal] != NSOKButton || [[panel URLs] count] == 0)
        return;

    [self openProfileAtPath:[[[panel URLs] objectAtIndex:0] path]];
}

- (BOOL)openProfileAtPath:(NSString *)path
{
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (text == nil) {
        [self showError:[NSError errorWithDomain:PRErrorDomain code:2
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                    @"The file could not be read."}]];
        return NO;
    }

    PRProfile *profile = [[PRProfile alloc] init];
    [profile setTitle:[path lastPathComponent]];
    [profile setCommand:path];
    [profile setCostUnit:PRCostUnitSamples];
    [profile setSummaryText:[NSString stringWithFormat:
                             @"Folded stacks read from\n%@\n", path]];
    PRFoldedStackParser *parser = [[PRFoldedStackParser alloc]
                                   initWithProfile:profile];
    [parser parseString:text];

    if ([profile sampleCount] == 0) {
        [self showError:[NSError errorWithDomain:PRErrorDomain code:3
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                    @"The file holds no stacks."}]];
        return NO;
    }

    _recorder = nil;
    [self showProfile:profile];
    return YES;
}

- (void)exportFoldedStacks:(id)sender
{
    (void)sender;
    if (_profile == nil)
        return;

    NSSavePanel *panel = [NSSavePanel savePanel];
    [panel setTitle:@"Save Folded Stacks"];
    [panel setNameFieldStringValue:[NSString stringWithFormat:@"%@.folded",
                                    [_profile title] ? [_profile title] : @"profile"]];
    if ([panel runModal] != NSOKButton)
        return;

    NSError *error = nil;
    if (![_profile writeFoldedStacksToPath:[[panel URL] path] error:&error])
        [self showError:error];
    else
        [_statusLabel setStringValue:[NSString stringWithFormat:@"Saved %@.",
                                      [[panel URL] path]]];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    if ([item action] == @selector(exportFoldedStacks:))
        return _profile != nil;
    if ([item action] == @selector(stopRecording:))
        return [_recorder isRecording];
    return YES;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
