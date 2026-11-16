/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SystemProfilerController.h"
#import "SystemInfo.h"
#import "AppearanceMetrics.h"

static const float SP_LEFT_PANEL_WIDTH = 200.0;
static const float SP_WINDOW_WIDTH = 700.0;
static const float SP_WINDOW_HEIGHT = 500.0;


@interface SPDataItem : NSObject
@property (nonatomic, strong) NSString *title;
@property (nonatomic, strong) NSMutableArray<SPDataItem *> *children;
@property (nonatomic, assign) BOOL isCategory;
@property (nonatomic, strong) NSArray *detailPairs;
@end

@implementation SPDataItem
@end

@interface SystemProfilerController ()
{
    NSWindow *_window;
    NSOutlineView *_outlineView;
    NSTableView *_detailTable;
    NSMutableArray<SPDataItem *> *_rootItems;
    NSArray *_currentKeys;
    NSArray *_currentValues;
    NSTableColumn *_keyColumn;
    NSTableColumn *_valueColumn;
    NSTextField *_hostnameField;
    NSTextField *_timeField;
    NSTimer *_timeTimer;
}
- (void)_setupMenu;
- (void)_buildDataModel;
- (void)_createWindow;
- (void)_updateTime;
@end

@implementation SystemProfilerController

+ (SystemProfilerController *)sharedController
{
    static SystemProfilerController *shared = nil;
    if (!shared) {
        shared = [[SystemProfilerController alloc] init];
    }
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _rootItems = [NSMutableArray array];
        [self _buildDataModel];
    }
    return self;
}

- (NSArray *)_pairWithKey:(NSString *)key value:(NSString *)value
{
    return [NSArray arrayWithObjects:key, value, nil];
}

- (NSArray *)_pairsFromList:(NSArray *)list
{
    return [self _pairsFromList:list withSeparator:[NSCharacterSet whitespaceCharacterSet]];
}

- (NSArray *)_pairsFromList:(NSArray *)list withSeparator:(NSCharacterSet *)sep
{
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *line in list) {
        NSString *key = @"";
        NSString *value = line;
        NSUInteger len = [line length];
        NSRange r = [line rangeOfCharacterFromSet:sep];
        if (r.location != NSNotFound && r.location < len && r.location > 0) {
            key = [line substringToIndex:r.location + 1];
            key = [key stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            value = [[line substringFromIndex:r.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
        [pairs addObject:[NSArray arrayWithObjects:key, value, nil]];
    }
    return pairs;
}

- (void)_buildDataModel
{
    SPDataItem *overview = [self _categoryItemWithTitle:@"Overview"];
    [overview setDetailPairs:[NSArray arrayWithObjects:
        [self _pairWithKey:@"Hardware UUID:" value:[SystemInfo hardwareUUID]],
        [self _pairWithKey:@"Model:" value:[SystemInfo systemModel]],
        [self _pairWithKey:@"Manufacturer:" value:[SystemInfo systemManufacturer]],
        [self _pairWithKey:@"Serial:" value:[SystemInfo systemSerial]],
        [self _pairWithKey:@"Boot Mode:" value:[SystemInfo bootMode]],
        nil]];
    [_rootItems addObject:overview];

    {
        NSArray *dt = [SystemInfo deviceTreeInfo];
        if ([dt count] > 0) {
            SPDataItem *dtItem = [self _categoryItemWithTitle:@"Device Tree"];
            [dtItem setDetailPairs:dt];
            [_rootItems addObject:dtItem];
        }
    }

    SPDataItem *processor = [self _categoryItemWithTitle:@"Processor"];
    [processor setDetailPairs:[NSArray arrayWithObjects:
        [self _pairWithKey:@"Name:" value:[SystemInfo processorName]],
        [self _pairWithKey:@"Count:" value:[SystemInfo processorCount]],
        [self _pairWithKey:@"Architecture:" value:[SystemInfo cpuArchitecture]],
        nil]];
    [_rootItems addObject:processor];

    SPDataItem *memory = [self _categoryItemWithTitle:@"Memory"];
    [memory setDetailPairs:[NSArray arrayWithObjects:
        [self _pairWithKey:@"Total:" value:[SystemInfo totalMemory]],
        [self _pairWithKey:@"Swap:" value:[SystemInfo swapInfo]],
        nil]];
    [_rootItems addObject:memory];

    SPDataItem *storage = [self _categoryItemWithTitle:@"Storage"];
    [storage setDetailPairs:[self _pairsFromList:[SystemInfo storageDevices]]];
    [_rootItems addObject:storage];

    SPDataItem *filesystems = [self _categoryItemWithTitle:@"Filesystems"];
    [filesystems setDetailPairs:[self _pairsFromList:[SystemInfo mountedFilesystems]]];
    [_rootItems addObject:filesystems];

    SPDataItem *pci = [self _categoryItemWithTitle:@"PCI / Hardware"];
    [pci setDetailPairs:[self _pairsFromList:[SystemInfo pciDevices]]];
    [_rootItems addObject:pci];

    SPDataItem *usb = [self _categoryItemWithTitle:@"USB"];
    [usb setDetailPairs:[self _pairsFromList:[SystemInfo usbDevices] withSeparator:[NSCharacterSet characterSetWithCharactersInString:@":"]]];
    [_rootItems addObject:usb];

    SPDataItem *displays = [self _categoryItemWithTitle:@"Displays"];
    {
        NSArray *pairs = [SystemInfo displayPairs];
        [displays setDetailPairs:pairs];
    }
    [_rootItems addObject:displays];

    SPDataItem *energy = [self _categoryItemWithTitle:@"Energy"];
    [energy setDetailPairs:[SystemInfo energyInfo]];
    [_rootItems addObject:energy];

    SPDataItem *bt = [self _categoryItemWithTitle:@"Bluetooth"];
    [bt setDetailPairs:[SystemInfo bluetoothInfo]];
    [_rootItems addObject:bt];

    SPDataItem *network = [self _categoryItemWithTitle:@"Network"];
    [network setDetailPairs:[self _pairsFromList:[SystemInfo networkInterfaces]]];
    [_rootItems addObject:network];

    SPDataItem *audio = [self _categoryItemWithTitle:@"Audio"];
    [audio setDetailPairs:[self _pairsFromList:[SystemInfo audioDevices]]];
    [_rootItems addObject:audio];

    SPDataItem *extensions = [self _categoryItemWithTitle:@"Kernel Extensions"];
    [extensions setDetailPairs:[self _pairsFromList:[SystemInfo kernelExtensions]]];
    [_rootItems addObject:extensions];

    SPDataItem *input = [self _categoryItemWithTitle:@"Input"];
    {
        NSArray *pairs = [SystemInfo inputDevicePairs];
        if ([pairs count] == 0) {
            pairs = [self _pairsFromList:[SystemInfo inputDevices]];
        }
        [input setDetailPairs:pairs];
    }
    [_rootItems addObject:input];

    SPDataItem *software = [self _categoryItemWithTitle:@"Software"];
    [software setDetailPairs:[NSArray arrayWithObjects:
        [self _pairWithKey:@"Distribution:" value:[SystemInfo distributionName]],
        [self _pairWithKey:@"Version:" value:[SystemInfo osVersion]],
        [self _pairWithKey:@"Kernel:" value:[SystemInfo kernelName]],
        [self _pairWithKey:@"Kernel Version:" value:[SystemInfo kernelVersion]],
        nil]];
    [_rootItems addObject:software];

    SPDataItem *startup = [self _categoryItemWithTitle:@"Startup"];
    [startup setDetailPairs:[NSArray arrayWithObjects:
        [self _pairWithKey:@"Uptime:" value:[SystemInfo systemUptime]],
        [self _pairWithKey:@"Init System:" value:[SystemInfo initSystem]],
        nil]];
    [_rootItems addObject:startup];

    SPDataItem *users = [self _categoryItemWithTitle:@"Users"];
    [users setDetailPairs:[NSArray arrayWithObjects:
        [self _pairWithKey:@"Current User:" value:[SystemInfo userName]],
        [self _pairWithKey:@"Hostname:" value:[SystemInfo hostname]],
        nil]];
    [_rootItems addObject:users];
}

- (SPDataItem *)_categoryItemWithTitle:(NSString *)title
{
    SPDataItem *item = [[SPDataItem alloc] init];
    [item setTitle:title];
    [item setChildren:[NSMutableArray array]];
    [item setIsCategory:YES];
    return item;
}

#pragma mark - Menu Setup

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    (void)notification;
    [self _setupMenu];
}

- (void)_setupMenu
{
    NSString *appName = [[NSProcessInfo processInfo] processName];

    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];

    // ---- Application menu ----
    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:appName action:NULL keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];

    [appMenu addItemWithTitle:@"About SystemProfiler..."
                       action:@selector(showAbout:)
                keyEquivalent:@""];

    [appMenu addItem:[NSMenuItem separatorItem]];

    [appMenu addItemWithTitle:@"Services"
                       action:NULL
                keyEquivalent:@""];
    NSMenu *servicesMenu = [[NSMenu alloc] initWithTitle:@"Services"];
    [[appMenu itemAtIndex:[appMenu numberOfItems] - 1] setSubmenu:servicesMenu];

    [appMenu addItem:[NSMenuItem separatorItem]];

    [appMenu addItemWithTitle:[NSString stringWithFormat:@"Hide %@", appName]
                       action:@selector(hide:)
                keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"Hide Others"
                       action:@selector(hideOtherApplications:)
                keyEquivalent:@"h"];
    [[[appMenu itemArray] lastObject] setKeyEquivalentModifierMask:NSAlternateKeyMask | NSCommandKeyMask];
    [appMenu addItemWithTitle:@"Show All"
                       action:@selector(unhideAllApplications:)
                keyEquivalent:@""];

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = (NSMenuItem *)[appMenu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
                                              action:@selector(terminate:)
                                       keyEquivalent:@"q"];
    [quitItem setTarget:NSApp];

    [appItem setSubmenu:appMenu];
    [mainMenu addItem:appItem];

    // ---- File menu ----
    NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"File" action:NULL keyEquivalent:@""];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];

    [fileMenu addItemWithTitle:@"Close"
                        action:@selector(performClose:)
                 keyEquivalent:@"w"];

    [fileItem setSubmenu:fileMenu];
    [mainMenu addItem:fileItem];

    // ---- Edit menu ----
    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:NULL keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];

    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

    [editItem setSubmenu:editMenu];
    [mainMenu addItem:editItem];

    [NSApp setMainMenu:mainMenu];
}

#pragma mark - About Panel

- (void)showAbout:(id)sender
{
    (void)sender;

    NSString *appName = [[NSProcessInfo processInfo] processName];
    NSString *version = @"1.0";
    NSString *buildInfo = [NSString stringWithFormat:@"%@ %@, %@",
        [SystemInfo distributionName], [SystemInfo osVersion],
        [SystemInfo cpuArchitecture]];

    NSString *credits = [NSString stringWithFormat:
        @"%@\n\n"
        @"Kernel: %@ %@\n"
        @"Processor: %@ (%@)\n"
        @"Memory: %@\n"
        @"Hostname: %@\n\n"
        @"Copyright (c) 2026 Simon Peter\n"
        @"SPDX-License-Identifier: BSD-2-Clause",
        buildInfo,
        [SystemInfo kernelName], [SystemInfo kernelVersion],
        [SystemInfo processorName], [SystemInfo processorCount],
        [SystemInfo totalMemory],
        [SystemInfo hostname]];

    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
        appName, @"ApplicationName",
        version, @"ApplicationVersion",
        credits, @"Credits",
        nil];

    [NSApp orderFrontStandardAboutPanelWithOptions:options];
}

#pragma mark - Window Lifecycle

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    (void)notification;
    [self _createWindow];
    [self _updateTime];
    _timeTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
        selector:@selector(_updateTime) userInfo:nil repeats:YES];
    [_window makeKeyAndOrderFront:self];
}

- (void)_updateTime
{
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"EEEE, MMMM d  HH:mm:ss"];
    [_timeField setStringValue:[fmt stringFromDate:[NSDate date]]];
}

- (void)_createWindow
{
    NSRect frame = NSMakeRect(100, 100, SP_WINDOW_WIDTH, SP_WINDOW_HEIGHT);
    unsigned int style = NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask;
    _window = [[NSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    /* ARC owns the window through _window.  Released when closed, -close would
     * release it a second time: on quit NSApplication closes every window and
     * the app crashed draining its autorelease pool. */
    [_window setReleasedWhenClosed:NO];
    [_window setTitle:@"System Profiler"];
    [_window setMinSize:NSMakeSize(SP_WINDOW_WIDTH * 0.6, SP_WINDOW_HEIGHT * 0.6)];
    [_window setDelegate:(id)self];

    NSView *contentView = [_window contentView];
    [contentView setAutoresizesSubviews:YES];
    NSRect winFrame = [_window frame];
    NSSize contentSize = [NSWindow contentRectForFrameRect:winFrame styleMask:[_window styleMask]].size;

    NSFont *hostFont = METRICS_FONT_SYSTEM_REGULAR_11;
    CGFloat fontH = ceil([hostFont ascender] + fabs([hostFont descender]) + [hostFont leading]);
    CGFloat paneTop = contentSize.height - fontH;

    /* Hostname (top left) */
    _hostnameField = [[NSTextField alloc] initWithFrame:NSMakeRect(8, paneTop, SP_LEFT_PANEL_WIDTH - 8, fontH)];
    [_hostnameField setStringValue:[SystemInfo hostname]];
    [_hostnameField setEditable:NO];
    [_hostnameField setSelectable:NO];
    [_hostnameField setBordered:NO];
    [_hostnameField setBezeled:NO];
    [_hostnameField setDrawsBackground:NO];
    [_hostnameField setTextColor:[NSColor controlTextColor]];
    NSFont *boldFont = [[NSFontManager sharedFontManager] convertFont:hostFont toHaveTrait:NSBoldFontMask];
    [_hostnameField setFont:(boldFont ?: hostFont)];
    [_hostnameField setAutoresizingMask:NSViewMinYMargin | NSViewMaxXMargin];
    [contentView addSubview:_hostnameField];

    /* Date/time (top right) */
    _timeField = [[NSTextField alloc] initWithFrame:NSMakeRect(contentSize.width - 200, paneTop, 192, fontH)];
    [_timeField setEditable:NO];
    [_timeField setSelectable:NO];
    [_timeField setBordered:NO];
    [_timeField setBezeled:NO];
    [_timeField setDrawsBackground:NO];
    [_timeField setTextColor:[NSColor controlTextColor]];
    [_timeField setAlignment:NSRightTextAlignment];
    [_timeField setFont:hostFont];
    [_timeField setAutoresizingMask:NSViewMinYMargin | NSViewMinXMargin];
    [contentView addSubview:_timeField];

    /* Left pane: fixed-width outline view with categories */
    NSRect leftFrame = NSMakeRect(0, 0, SP_LEFT_PANEL_WIDTH, paneTop);
    NSScrollView *leftScrollView = [[NSScrollView alloc] initWithFrame:leftFrame];
    [leftScrollView setBorderType:NSNoBorder];
    [leftScrollView setHasVerticalScroller:YES];
    [leftScrollView setAutoresizingMask:NSViewHeightSizable | NSViewMaxXMargin];

    _outlineView = [[NSOutlineView alloc] initWithFrame:NSMakeRect(0, 0, SP_LEFT_PANEL_WIDTH, paneTop * 10)];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"Category"];
    [column setWidth:SP_LEFT_PANEL_WIDTH - 20];
    [_outlineView addTableColumn:column];
    [_outlineView setHeaderView:nil];
    [_outlineView setDataSource:self];
    [_outlineView setDelegate:self];
    [_outlineView setAllowsMultipleSelection:NO];
    [leftScrollView setDocumentView:_outlineView];
    [contentView addSubview:leftScrollView];

    /* Right pane: fills remaining width */
    NSRect rightFrame = NSMakeRect(SP_LEFT_PANEL_WIDTH, 0, contentSize.width - SP_LEFT_PANEL_WIDTH, paneTop);
    NSScrollView *rightScrollView = [[NSScrollView alloc] initWithFrame:rightFrame];
    [rightScrollView setBorderType:NSNoBorder];
    [rightScrollView setHasVerticalScroller:YES];
    [rightScrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    _detailTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, rightFrame.size.width, paneTop * 10)];
    [_detailTable setAutoresizingMask:NSViewWidthSizable];
    [_detailTable setUsesAlternatingRowBackgroundColors:YES];
    [_detailTable setRowHeight:16.0];
    [_detailTable setIntercellSpacing:NSMakeSize(6, 2)];

    _keyColumn = [[NSTableColumn alloc] initWithIdentifier:@"Key"];
    [_keyColumn setWidth:120];
    [_keyColumn setResizingMask:NSTableColumnNoResizing];
    [[_keyColumn dataCell] setFont:METRICS_FONT_SYSTEM_REGULAR_11];

    _valueColumn = [[NSTableColumn alloc] initWithIdentifier:@"Value"];
    [_valueColumn setWidth:200];
    [_valueColumn setResizingMask:NSTableColumnNoResizing];
    [[_valueColumn dataCell] setFont:METRICS_FONT_SYSTEM_REGULAR_11];

    [_detailTable addTableColumn:_keyColumn];
    [_detailTable addTableColumn:_valueColumn];
    [_detailTable setDataSource:self];
    [_detailTable setDelegate:self];
    [_detailTable setHeaderView:nil];
    [_detailTable setPostsFrameChangedNotifications:YES];
    [rightScrollView setDocumentView:_detailTable];
    [contentView addSubview:rightScrollView];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(_resizeValueColumn)
        name:NSViewFrameDidChangeNotification
        object:_detailTable];

    if ([_rootItems count] > 0) {
        [_outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [self outlineViewSelectionDidChange:nil];
    }
}

#pragma mark - NSWindowDelegate

- (void)windowWillClose:(NSNotification *)notification
{
    (void)notification;
    [_timeTimer invalidate];
    _timeTimer = nil;
    _window = nil;
    [NSApp terminate:self];
}

#pragma mark - NSOutlineViewDataSource

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item
{
    (void)outlineView;
    if (!item) {
        return (NSInteger)[_rootItems count];
    }
    return (NSInteger)[[(SPDataItem *)item children] count];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item
{
    (void)outlineView;
    return [[(SPDataItem *)item children] count] > 0;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item
{
    (void)outlineView;
    if (!item) {
        return [_rootItems objectAtIndex:(NSUInteger)index];
    }
    return [[(SPDataItem *)item children] objectAtIndex:(NSUInteger)index];
}

- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn byItem:(id)item
{
    (void)outlineView;
    (void)tableColumn;
    return [(SPDataItem *)item title];
}

#pragma mark - NSOutlineViewDelegate

- (void)outlineViewSelectionDidChange:(NSNotification *)notification
{
    (void)notification;
    NSInteger row = [_outlineView selectedRow];
    if (row < 0) {
        _currentKeys = [NSArray array];
        _currentValues = [NSArray array];
        [_detailTable reloadData];
        return;
    }

    SPDataItem *item = [_outlineView itemAtRow:row];
    if (!item) return;

    NSArray *pairs = [item detailPairs];
    NSMutableArray *keys = [NSMutableArray array];
    NSMutableArray *values = [NSMutableArray array];
    for (NSArray *pair in pairs) {
        if ([pair count] >= 2) {
            [keys addObject:[pair objectAtIndex:0]];
            [values addObject:[pair objectAtIndex:1]];
        }
    }
    _currentKeys = keys;
    _currentValues = values;
    [_detailTable reloadData];
    [_detailTable deselectAll:nil];

    CGFloat maxW = 0;
    for (NSString *key in keys) {
        NSSize sz = [key sizeWithAttributes:
            @{NSFontAttributeName: METRICS_FONT_SYSTEM_REGULAR_11}];
        if (sz.width > maxW) maxW = sz.width;
    }
    CGFloat keyW = ceil(maxW) + 10;
    [_keyColumn setWidth:keyW];
    [self _resizeValueColumn];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    (void)tableView;
    return (NSInteger)[_currentKeys count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    (void)tableView;
    if ([[tableColumn identifier] isEqualToString:@"Key"]) {
        return [_currentKeys objectAtIndex:(NSUInteger)row];
    }
    return [_currentValues objectAtIndex:(NSUInteger)row];
}

#pragma mark - NSTableViewDelegate

- (void)_resizeValueColumn
{
    CGFloat keyW = [_keyColumn width];
    CGFloat clipW = [[_detailTable superview] bounds].size.width;
    if (clipW > keyW + 6)
        [_valueColumn setWidth:clipW - keyW - 6.0];
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row
{
    (void)tableView;
    if (row == [_detailTable selectedRow]) {
        [_detailTable deselectAll:nil];
        return NO;
    }
    return YES;
}

#pragma mark - Copy

- (void)copy:(id)sender
{
    (void)sender;
    NSInteger row = [_detailTable selectedRow];
    NSMutableString *text = [NSMutableString string];

    if (row >= 0 && row < (NSInteger)[_currentKeys count]) {
        NSString *key = [_currentKeys objectAtIndex:(NSUInteger)row];
        NSString *val = [_currentValues objectAtIndex:(NSUInteger)row];
        if ([key length] > 0) {
            [text appendFormat:@"%@ %@", key, val];
        } else {
            [text appendString:val];
        }
    } else {
        for (NSUInteger i = 0; i < [_currentKeys count]; i++) {
            NSString *key = [_currentKeys objectAtIndex:i];
            NSString *val = [_currentValues objectAtIndex:i];
            if ([key length] > 0) {
                [text appendFormat:@"%@ %@", key, val];
            } else {
                [text appendString:val];
            }
            if (i + 1 < [_currentKeys count]) {
                [text appendString:@"\n"];
            }
        }
    }

    if ([text length] > 0) {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
        [pb setString:text forType:NSStringPboardType];
    }
}

#pragma mark - NSApplicationDelegate

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application
{
    (void)application;
    return YES;
}

@end
