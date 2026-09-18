/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ForceQuitPanel.h"
#import "RunningApplicationList.h"
#import "AppearanceMetrics.h"

#import <errno.h>
#import <signal.h>
#import <string.h>

static const CGFloat kForceQuitPanelWidth = 400.0;
static const CGFloat kForceQuitPanelHeight = 320.0;
static const CGFloat kForceQuitMessageHeight = 34.0;
static const CGFloat kForceQuitHintHeight = 28.0;
/* Rows keep the standard table pitch (20 + 2px spacing), but the spacing is
   given to the cells so the icon can fill the whole row and stay
   recognizable. */
static const CGFloat kForceQuitRowHeight = 22.0;
static const CGFloat kForceQuitIconSize = 22.0;
static const CGFloat kForceQuitIconColumnWidth = 26.0;
/* Applications come and go while the panel is open; the list must follow
   without the user having to reopen it. */
static const NSTimeInterval kForceQuitRefreshInterval = 1.0;

/* The table view is first responder and swallows Escape, so the panel
   closes itself before the event is dispatched. */
@interface ForceQuitPanel : NSPanel
@end

@implementation ForceQuitPanel

- (void)sendEvent:(NSEvent *)event
{
    if ([event type] == NSKeyDown) {
        NSString *chars = [event charactersIgnoringModifiers];
        if ([chars length] == 1 && [chars characterAtIndex:0] == 0x1B) {
            [self performClose:nil];
            return;
        }
    }
    [super sendEvent:event];
}

@end

/* A plain text cell draws the name at the top of the row; it has to sit on
   the same center line as the icon next to it. */
@interface ForceQuitNameCell : NSTextFieldCell
@end

@implementation ForceQuitNameCell

- (NSRect)titleRectForBounds:(NSRect)bounds
{
    NSRect titleRect = [super titleRectForBounds:bounds];
    CGFloat titleHeight = [[self attributedStringValue] size].height;
    titleRect.origin.y = bounds.origin.y + floor((bounds.size.height - titleHeight) / 2);
    titleRect.size.height = titleHeight;
    return titleRect;
}

@end

@interface ForceQuitPanelController () <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
{
    NSTableView *_tableView;
    NSButton *_forceQuitButton;
    NSArray *_applications;
    NSMutableDictionary *_iconsByName;
    NSTimer *_refreshTimer;
}
@end

@implementation ForceQuitPanelController

+ (instancetype)sharedController
{
    static ForceQuitPanelController *shared = nil;
    if (shared == nil) {
        shared = [[ForceQuitPanelController alloc] init];
    }
    return shared;
}

- (instancetype)init
{
    NSRect contentRect = NSMakeRect(0, 0, kForceQuitPanelWidth, kForceQuitPanelHeight);
    ForceQuitPanel *panel = [[ForceQuitPanel alloc] initWithContentRect:contentRect
                                                              styleMask:NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask
                                                                backing:NSBackingStoreBuffered
                                                                  defer:NO];
    [panel setTitle:NSLocalizedString(@"Force Quit Applications", nil)];
    [panel setReleasedWhenClosed:NO];
    [panel setHidesOnDeactivate:NO];
    /* The panel is typically opened while another application hangs; it
       must not end up behind that application's windows. */
    [panel setLevel:NSFloatingWindowLevel];
    [panel setContentMinSize:NSMakeSize(kForceQuitPanelWidth, 200)];

    self = [super initWithWindow:panel];
    if (self) {
        _applications = @[];
        _iconsByName = [NSMutableDictionary dictionary];
        [panel setDelegate:self];
        [self buildContent];
        [panel center];
    }
    return self;
}

- (void)buildContent
{
    NSView *content = [[self window] contentView];
    CGFloat w = NSWidth([content frame]);
    CGFloat h = NSHeight([content frame]);
    CGFloat innerW = w - 2 * METRICS_CONTENT_SIDE_MARGIN;

    CGFloat messageY = h - METRICS_CONTENT_TOP_MARGIN - kForceQuitMessageHeight;
    NSTextField *message = [self labelWithFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, messageY,
                                                           innerW, kForceQuitMessageHeight)
                                           text:NSLocalizedString(@"If an application does not respond for a while, select its name and click Force Quit.", nil)
                                           font:METRICS_FONT_SYSTEM_REGULAR_13];
    [message setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [content addSubview:message];

    /* The hint takes two lines at the panel's minimum width; the button is
       centered on it. */
    CGFloat hintY = METRICS_CONTENT_BOTTOM_MARGIN;
    CGFloat buttonY = hintY + floor((kForceQuitHintHeight - METRICS_BUTTON_HEIGHT) / 2);
    _forceQuitButton = [[NSButton alloc] initWithFrame:NSMakeRect(w - METRICS_CONTENT_SIDE_MARGIN - METRICS_BUTTON_MIN_WIDTH,
                                                                  buttonY,
                                                                  METRICS_BUTTON_MIN_WIDTH,
                                                                  METRICS_BUTTON_HEIGHT)];
    [_forceQuitButton setTitle:NSLocalizedString(@"Force Quit", nil)];
    [_forceQuitButton setBezelStyle:NSRoundedBezelStyle];
    [_forceQuitButton setKeyEquivalent:@"\r"];
    [_forceQuitButton setTarget:self];
    [_forceQuitButton setAction:@selector(forceQuit:)];
    [_forceQuitButton setEnabled:NO];
    [_forceQuitButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
    [content addSubview:_forceQuitButton];

    NSTextField *hint = [self labelWithFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, hintY,
                                                        innerW - METRICS_BUTTON_MIN_WIDTH - METRICS_BUTTON_HORIZ_INTERSPACE,
                                                        kForceQuitHintHeight)
                                        text:NSLocalizedString(@"You can open this window by pressing Command-Shift-Escape.", nil)
                                        font:METRICS_FONT_SYSTEM_REGULAR_11];
    [hint setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    [content addSubview:hint];

    CGFloat scrollY = hintY + kForceQuitHintHeight + METRICS_SPACE_12;
    CGFloat scrollH = messageY - METRICS_SPACE_8 - scrollY;
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, scrollY,
                                                                              innerW, scrollH)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setBorderType:NSBezelBorder];
    [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    NSSize tableSize = [scrollView contentSize];
    _tableView = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, tableSize.width, tableSize.height)];
    [_tableView setHeaderView:nil];
    [_tableView setCornerView:nil];
    [_tableView setRowHeight:kForceQuitRowHeight];
    [_tableView setIntercellSpacing:NSMakeSize([_tableView intercellSpacing].width, 0)];
    [_tableView setAllowsMultipleSelection:NO];
    [_tableView setAllowsEmptySelection:YES];
    [_tableView setColumnAutoresizingStyle:NSTableViewLastColumnOnlyAutoresizingStyle];

    NSTableColumn *iconColumn = [[NSTableColumn alloc] initWithIdentifier:@"icon"];
    NSImageCell *iconCell = [[NSImageCell alloc] init];
    [iconCell setImageAlignment:NSImageAlignCenter];
    [iconColumn setDataCell:iconCell];
    [iconColumn setWidth:kForceQuitIconColumnWidth];
    [iconColumn setMinWidth:kForceQuitIconColumnWidth];
    [iconColumn setMaxWidth:kForceQuitIconColumnWidth];
    [iconColumn setEditable:NO];
    [_tableView addTableColumn:iconColumn];

    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [nameColumn setDataCell:[[ForceQuitNameCell alloc] init]];
    [nameColumn setEditable:NO];
    [nameColumn setWidth:tableSize.width - kForceQuitIconColumnWidth];
    [nameColumn setResizingMask:NSTableColumnAutoresizingMask];
    [_tableView addTableColumn:nameColumn];

    [_tableView setDataSource:self];
    [_tableView setDelegate:self];
    [_tableView setTarget:self];
    [_tableView setDoubleAction:@selector(forceQuit:)];

    [scrollView setDocumentView:_tableView];
    [content addSubview:scrollView];
}

- (NSTextField *)labelWithFrame:(NSRect)frame text:(NSString *)text font:(NSFont *)font
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    [label setStringValue:text];
    [label setFont:font];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [[label cell] setWraps:YES];
    return label;
}

#pragma mark - Showing

- (void)showPanel:(id)sender
{
    (void)sender;
    [self reloadApplications];
    if ([_tableView selectedRow] < 0 && [_applications count] > 0) {
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    }

    [NSApp activateIgnoringOtherApps:YES];
    [[self window] makeKeyAndOrderFront:nil];
    [[self window] makeFirstResponder:_tableView];

    if (_refreshTimer == nil) {
        _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:kForceQuitRefreshInterval
                                                         target:self
                                                       selector:@selector(refreshTimerFired:)
                                                       userInfo:nil
                                                        repeats:YES];
    }
}

- (void)windowWillClose:(NSNotification *)notification
{
    (void)notification;
    [_refreshTimer invalidate];
    _refreshTimer = nil;
}

- (void)refreshTimerFired:(NSTimer *)timer
{
    (void)timer;
    [self reloadApplications];
}

#pragma mark - Application list

- (void)reloadApplications
{
    NSNumber *selectedPid = [self selectedApplicationPid];

    NSArray *apps = [RunningApplicationList applicationsOwningWindows];
    NSSortDescriptor *byName = [NSSortDescriptor sortDescriptorWithKey:@"name"
                                                             ascending:YES
                                                              selector:@selector(caseInsensitiveCompare:)];
    apps = [apps sortedArrayUsingDescriptors:@[byName]];
    if ([apps isEqualToArray:_applications]) {
        return;
    }
    _applications = apps;
    [_tableView reloadData];

    /* Keep the user's choice across refreshes; row indexes shift whenever an
       application starts or quits. */
    [_tableView deselectAll:nil];
    if (selectedPid != nil) {
        for (NSUInteger i = 0; i < [_applications count]; i++) {
            if ([[[_applications objectAtIndex:i] objectForKey:@"pid"] isEqual:selectedPid]) {
                [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
                break;
            }
        }
    }
    [self updateButtonState];
}

- (NSNumber *)selectedApplicationPid
{
    NSInteger row = [_tableView selectedRow];
    if (row < 0 || (NSUInteger)row >= [_applications count]) {
        return nil;
    }
    return [[_applications objectAtIndex:row] objectForKey:@"pid"];
}

- (void)updateButtonState
{
    [_forceQuitButton setEnabled:([_tableView selectedRow] >= 0)];
}

/* Looking an application up by name scans the application folders, so the
   result is kept for the next refresh.  Applications that are not GNUstep
   bundles have no icon to show.  -launchedApplications would give the exact
   bundle path, but it asks the Workspace over DO, and the Workspace may be
   the very application that hangs. */
- (NSImage *)iconForApplicationNamed:(NSString *)name
{
    id icon = [_iconsByName objectForKey:name];
    if (icon == nil) {
        NSString *path = [[NSWorkspace sharedWorkspace] fullPathForApplication:name];
        /* The application list is a cache and can still name a bundle that
           has since been moved or removed; its icon would be the generic one. */
        if (path != nil && ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            path = nil;
        }
        icon = path ? [[NSWorkspace sharedWorkspace] iconForFile:path] : nil;
        if (icon != nil) {
            icon = [icon copy];
            [icon setSize:NSMakeSize(kForceQuitIconSize, kForceQuitIconSize)];
        }
        [_iconsByName setObject:(icon ?: [NSNull null]) forKey:name];
    }
    return (icon == [NSNull null]) ? nil : icon;
}

#pragma mark - Force Quit

- (void)forceQuit:(id)sender
{
    (void)sender;
    NSInteger row = [_tableView selectedRow];
    if (row < 0 || (NSUInteger)row >= [_applications count]) {
        return;
    }
    NSDictionary *app = [_applications objectAtIndex:row];
    NSString *name = [app objectForKey:@"name"];
    pid_t pid = (pid_t)[[app objectForKey:@"pid"] intValue];

    NSString *title = [NSString stringWithFormat:NSLocalizedString(@"Do you want to force \"%@\" to quit?", nil), name];
    if (NSRunAlertPanel(title,
                        NSLocalizedString(@"You will lose any unsaved changes.", nil),
                        NSLocalizedString(@"Force Quit", nil),
                        NSLocalizedString(@"Cancel", nil), nil) != NSAlertDefaultReturn) {
        return;
    }

    /* SIGKILL cannot be caught or ignored, which is the point: the
       application is not responding to a normal quit request. */
    NSLog(@"ForceQuitPanel: Force quitting %@ (pid %d)", name, (int)pid);
    if (kill(pid, SIGKILL) != 0 && errno != ESRCH) {
        NSRunAlertPanel(NSLocalizedString(@"Force Quit", nil),
                        [NSString stringWithFormat:NSLocalizedString(@"\"%@\" could not be forced to quit: %s", nil),
                                                   name, strerror(errno)],
                        NSLocalizedString(@"OK", nil), nil, nil);
    }
    [self reloadApplications];
}

#pragma mark - NSTableViewDataSource / NSTableViewDelegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    (void)tableView;
    return (NSInteger)[_applications count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    (void)tableView;
    if (row < 0 || (NSUInteger)row >= [_applications count]) {
        return nil;
    }
    NSString *name = [[_applications objectAtIndex:row] objectForKey:@"name"];
    if ([[column identifier] isEqual:@"icon"]) {
        return [self iconForApplicationNamed:name];
    }
    return name;
}

- (BOOL)tableView:(NSTableView *)tableView shouldEditTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    (void)tableView;
    (void)column;
    (void)row;
    return NO;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    (void)notification;
    [self updateButtonState];
}

@end
