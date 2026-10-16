/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRRecordPanelController.h"
#import "PRRecorderFactory.h"
#import "PRProcessMonitor.h"
#import "PRProcessInfo.h"
#import "PRLiveGraphView.h"
#import "AppearanceMetrics.h"

static const CGFloat kPanelWidth = 620.0;
static const CGFloat kPanelHeight = 566.0;
static const CGFloat kLabelWidth = 118.0;
static const CGFloat kRowHeight = 22.0;

@implementation PRRecordPanelController

- (id)init
{
    self = [super init];
    if (self == nil)
        return nil;
    _monitor = [[PRProcessMonitor alloc] init];
    [self buildPanel];
    return self;
}

/* Helpers */

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

/* Two buttons instead of an NSMatrix: each one is a widget of its own, so
   the interface can be driven and tested by name. */
- (NSButton *)radioWithTitle:(NSString *)title frame:(NSRect)frame
{
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    [button setButtonType:NSRadioButton];
    [button setTitle:title];
    [button setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [button setTarget:self];
    [button setAction:@selector(targetKindChanged:)];
    return button;
}

- (NSPopUpButton *)popUpWithTitles:(NSArray *)titles frame:(NSRect)frame
{
    NSPopUpButton *popUp = [[NSPopUpButton alloc] initWithFrame:frame
                                                       pullsDown:NO];
    for (NSString *title in titles)
        [popUp addItemWithTitle:title];
    [popUp setTarget:self];
    [popUp setAction:@selector(optionsChanged:)];
    return popUp;
}

- (NSBox *)boxWithTitle:(NSString *)title frame:(NSRect)frame
{
    NSBox *box = [[NSBox alloc] initWithFrame:frame];
    [box setTitle:title];
    [box setTitlePosition:NSAtTop];
    [box setBorderType:NSBezelBorder];
    [box setBoxType:NSBoxPrimary];
    return box;
}

/* Layout */

- (void)buildPanel
{
    NSRect frame = NSMakeRect(0, 0, kPanelWidth, kPanelHeight);
    _panel = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:NSTitledWindowMask
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    [_panel setTitle:@"Record a Profile"];
    NSView *content = [_panel contentView];

    CGFloat margin = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat contentWidth = kPanelWidth - 2 * margin;
    CGFloat y = kPanelHeight - METRICS_CONTENT_TOP_MARGIN;

    /* What to profile. */
    y -= METRICS_RADIO_BUTTON_SIZE;
    _attachRadio = [self radioWithTitle:@"Watch a running program"
                                  frame:NSMakeRect(margin, y, contentWidth / 2,
                                                   METRICS_RADIO_BUTTON_SIZE)];
    [_attachRadio setState:NSOnState];
    [content addSubview:_attachRadio];

    _launchRadio = [self radioWithTitle:@"Start a program"
                                  frame:NSMakeRect(margin + contentWidth / 2, y,
                                                   contentWidth / 2,
                                                   METRICS_RADIO_BUTTON_SIZE)];
    [content addSubview:_launchRadio];

    /* Running processes. */
    y -= METRICS_SPACE_8 + kRowHeight;
    _filterField = [[NSSearchField alloc] initWithFrame:
                    NSMakeRect(margin, y, contentWidth, kRowHeight)];
    [_filterField setTarget:self];
    [_filterField setAction:@selector(filterChanged:)];
    /* The list is narrowed down while the name is typed, so the search
       field sends its action on every keystroke instead of on Return. */
    [[_filterField cell] setSendsWholeSearchString:NO];
    [[_filterField cell] setSendsSearchStringImmediately:YES];
    [[_filterField cell] setPlaceholderString:@"Search for a program by name "
                                              @"or process id"];
    /* A theme may clear the field through the change notification instead
       of the field's own action, so both bring the whole list back. */
    [_filterField setDelegate:self];
    [content addSubview:_filterField];

    CGFloat tableHeight = 170;
    CGFloat graphWidth = 128;
    y -= METRICS_SPACE_8 + tableHeight;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:
                            NSMakeRect(margin, y,
                                       contentWidth - graphWidth - METRICS_SPACE_8,
                                       tableHeight)];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];

    _processTable = [[NSTableView alloc] initWithFrame:[[scroll contentView] bounds]];
    [self addColumn:@"name" title:@"Program" width:190 aligned:NSLeftTextAlignment];
    [self addColumn:@"pid" title:@"PID" width:54 aligned:NSRightTextAlignment];
    [self addColumn:@"cpu" title:@"CPU" width:54 aligned:NSRightTextAlignment];
    [self addColumn:@"memory" title:@"Memory" width:74 aligned:NSRightTextAlignment];
    [_processTable setDataSource:self];
    [_processTable setDelegate:self];
    [_processTable setRowHeight:18];
    [_processTable setUsesAlternatingRowBackgroundColors:YES];
    [scroll setDocumentView:_processTable];
    [content addSubview:scroll];

    _liveGraph = [[PRLiveGraphView alloc] initWithFrame:
                  NSMakeRect(kPanelWidth - margin - graphWidth, y,
                             graphWidth, tableHeight)];
    [_liveGraph setCaption:@"CPU %"];
    [_liveGraph setMaximum:100.0];
    [content addSubview:_liveGraph];

    /* Program to start. */
    y -= METRICS_SPACE_12 + kRowHeight;
    [content addSubview:[self labelWithString:@"Program:"
                                        frame:NSMakeRect(margin, y, kLabelWidth, kRowHeight)
                                    alignment:NSRightTextAlignment]];
    CGFloat chooseWidth = 96;
    _launchField = [[NSTextField alloc] initWithFrame:
                    NSMakeRect(margin + kLabelWidth + METRICS_SPACE_8, y,
                               contentWidth - kLabelWidth - chooseWidth - 2 * METRICS_SPACE_8,
                               kRowHeight)];
    [content addSubview:_launchField];

    NSButton *choose = [[NSButton alloc] initWithFrame:
                        NSMakeRect(kPanelWidth - margin - chooseWidth,
                                   y + 1, chooseWidth, METRICS_BUTTON_HEIGHT)];
    [choose setTitle:@"Choose..."];
    [choose setBezelStyle:NSRoundedBezelStyle];
    [choose setTarget:self];
    [choose setAction:@selector(chooseProgram:)];
    [content addSubview:choose];

    y -= METRICS_SPACE_8 + kRowHeight;
    [content addSubview:[self labelWithString:@"Arguments:"
                                        frame:NSMakeRect(margin, y, kLabelWidth, kRowHeight)
                                    alignment:NSRightTextAlignment]];
    _argumentsField = [[NSTextField alloc] initWithFrame:
                       NSMakeRect(margin + kLabelWidth + METRICS_SPACE_8, y,
                                  contentWidth - kLabelWidth - METRICS_SPACE_8,
                                  kRowHeight)];
    [content addSubview:_argumentsField];

    /* Options. */
    CGFloat boxHeight = 14 + 16 + 4 * kRowHeight + 3 * METRICS_SPACE_8 + 16;
    y -= METRICS_SPACE_12 + boxHeight;
    NSBox *options = [self boxWithTitle:@"Settings"
                                  frame:NSMakeRect(margin, y, contentWidth, boxHeight)];
    [content addSubview:options];

    NSView *boxContent = [options contentView];
    CGFloat boxWidth = NSWidth([boxContent bounds]);
    CGFloat innerWidth = boxWidth - 2 * METRICS_SPACE_16;
    CGFloat controlX = METRICS_SPACE_16 + kLabelWidth + METRICS_SPACE_8;
    CGFloat controlWidth = innerWidth - kLabelWidth - METRICS_SPACE_8;
    CGFloat by = NSHeight([boxContent bounds]) - 16 - kRowHeight;

    _modePopUp = [self popUpWithTitles:@[@"CPU time", @"Heap memory"]
                                 frame:NSMakeRect(controlX, by, controlWidth, kRowHeight)];
    [self addRowLabel:@"Measure:" y:by toView:boxContent];
    [boxContent addSubview:_modePopUp];

    by -= METRICS_SPACE_8 + kRowHeight;
    _frequencyPopUp = [self popUpWithTitles:@[@"99 samples per second",
                                              @"199 samples per second",
                                              @"499 samples per second",
                                              @"999 samples per second",
                                              @"1999 samples per second"]
                                      frame:NSMakeRect(controlX, by, controlWidth, kRowHeight)];
    [_frequencyPopUp selectItemAtIndex:3];
    [self addRowLabel:@"Sampling rate:" y:by toView:boxContent];
    [boxContent addSubview:_frequencyPopUp];

    by -= METRICS_SPACE_8 + kRowHeight;
    _callGraphPopUp = [self popUpWithTitles:@[@"DWARF debug information",
                                              @"Frame pointers",
                                              @"Processor branch records"]
                                      frame:NSMakeRect(controlX, by, controlWidth, kRowHeight)];
    [self addRowLabel:@"Call stacks from:" y:by toView:boxContent];
    [boxContent addSubview:_callGraphPopUp];

    _memoryCostPopUp = [self popUpWithTitles:@[@"Memory held at the peak",
                                               @"Memory never freed",
                                               @"Number of allocations",
                                               @"Short lived allocations"]
                                       frame:NSMakeRect(controlX, by, controlWidth, kRowHeight)];
    [boxContent addSubview:_memoryCostPopUp];

    by -= METRICS_SPACE_8 + kRowHeight;
    _durationCheck = [[NSButton alloc] initWithFrame:
                      NSMakeRect(METRICS_SPACE_16, by + 2, 150, 18)];
    [_durationCheck setButtonType:NSSwitchButton];
    [_durationCheck setTitle:@"Stop by itself after"];
    [_durationCheck setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [_durationCheck setTarget:self];
    [_durationCheck setAction:@selector(optionsChanged:)];
    [boxContent addSubview:_durationCheck];

    _durationField = [[NSTextField alloc] initWithFrame:
                      NSMakeRect(METRICS_SPACE_16 + 158, by, 60, kRowHeight)];
    [_durationField setStringValue:@"10"];
    [_durationField setAlignment:NSRightTextAlignment];
    [boxContent addSubview:_durationField];
    [boxContent addSubview:[self labelWithString:@"seconds"
                                           frame:NSMakeRect(METRICS_SPACE_16 + 224,
                                                            by, 80, kRowHeight)
                                       alignment:NSLeftTextAlignment]];

    /* Note and buttons. */
    CGFloat buttonY = METRICS_CONTENT_BOTTOM_MARGIN;
    CGFloat buttonWidth = METRICS_BUTTON_MIN_WIDTH;

    _recordButton = [[NSButton alloc] initWithFrame:
                     NSMakeRect(kPanelWidth - margin - buttonWidth, buttonY,
                                buttonWidth, METRICS_BUTTON_HEIGHT)];
    [_recordButton setTitle:@"Record"];
    [_recordButton setBezelStyle:NSRoundedBezelStyle];
    [_recordButton setKeyEquivalent:@"\r"];
    [_recordButton setTarget:self];
    [_recordButton setAction:@selector(startRecording:)];
    [content addSubview:_recordButton];

    NSButton *cancel = [[NSButton alloc] initWithFrame:
                        NSMakeRect(kPanelWidth - margin - 2 * buttonWidth -
                                   METRICS_BUTTON_HORIZ_INTERSPACE, buttonY,
                                   buttonWidth, METRICS_BUTTON_HEIGHT)];
    [cancel setTitle:@"Cancel"];
    [cancel setBezelStyle:NSRoundedBezelStyle];
    [cancel setKeyEquivalent:@"\033"];
    [cancel setTarget:self];
    [cancel setAction:@selector(cancel:)];
    [content addSubview:cancel];

    CGFloat noteHeight = y - buttonY - METRICS_BUTTON_HEIGHT - METRICS_SPACE_8;
    if (noteHeight < 32)
        noteHeight = 32;
    _noteField = [self labelWithString:@""
                                 frame:NSMakeRect(margin,
                                                  buttonY + METRICS_BUTTON_HEIGHT +
                                                  METRICS_SPACE_8,
                                                  contentWidth, noteHeight)
                             alignment:NSLeftTextAlignment];
    [_noteField setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [[_noteField cell] setWraps:YES];
    [content addSubview:_noteField];

    [self refreshProcesses:nil];
    [self targetKindChanged:nil];
    [self optionsChanged:nil];
}

- (void)addRowLabel:(NSString *)title y:(CGFloat)y toView:(NSView *)view
{
    [view addSubview:[self labelWithString:title
                                     frame:NSMakeRect(METRICS_SPACE_16, y,
                                                      kLabelWidth, kRowHeight)
                                 alignment:NSRightTextAlignment]];
}

- (void)addColumn:(NSString *)identifier
            title:(NSString *)title
            width:(CGFloat)width
          aligned:(NSTextAlignment)alignment
{
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
    [[column headerCell] setStringValue:title];
    [column setWidth:width];
    [column setEditable:NO];
    [[column dataCell] setAlignment:alignment];
    [[column dataCell] setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [_processTable addTableColumn:column];
}

/* Running the panel */

- (PRRecordRequest *)runModal
{
    _result = nil;
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                     target:self
                                                   selector:@selector(refreshProcesses:)
                                                   userInfo:nil
                                                    repeats:YES];
    [_panel center];
    [NSApp runModalForWindow:_panel];
    [_refreshTimer invalidate];
    _refreshTimer = nil;
    [_panel orderOut:nil];
    return _result;
}

- (void)cancel:(id)sender
{
    (void)sender;
    _result = nil;
    [NSApp stopModal];
}

- (BOOL)isAttachSelected
{
    return [_attachRadio state] == NSOnState;
}

- (PRProfileMode)selectedMode
{
    return [_modePopUp indexOfSelectedItem] == 0 ?
        PRProfileModeCPU : PRProfileModeMemory;
}

- (PRProcessInfo *)selectedProcess
{
    NSInteger row = [_processTable selectedRow];
    if (row < 0 || row >= (NSInteger)[_visibleProcesses count])
        return nil;
    return [_visibleProcesses objectAtIndex:row];
}

- (void)targetKindChanged:(id)sender
{
    if (sender == _attachRadio || sender == _launchRadio) {
        [_attachRadio setState:sender == _attachRadio ? NSOnState : NSOffState];
        [_launchRadio setState:sender == _launchRadio ? NSOnState : NSOffState];
    }

    BOOL attach = [self isAttachSelected];
    [_processTable setEnabled:attach];
    [_filterField setEnabled:attach];
    [_launchField setEnabled:!attach];
    [_argumentsField setEnabled:!attach];
    [self optionsChanged:nil];
}

- (void)optionsChanged:(id)sender
{
    (void)sender;
    BOOL cpu = [self selectedMode] == PRProfileModeCPU;

    [_frequencyPopUp setHidden:!cpu];
    [_callGraphPopUp setHidden:!cpu];
    [_memoryCostPopUp setHidden:cpu];
    [_durationField setEnabled:[_durationCheck state] == NSOnState];

    NSMutableString *note = [NSMutableString string];
    NSString *problem = [PRRecorderFactory problemForMode:[self selectedMode]];
    Class recorder = [PRRecorderFactory recorderClassForMode:[self selectedMode]];

    if (problem != nil) {
        [note appendString:problem];
        [_recordButton setEnabled:NO];
    } else {
        [_recordButton setEnabled:YES];
        [note appendFormat:@"Records with %@.", [recorder toolName]];

        PRRecordRequest *request = [self buildRequest];
        NSString *warning = [recorder warningForRequest:request];
        if (warning != nil)
            [note appendFormat:@"\n\n%@", warning];
    }

    [_noteField setStringValue:note];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
    if ([notification object] == _filterField)
        [self filterChanged:_filterField];
}

- (void)filterChanged:(id)sender
{
    (void)sender;
    [self applyFilter];
    [_processTable reloadData];
}

- (void)applyFilter
{
    NSString *filter = [_filterField stringValue];
    if ([filter length] == 0) {
        _visibleProcesses = _processes;
        return;
    }

    NSMutableArray *matches = [NSMutableArray array];
    for (PRProcessInfo *process in _processes) {
        if ([[process name] rangeOfString:filter
                                  options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [[NSString stringWithFormat:@"%d", [process pid]] hasPrefix:filter])
            [matches addObject:process];
    }
    _visibleProcesses = matches;
}

- (void)refreshProcesses:(NSTimer *)timer
{
    (void)timer;
    PRProcessInfo *selected = [self selectedProcess];

    _processes = [[_monitor processes] sortedArrayUsingComparator:
                  ^NSComparisonResult(PRProcessInfo *a, PRProcessInfo *b) {
        if ([a cpuPercent] > [b cpuPercent]) return NSOrderedAscending;
        if ([a cpuPercent] < [b cpuPercent]) return NSOrderedDescending;
        return [[a name] localizedCaseInsensitiveCompare:[b name]];
    }];
    [self applyFilter];
    [_processTable reloadData];

    if (selected != nil) {
        NSUInteger row = 0;
        for (PRProcessInfo *process in _visibleProcesses) {
            if ([process pid] == [selected pid]) {
                [_processTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
                           byExtendingSelection:NO];
                [_liveGraph addValue:[process cpuPercent]];
                break;
            }
            row++;
        }
    }
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    (void)notification;
    [_liveGraph clear];
    PRProcessInfo *process = [self selectedProcess];
    if (process != nil)
        [_liveGraph setCaption:[NSString stringWithFormat:@"CPU %% of %@",
                                [process name]]];
    [self optionsChanged:nil];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    (void)tableView;
    return (NSInteger)[_visibleProcesses count];
}

- (id)tableView:(NSTableView *)tableView
objectValueForTableColumn:(NSTableColumn *)column
            row:(NSInteger)rowIndex
{
    (void)tableView;
    PRProcessInfo *process = [_visibleProcesses objectAtIndex:rowIndex];
    NSString *identifier = [column identifier];

    if ([identifier isEqualToString:@"name"])
        return [process name];
    if ([identifier isEqualToString:@"pid"])
        return [NSString stringWithFormat:@"%d", [process pid]];
    if ([identifier isEqualToString:@"cpu"])
        return [NSString stringWithFormat:@"%.0f %%", [process cpuPercent]];
    if ([identifier isEqualToString:@"memory"])
        return [NSString stringWithFormat:@"%.0f MB",
                [process rssBytes] / 1048576.0];
    return @"";
}

- (void)chooseProgram:(id)sender
{
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:YES];
    [panel setAllowsMultipleSelection:NO];
    [panel setTitle:@"Choose a Program to Profile"];

    if ([panel runModal] != NSOKButton)
        return;

    NSString *path = [[panel URLs] count] ?
        [[[panel URLs] objectAtIndex:0] path] : nil;
    if (path == nil)
        return;

    /* An application bundle is not executable itself; the program inside
       it carries the bundle's name. */
    if ([[path pathExtension] isEqualToString:@"app"]) {
        NSString *name = [[path lastPathComponent] stringByDeletingPathExtension];
        NSString *executable = [path stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:executable])
            path = executable;
    }

    [_launchField setStringValue:path];
    [self targetKindChanged:_launchRadio];
}

- (PRRecordRequest *)buildRequest
{
    PRRecordRequest *request = [[PRRecordRequest alloc] init];
    [request setMode:[self selectedMode]];
    [request setCallGraph:(PRCallGraphMethod)[_callGraphPopUp indexOfSelectedItem]];
    [request setMemoryCost:(PRMemoryCost)[_memoryCostPopUp indexOfSelectedItem]];

    static const NSUInteger frequencies[] = { 99, 199, 499, 999, 1999 };
    NSUInteger index = (NSUInteger)[_frequencyPopUp indexOfSelectedItem];
    [request setFrequency:frequencies[index < 5 ? index : 3]];

    if ([_durationCheck state] == NSOnState)
        [request setDuration:[[_durationField stringValue] doubleValue]];

    if ([self isAttachSelected]) {
        PRProcessInfo *process = [self selectedProcess];
        if (process != nil) {
            [request setPid:[process pid]];
            [request setTargetName:[process name]];
        }
    } else {
        NSString *path = [[_launchField stringValue]
                          stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        [request setLaunchPath:path];
        [request setTargetName:[path lastPathComponent]];
        NSString *arguments = [[_argumentsField stringValue]
                               stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]];
        if ([arguments length] > 0)
            [request setArguments:[arguments componentsSeparatedByString:@" "]];
    }
    return request;
}

- (void)complain:(NSString *)message
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"The recording cannot be started"];
    [alert setInformativeText:message];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)startRecording:(id)sender
{
    (void)sender;
    PRRecordRequest *request = [self buildRequest];

    if ([self isAttachSelected]) {
        if ([request pid] <= 0) {
            [self complain:@"Select the program to watch in the list."];
            return;
        }
    } else {
        NSString *path = [request launchPath];
        if ([path length] == 0) {
            [self complain:@"Choose the program to start."];
            return;
        }
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
            [self complain:[NSString stringWithFormat:
                            @"%@ cannot be run.", path]];
            return;
        }
    }

    NSString *problem = [PRRecorderFactory problemForMode:[request mode]];
    if (problem != nil) {
        [self complain:problem];
        return;
    }

    _result = request;
    [NSApp stopModal];
}

@end
