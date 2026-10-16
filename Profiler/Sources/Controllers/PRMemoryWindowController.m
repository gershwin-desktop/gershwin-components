/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRFormat.h"
#import "PRMemoryWindowController.h"
#import "PRMemoryMap.h"
#import "PRMemoryMapReader.h"
#import "PRProcessMonitor.h"
#import "PRProcessInfo.h"
#import "PRAppearance.h"
#import "AppearanceMetrics.h"

static const CGFloat kWindowWidth = 980.0;
static const CGFloat kWindowHeight = 560.0;
static const CGFloat kRowHeight = 22.0;
static const CGFloat kListWidth = 260.0;

@implementation PRMemoryWindowController

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
    [window setTitle:@"Memory in Use"];
    [window setMinSize:NSMakeSize(820, 420)];

    self = [super initWithWindow:window];
    if (self == nil)
        return nil;

    _monitor = [[PRProcessMonitor alloc] init];
    _pid = 0;
    [self buildInterface];
    [window center];
    [self refresh:nil];

    /* Memory moves while one watches, and that movement is the point. */
    _timer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                              target:self
                                            selector:@selector(refresh:)
                                            userInfo:nil
                                             repeats:YES];
    return self;
}

- (void)stopEverything
{
    [_timer invalidate];
    _timer = nil;
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

- (NSTableColumn *)columnWithIdentifier:(NSString *)identifier
                                  title:(NSString *)title
                                  width:(CGFloat)width
                                aligned:(NSTextAlignment)alignment
{
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
    [[column headerCell] setStringValue:title];
    [column setWidth:width];
    [column setMinWidth:40];
    [column setEditable:NO];
    [[column dataCell] setAlignment:alignment];
    [[column dataCell] setFont:[NSFont systemFontOfSize:11]];
    return column;
}

- (NSScrollView *)scrollViewWithFrame:(NSRect)frame
{
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:frame];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    return scroll;
}

/* Layout */

- (void)buildInterface
{
    NSView *content = [[self window] contentView];
    CGFloat margin = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat width = kWindowWidth - 2 * margin;
    CGFloat y = kWindowHeight - METRICS_CONTENT_TOP_MARGIN - kRowHeight;

    _searchField = [[NSSearchField alloc] initWithFrame:
                    NSMakeRect(margin, y, kListWidth, kRowHeight)];
    [_searchField setTarget:self];
    [_searchField setAction:@selector(searchChanged:)];
    [[_searchField cell] setSendsWholeSearchString:NO];
    [[_searchField cell] setSendsSearchStringImmediately:YES];
    [[_searchField cell] setPlaceholderString:
     @"Search for a program by name or process id"];
    [_searchField setDelegate:self];
    [_searchField setAutoresizingMask:NSViewMinYMargin];
    [content addSubview:_searchField];

    CGFloat rightX = margin + kListWidth + METRICS_SPACE_8;
    [content addSubview:[self labelWithString:@"Add up by:"
                                        frame:NSMakeRect(rightX, y, 70,
                                                         kRowHeight)]];

    _groupingPopUp = [[NSPopUpButton alloc] initWithFrame:
                      NSMakeRect(rightX + 74, y, 220, kRowHeight)
                                             pullsDown:NO];
    [_groupingPopUp addItemWithTitle:@"What it is used for"];
    [_groupingPopUp addItemWithTitle:@"File or mapping"];
    [_groupingPopUp setTarget:self];
    [_groupingPopUp setAction:@selector(groupingChanged:)];
    [_groupingPopUp setAutoresizingMask:NSViewMinYMargin];
    [content addSubview:_groupingPopUp];

    y -= METRICS_SPACE_8 + 18;
    _summaryLabel = [self labelWithString:@"Choose a program to see where its "
                                           @"memory sits."
                                    frame:NSMakeRect(rightX, y,
                                                     kWindowWidth - margin -
                                                     rightX, 18)];
    [_summaryLabel setFont:METRICS_FONT_SYSTEM_BOLD_11];
    [_summaryLabel setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [content addSubview:_summaryLabel];

    CGFloat statusY = METRICS_CONTENT_BOTTOM_MARGIN;
    _statusLabel = [self labelWithString:@"" frame:NSMakeRect(margin, statusY,
                                                              width, 18)];
    [_statusLabel setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    [content addSubview:_statusLabel];

    CGFloat tablesTop = y - METRICS_SPACE_8;
    CGFloat tablesBottom = statusY + 18 + METRICS_SPACE_8;
    CGFloat listTop = kWindowHeight - METRICS_CONTENT_TOP_MARGIN - kRowHeight -
                      METRICS_SPACE_8;

    /* The list of programs keeps the full height: picking the program that
       is too big is the first half of the question. */
    NSScrollView *listScroll = [self scrollViewWithFrame:
                                NSMakeRect(margin, tablesBottom, kListWidth,
                                           listTop - tablesBottom)];
    [listScroll setAutoresizingMask:NSViewHeightSizable];
    _processTable = [[NSTableView alloc] initWithFrame:
                     [[listScroll contentView] bounds]];
    [_processTable addTableColumn:[self columnWithIdentifier:@"name"
                                                       title:@"Program"
                                                       width:120
                                                     aligned:NSLeftTextAlignment]];
    [_processTable addTableColumn:[self columnWithIdentifier:@"pid"
                                                       title:@"PID"
                                                       width:50
                                                     aligned:NSRightTextAlignment]];
    [_processTable addTableColumn:[self columnWithIdentifier:@"memory"
                                                       title:@"Memory"
                                                       width:75
                                                     aligned:NSRightTextAlignment]];
    [_processTable setDataSource:self];
    [_processTable setDelegate:self];
    [_processTable setRowHeight:18];
    [_processTable setUsesAlternatingRowBackgroundColors:YES];
    [listScroll setDocumentView:_processTable];
    [content addSubview:listScroll];

    NSScrollView *regionScroll = [self scrollViewWithFrame:
                                  NSMakeRect(rightX, tablesBottom,
                                             kWindowWidth - margin - rightX,
                                             tablesTop - tablesBottom)];
    [regionScroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    _regionTable = [[NSTableView alloc] initWithFrame:
                    [[regionScroll contentView] bounds]];
    [_regionTable addTableColumn:[self columnWithIdentifier:@"resident"
                                                      title:@"In RAM"
                                                      width:85
                                                    aligned:NSRightTextAlignment]];
    [_regionTable addTableColumn:[self columnWithIdentifier:@"share"
                                                      title:@"Share"
                                                      width:55
                                                    aligned:NSRightTextAlignment]];
    [_regionTable addTableColumn:[self columnWithIdentifier:@"private"
                                                      title:@"Its own"
                                                      width:85
                                                    aligned:NSRightTextAlignment]];
    [_regionTable addTableColumn:[self columnWithIdentifier:@"swap"
                                                      title:@"In swap"
                                                      width:70
                                                    aligned:NSRightTextAlignment]];
    [_regionTable addTableColumn:[self columnWithIdentifier:@"name"
                                                      title:@"Memory"
                                                      width:150
                                                    aligned:NSLeftTextAlignment]];
    [_regionTable addTableColumn:[self columnWithIdentifier:@"detail"
                                                      title:@"What it is"
                                                      width:200
                                                    aligned:NSLeftTextAlignment]];
    [_regionTable setDataSource:self];
    [_regionTable setDelegate:self];
    [_regionTable setRowHeight:18];
    [_regionTable setUsesAlternatingRowBackgroundColors:YES];
    [regionScroll setDocumentView:_regionTable];
    [content addSubview:regionScroll];
}

/* Reading */

- (void)refresh:(NSTimer *)timer
{
    (void)timer;

    _processes = [[_monitor processes] sortedArrayUsingComparator:
                  ^NSComparisonResult(PRProcessInfo *a, PRProcessInfo *b) {
        if ([a rssBytes] > [b rssBytes]) return NSOrderedAscending;
        if ([a rssBytes] < [b rssBytes]) return NSOrderedDescending;
        return [[a name] localizedCaseInsensitiveCompare:[b name]];
    }];
    [self applyFilter];
    [self readSelectedProcess];
}

- (void)applyFilter
{
    NSString *filter = [_searchField stringValue];
    NSInteger selected = [_processTable selectedRow];
    pid_t keep = _pid;

    if ([filter length] == 0) {
        _visibleProcesses = _processes;
    } else {
        NSMutableArray *kept = [NSMutableArray array];
        for (PRProcessInfo *process in _processes)
            if ([[process name] rangeOfString:filter
                                      options:NSCaseInsensitiveSearch].location
                != NSNotFound ||
                [[NSString stringWithFormat:@"%d", [process pid]]
                 hasPrefix:filter])
                [kept addObject:process];
        _visibleProcesses = kept;
    }

    [_processTable reloadData];

    /* The list is sorted by size and reordered while it is watched, so the
       program that was chosen has to be found again, not its row. */
    if (keep != 0) {
        NSUInteger index = 0;
        for (PRProcessInfo *process in _visibleProcesses) {
            if ([process pid] == keep) {
                [_processTable selectRowIndexes:
                 [NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
                return;
            }
            index++;
        }
    }
    if (selected >= 0 && selected < (NSInteger)[_visibleProcesses count])
        [_processTable selectRowIndexes:[NSIndexSet indexSetWithIndex:
                                         (NSUInteger)selected]
                   byExtendingSelection:NO];
}

- (void)readSelectedProcess
{
    NSInteger row = [_processTable selectedRow];
    if (row < 0 || row >= (NSInteger)[_visibleProcesses count]) {
        _map = nil;
        _rows = nil;
        [_regionTable reloadData];
        return;
    }

    PRProcessInfo *process = [_visibleProcesses objectAtIndex:row];
    _pid = [process pid];

    NSError *error = nil;
    PRMemoryMap *map = [PRMemoryMapReader mapForProcess:_pid error:&error];
    if (map == nil) {
        _map = nil;
        _rows = nil;
        [_regionTable reloadData];
        [_summaryLabel setStringValue:[NSString stringWithFormat:@"%@ (%d)",
                                       [process name], (int)_pid]];
        [_statusLabel setStringValue:[error localizedDescription]];
        return;
    }

    _map = map;
    [self rebuildRows];

    [_summaryLabel setStringValue:[NSString stringWithFormat:
                                   @"%@ (%d) - %@ in RAM, %@ of it its own%@",
                                   [process name], (int)_pid,
                                   [self bytes:[map resident]],
                                   [self bytes:[map privateBytes]],
                                   [map swap] > 0 ?
                                   [NSString stringWithFormat:@", %@ pushed out "
                                    @"to swap", [self bytes:[map swap]]] : @""]];

    if (![PRMemoryMapReader reportsResidentMemoryPerMapping])
        [_statusLabel setStringValue:
         @"This system reports only the memory a program claimed, not how "
         @"much of it is really in RAM."];
    else
        [_statusLabel setStringValue:
         @"\"Its own\" is what would be freed if the program ended; the rest "
         @"is shared with other programs."];
}

- (void)rebuildRows
{
    _rows = [_groupingPopUp indexOfSelectedItem] == 0 ?
        [_map regionsByKind] : [_map regionsByName];
    [_regionTable reloadData];
}

- (NSString *)bytes:(unsigned long long)value
{
    return [PRFormat stringForWeight:(double)value
                                unit:PRCostUnitBytes
                           frequency:0];
}

- (void)groupingChanged:(id)sender
{
    (void)sender;
    if (_map != nil)
        [self rebuildRows];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
    if ([notification object] == _searchField)
        [self searchChanged:_searchField];
}

- (void)searchChanged:(id)sender
{
    (void)sender;
    [self applyFilter];
}

/* Tables */

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    if (tableView == _processTable)
        return (NSInteger)[_visibleProcesses count];
    return (NSInteger)[_rows count];
}

- (id)tableView:(NSTableView *)tableView
objectValueForTableColumn:(NSTableColumn *)column
            row:(NSInteger)rowIndex
{
    NSString *identifier = [column identifier];

    if (tableView == _processTable) {
        PRProcessInfo *process = [_visibleProcesses objectAtIndex:rowIndex];
        if ([identifier isEqualToString:@"name"])
            return [process name];
        if ([identifier isEqualToString:@"pid"])
            return [NSString stringWithFormat:@"%d", [process pid]];
        return [self bytes:[process rssBytes]];
    }

    PRMemoryRegion *region = [_rows objectAtIndex:rowIndex];
    if ([identifier isEqualToString:@"resident"])
        return [self bytes:[region resident]];
    if ([identifier isEqualToString:@"share"])
        return [PRFormat percentOf:(double)[region resident]
                             total:(double)[_map resident]];
    if ([identifier isEqualToString:@"private"])
        return [self bytes:[region privateBytes]];
    if ([identifier isEqualToString:@"swap"])
        return [region swap] > 0 ? [self bytes:[region swap]] : @"";
    if ([identifier isEqualToString:@"name"])
        return [region name];

    /* Grouped by kind the detail says what the kind means, grouped by file
       it says which file, which is what one wants to know next. */
    if ([_groupingPopUp indexOfSelectedItem] == 0)
        return [region path];
    if ([region count] > 1)
        return [NSString stringWithFormat:@"%@ - %lu mappings",
                PRMemoryKindName([region kind]), (unsigned long)[region count]];
    return PRMemoryKindName([region kind]);
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    if ([notification object] == _processTable)
        [self readSelectedProcess];
}

@end
