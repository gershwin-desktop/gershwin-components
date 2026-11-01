/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRObjectCensusController.h"
#import "PRCensusClient.h"
#import "PRCensus.h"
#import "AppearanceMetrics.h"

static const CGFloat kWindowWidth = 720.0;
static const CGFloat kWindowHeight = 560.0;
static const CGFloat kRowHeight = 22.0;

@implementation PRObjectCensusController

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
    [window setTitle:@"Objects in Use"];
    [window setMinSize:NSMakeSize(560, 400)];

    self = [super initWithWindow:window];
    if (self == nil)
        return nil;

    _sortKey = @"change";
    [self buildInterface];
    [window center];
    return self;
}

/* Small helpers */

- (NSTextField *)labelWithString:(NSString *)string frame:(NSRect)frame
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    [label setStringValue:string];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setBordered:NO];
    [label setDrawsBackground:NO];
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

- (NSTableColumn *)columnWithIdentifier:(NSString *)identifier
                                  title:(NSString *)title
                                  width:(CGFloat)width
                                aligned:(NSTextAlignment)alignment
{
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
    [[column headerCell] setStringValue:title];
    [column setWidth:width];
    [column setMinWidth:50];
    [column setEditable:NO];
    [[column dataCell] setAlignment:alignment];
    [[column dataCell] setFont:[NSFont systemFontOfSize:11]];
    return column;
}

/* Layout */

- (void)buildInterface
{
    NSView *content = [[self window] contentView];
    CGFloat margin = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat width = kWindowWidth - 2 * margin;
    CGFloat y = kWindowHeight - METRICS_CONTENT_TOP_MARGIN - kRowHeight;

    [content addSubview:[self labelWithString:@"Program:"
                                        frame:NSMakeRect(margin, y, 60,
                                                         kRowHeight)]];

    CGFloat buttonsWidth = 3 * 90 + 2 * METRICS_BUTTON_HORIZ_INTERSPACE;
    _programField = [[NSTextField alloc] initWithFrame:
                     NSMakeRect(margin + 64, y,
                                width - 64 - buttonsWidth - METRICS_SPACE_8,
                                kRowHeight)];
    [[_programField cell] setPlaceholderString:
     @"The program to start and watch"];
    [_programField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [content addSubview:_programField];

    CGFloat buttonX = kWindowWidth - margin - buttonsWidth;
    NSButton *choose = [self buttonWithTitle:@"Choose..."
                                      action:@selector(chooseProgram:)
                                       frame:NSMakeRect(buttonX, y, 90,
                                                        METRICS_BUTTON_HEIGHT)];
    [choose setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [content addSubview:choose];

    buttonX += 90 + METRICS_BUTTON_HORIZ_INTERSPACE;
    _startButton = [self buttonWithTitle:@"Watch"
                                  action:@selector(startWatching:)
                                   frame:NSMakeRect(buttonX, y, 90,
                                                    METRICS_BUTTON_HEIGHT)];
    [_startButton setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [content addSubview:_startButton];

    buttonX += 90 + METRICS_BUTTON_HORIZ_INTERSPACE;
    _stopButton = [self buttonWithTitle:@"Stop"
                                 action:@selector(stopWatching:)
                                  frame:NSMakeRect(buttonX, y, 90,
                                                   METRICS_BUTTON_HEIGHT)];
    [_stopButton setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [_stopButton setEnabled:NO];
    [content addSubview:_stopButton];

    /* What the numbers are measured against, and what stands out. */
    y -= METRICS_SPACE_8 + kRowHeight;
    _markButton = [self buttonWithTitle:@"Mark This Moment"
                                 action:@selector(markMoment:)
                                  frame:NSMakeRect(margin, y, 160,
                                                   METRICS_BUTTON_HEIGHT)];
    [_markButton setAutoresizingMask:NSViewMinYMargin];
    [_markButton setEnabled:NO];
    [content addSubview:_markButton];

    CGFloat searchWidth = 220;
    _searchField = [[NSSearchField alloc] initWithFrame:
                    NSMakeRect(kWindowWidth - margin - searchWidth, y,
                               searchWidth, kRowHeight)];
    [_searchField setTarget:self];
    [_searchField setAction:@selector(searchChanged:)];
    [[_searchField cell] setSendsWholeSearchString:NO];
    [[_searchField cell] setSendsSearchStringImmediately:YES];
    [[_searchField cell] setPlaceholderString:@"Find a class"];
    [_searchField setDelegate:self];
    [_searchField setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [content addSubview:_searchField];

    y -= METRICS_SPACE_8 + 18;
    _summaryLabel = [self labelWithString:
                     @"Start a program to see which of its classes grow."
                                    frame:NSMakeRect(margin, y, width, 18)];
    [_summaryLabel setFont:METRICS_FONT_SYSTEM_BOLD_11];
    [_summaryLabel setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [content addSubview:_summaryLabel];

    CGFloat statusY = METRICS_CONTENT_BOTTOM_MARGIN;
    _statusLabel = [self labelWithString:@"Ready."
                                   frame:NSMakeRect(margin, statusY, width, 18)];
    [_statusLabel setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    [content addSubview:_statusLabel];

    CGFloat tableTop = y - METRICS_SPACE_8;
    CGFloat tableBottom = statusY + 18 + METRICS_SPACE_8;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:
                            NSMakeRect(margin, tableBottom, width,
                                       tableTop - tableBottom)];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    [scroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    _table = [[NSTableView alloc] initWithFrame:[[scroll contentView] bounds]];
    [_table addTableColumn:[self columnWithIdentifier:@"change"
                                                title:@"Since the mark"
                                                width:110
                                              aligned:NSRightTextAlignment]];
    [_table addTableColumn:[self columnWithIdentifier:@"live"
                                                title:@"Alive"
                                                width:80
                                              aligned:NSRightTextAlignment]];
    [_table addTableColumn:[self columnWithIdentifier:@"peak"
                                                title:@"Most at once"
                                                width:100
                                              aligned:NSRightTextAlignment]];
    [_table addTableColumn:[self columnWithIdentifier:@"total"
                                                title:@"Ever made"
                                                width:100
                                              aligned:NSRightTextAlignment]];
    [_table addTableColumn:[self columnWithIdentifier:@"className"
                                                title:@"Class"
                                                width:240
                                              aligned:NSLeftTextAlignment]];
    [_table setDataSource:self];
    [_table setDelegate:self];
    [_table setRowHeight:18];
    [_table setUsesAlternatingRowBackgroundColors:YES];
    [scroll setDocumentView:_table];
    [content addSubview:scroll];
}

/* Watching */

- (void)chooseProgram:(id)sender
{
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:NO];
    [panel setAllowsMultipleSelection:NO];
    [panel setTitle:@"Choose a program to watch"];

    if ([panel runModal] != NSOKButton || [[panel URLs] count] == 0)
        return;
    [_programField setStringValue:[[[panel URLs] objectAtIndex:0] path]];
}

- (void)startWatching:(id)sender
{
    (void)sender;
    NSString *program = [[_programField stringValue]
                         stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceCharacterSet]];
    if ([program length] == 0) {
        [_statusLabel setStringValue:@"Name a program to watch first."];
        return;
    }

    /* A program bundle is named by its directory, but what runs is the
       executable inside it. */
    if ([[program pathExtension] isEqualToString:@"app"])
        program = [program stringByAppendingPathComponent:
                   [[program lastPathComponent] stringByDeletingPathExtension]];

    _client = [[PRCensusClient alloc] init];
    NSError *error = nil;
    if (![_client startProgram:program arguments:@[] error:&error]) {
        _client = nil;
        [self showError:error];
        return;
    }

    _baseline = nil;
    _current = nil;
    _rows = nil;
    [_table reloadData];

    [_startButton setEnabled:NO];
    [_stopButton setEnabled:YES];
    [_markButton setEnabled:YES];
    [_summaryLabel setStringValue:[NSString stringWithFormat:
                                   @"Watching %@ (process %d)",
                                   [program lastPathComponent],
                                   [_client processIdentifier]]];
    [_statusLabel setStringValue:@"Waiting for the program to answer..."];

    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                              target:self
                                            selector:@selector(refresh:)
                                            userInfo:nil
                                             repeats:YES];
}

- (void)stopWatching:(id)sender
{
    (void)sender;
    [_timer invalidate];
    _timer = nil;
    [_client stop];
    _client = nil;

    [_startButton setEnabled:YES];
    [_stopButton setEnabled:NO];
    [_statusLabel setStringValue:@"The program was stopped. The last count "
                                 @"stays on screen."];
}

- (void)stopEverything
{
    [_timer invalidate];
    _timer = nil;
    [_client stop];
    _client = nil;
}

- (void)showError:(NSError *)error
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"The program cannot be watched"];
    [alert setInformativeText:error ? [error localizedDescription] :
     @"The program did not say why."];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)markMoment:(id)sender
{
    (void)sender;
    if (_current == nil)
        return;
    _baseline = _current;
    [_statusLabel setStringValue:@"Counting from this moment. What keeps "
                                 @"growing from here is what is not let go."];
    [self rebuildRows];
}

- (void)refresh:(NSTimer *)timer
{
    (void)timer;

    if (![_client isRunning]) {
        [self stopWatching:nil];
        [_statusLabel setStringValue:@"The program has ended."];
        return;
    }

    NSError *error = nil;
    PRCensusSnapshot *snapshot = [_client takeSnapshotWithError:&error];
    if (snapshot == nil) {
        [_statusLabel setStringValue:[error localizedDescription]];
        return;
    }

    _current = snapshot;
    if (_baseline == nil) {
        _baseline = snapshot;
        [_statusLabel setStringValue:
         @"Counting every second. Use the program the way that makes it grow, "
         @"then mark a moment and watch what keeps climbing."];
    }
    [self rebuildRows];
}

/* Rows */

- (void)rebuildRows
{
    NSArray *compared = [_current rowsComparedWith:_baseline];
    NSString *filter = [_searchField stringValue];

    if ([filter length] > 0) {
        NSMutableArray *kept = [NSMutableArray array];
        for (PRCensusRow *row in compared)
            if ([[row className] rangeOfString:filter
                                       options:NSCaseInsensitiveSearch].location
                != NSNotFound)
                [kept addObject:row];
        compared = kept;
    }

    _rows = [self sortedRows:compared];
    [_table reloadData];
    [self updateSummary];
}

- (NSArray *)sortedRows:(NSArray *)rows
{
    NSString *key = _sortKey;
    return [rows sortedArrayUsingComparator:
            ^NSComparisonResult(PRCensusRow *a, PRCensusRow *b) {
        if ([key isEqualToString:@"className"])
            return [[a className] localizedCaseInsensitiveCompare:[b className]];

        NSInteger left, right;
        if ([key isEqualToString:@"live"]) {
            left = [a live]; right = [b live];
        } else if ([key isEqualToString:@"peak"]) {
            left = [a peak]; right = [b peak];
        } else if ([key isEqualToString:@"total"]) {
            left = [a total]; right = [b total];
        } else {
            left = [a change]; right = [b change];
        }
        if (left > right) return NSOrderedAscending;
        if (left < right) return NSOrderedDescending;
        return [[a className] localizedCaseInsensitiveCompare:[b className]];
    }];
}

- (void)updateSummary
{
    if (_current == nil)
        return;

    NSInteger alive = [_current liveTotal];
    NSInteger grown = [_current liveTotal] - [_baseline liveTotal];
    NSTimeInterval since = [[_current takenAt] timeIntervalSinceDate:
                            [_baseline takenAt]];

    /* The class that grows fastest is the one worth looking at first. */
    PRCensusRow *worst = nil;
    for (PRCensusRow *row in [_current rowsComparedWith:_baseline]) {
        worst = row;
        break;
    }

    NSString *headline;
    if (worst != nil && [worst change] > 0)
        headline = [NSString stringWithFormat:
                    @"%ld objects alive, %ld more than %.0f seconds ago - "
                    @"%@ grew most, by %ld",
                    (long)alive, (long)grown, since, [worst className],
                    (long)[worst change]];
    else
        headline = [NSString stringWithFormat:
                    @"%ld objects alive, %ld since the mark - nothing is "
                    @"growing", (long)alive, (long)grown];
    [_summaryLabel setStringValue:headline];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
    if ([notification object] == _searchField)
        [self searchChanged:_searchField];
}

- (void)searchChanged:(id)sender
{
    (void)sender;
    if (_current != nil)
        [self rebuildRows];
}

/* Table */

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    (void)tableView;
    return (NSInteger)[_rows count];
}

- (id)tableView:(NSTableView *)tableView
objectValueForTableColumn:(NSTableColumn *)column
            row:(NSInteger)rowIndex
{
    (void)tableView;
    PRCensusRow *row = [_rows objectAtIndex:rowIndex];
    NSString *identifier = [column identifier];

    if ([identifier isEqualToString:@"className"])
        return [row className];
    if ([identifier isEqualToString:@"live"])
        return [NSString stringWithFormat:@"%ld", (long)[row live]];
    if ([identifier isEqualToString:@"peak"])
        return [NSString stringWithFormat:@"%ld", (long)[row peak]];
    if ([identifier isEqualToString:@"total"])
        return [NSString stringWithFormat:@"%ld", (long)[row total]];

    /* A plus sign says at a glance which way a class is going. */
    if ([row change] > 0)
        return [NSString stringWithFormat:@"+%ld", (long)[row change]];
    return [NSString stringWithFormat:@"%ld", (long)[row change]];
}

- (void)tableView:(NSTableView *)tableView
didClickTableColumn:(NSTableColumn *)column
{
    (void)tableView;
    _sortKey = [column identifier];
    if (_current != nil)
        [self rebuildRows];
}

@end
