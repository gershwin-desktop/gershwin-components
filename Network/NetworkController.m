/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Network Controller Implementation
 */

#import "NetworkController.h"
#import "NMBackend.h"
#import "BSDBackend.h"
#import "CaptivePortalDetector.h"
#import "AppearanceMetrics.h"
#include <sys/utsname.h>
#if defined(__FreeBSD__) || defined(__DragonFly__)
#include <sys/sysctl.h>
#endif

// Layout constants following Eau Theme HIG (AppearanceMetrics.h)
// Content area matches the 640x480 window.
static const CGFloat kWindowWidth = 640;
static const CGFloat kWindowHeight = 440;
static const CGFloat kServiceListWidth = 180;

// HIG-compliant margins
static const CGFloat kContentSideMargin = METRICS_CONTENT_SIDE_MARGIN;
static const CGFloat kContentBottomMargin = METRICS_CONTENT_BOTTOM_MARGIN;
static const CGFloat kSpace8 = METRICS_SPACE_8;
static const CGFloat kSpace12 = METRICS_SPACE_12;

// HIG-compliant control sizes
static const CGFloat kButtonHeight = METRICS_BUTTON_HEIGHT;
static const CGFloat kFieldHeight = METRICS_TEXT_INPUT_FIELD_HEIGHT;
static const CGFloat kLabelWidth = 110;
static const CGFloat kStatusAreaHeight = 60;

@class NetworkController;

/* The pane view. The host window sizes it 5px wider than the box content
   (GNUstep NSBox quirk); make it exactly fill its superview and re-lay out
   so margins stay symmetric. */
@interface NetworkMainView : NSView
{
    NetworkController *_layoutOwner;
}
@end

@implementation NetworkMainView
- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    [_layoutOwner relayoutWithWidth:newSize.width];
}
- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    if ([self window] && [self superview]) {
        /* The host sizes the pane to the +5px-inflated contentView.  Fill
           the superview (the prefsBox content area) exactly so the left/right
           margins are symmetric and the top is not clipped, then re-lay out
           the panels to the actual height.  GNUstep's setFrame: bypasses
           setFrameSize:, so re-lay out explicitly here. */
        [self setFrame:[[self superview] bounds]];
        [_layoutOwner relayoutWithWidth:NSWidth([[self superview] bounds])];
    }
}
- (void)setLayoutOwner:(NetworkController *)owner
{
    _layoutOwner = owner;
}
@end

@interface NetworkController ()
- (void)updateClonedMacPopup;
- (void)setWLANTabShown:(BOOL)shown;
@end

#pragma mark - Dialog building blocks

/* Sheets and panels are laid out from these helpers so that every dialog of
   the pane gets the same control heights, spacings and button row. */

static const CGFloat kDialogTitleHeight = 17.0;    // one line of 13 pt
static const CGFloat kDialogInfoHeight = 14.0;     // one line of 11 pt
// The label of a 13 pt line is 17 px high; centred on a 22 px field.
static const CGFloat kDialogLabelInset = 3.0;

static NSTextField *DialogLabel(NSString *text, NSFont *font, NSTextAlignment alignment,
                                NSRect frame)
{
    NSTextField *label = [[[NSTextField alloc] initWithFrame:frame] autorelease];
    [label setStringValue:text];
    [label setFont:font];
    [label setAlignment:alignment];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    return label;
}

/* A one-line label that must not wrap into a second, clipped line: the
   network name in it is not under our control. */
static NSTextField *DialogSingleLineLabel(NSString *text, NSFont *font, NSRect frame)
{
    NSTextField *label = DialogLabel(text, font, NSLeftTextAlignment, frame);
    [[label cell] setLineBreakMode:NSLineBreakByTruncatingMiddle];
    [label setToolTip:text];
    return label;
}

static CGFloat DialogTextWidth(NSString *text, NSFont *font)
{
    return ceil([text sizeWithAttributes:
                 [NSDictionary dictionaryWithObject:font forKey:NSFontAttributeName]].width);
}

static NSButton *DialogButton(NSString *title, id target, SEL action, NSString *keyEquivalent)
{
    NSButton *button = [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease];
    [button setBezelStyle:NSRoundedBezelStyle];
    [button setTitle:title];
    [button setTarget:target];
    [button setAction:action];
    [button setKeyEquivalent:keyEquivalent];
    [button sizeToFit];
    /* sizeToFit also changes the height; the metrics fix it at 20. */
    NSRect frame = [button frame];
    frame.size.width = MAX(NSWidth(frame), METRICS_BUTTON_MIN_WIDTH);
    frame.size.height = METRICS_BUTTON_HEIGHT;
    [button setFrame:frame];
    return button;
}

/* Lays the buttons out along the bottom right edge in the given order
   (alternate, Cancel, default: the last one is the default button) and makes
   the last one the window's default button. */
static void DialogPlaceButtons(NSWindow *window, NSArray *buttons)
{
    NSView *content = [window contentView];
    CGFloat right = NSWidth([content frame]) - METRICS_CONTENT_SIDE_MARGIN;
    for (NSButton *button in [buttons reverseObjectEnumerator]) {
        NSRect frame = [button frame];
        frame.origin.x = right - NSWidth(frame);
        frame.origin.y = METRICS_CONTENT_BOTTOM_MARGIN;
        [button setFrame:frame];
        [button setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
        [content addSubview:button];
        right = NSMinX(frame) - METRICS_BUTTON_HORIZ_INTERSPACE;
    }
    [window setDefaultButtonCell:[[buttons lastObject] cell]];
}

/* Width the buttons take, so that a dialog is never narrower than its own
   button row. */
static CGFloat DialogButtonsWidth(NSArray *buttons)
{
    CGFloat width = 0;
    for (NSButton *button in buttons) {
        width += NSWidth([button frame]);
    }
    return width + METRICS_BUTTON_HORIZ_INTERSPACE * ([buttons count] - 1);
}

static NSPanel *DialogPanel(NSString *title, NSSize contentSize)
{
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, contentSize.width, contentSize.height)
                                                styleMask:NSTitledWindowMask
                                                  backing:NSBackingStoreBuffered
                                                    defer:YES];
    [panel setTitle:title];
    return panel;
}


@implementation NetworkController

#pragma mark - Initialization

- (id)init
{
    self = [super init];
    if (self) {
        interfaces = [[NSMutableArray alloc] init];
        wlanNetworks = [[NSMutableArray alloc] init];
        selectedInterface = nil;
        selectedWLANNetwork = nil;
        isEditing = NO;
        
        // Initialize the backend based on OS
        // NOTE: uname() is unreliable on FreeBSD with linux_enable="YES"
        // because the Linux ABI compatibility layer makes it return "Linux".
        // Use sysctlbyname or file-based detection instead.
        BOOL isFreeBSD = NO;

#if defined(__FreeBSD__) || defined(__DragonFly__)
        {
            char ostype[64] = {0};
            size_t len = sizeof(ostype) - 1;
            if (sysctlbyname("kern.ostype", ostype, &len, NULL, 0) == 0) {
                if (strcmp(ostype, "FreeBSD") == 0 ||
                    strcmp(ostype, "DragonFly") == 0) {
                    isFreeBSD = YES;
                }
            }
        }
#endif

        if (!isFreeBSD) {
            /* File-based fallback: sysrc(8) is FreeBSD-specific */
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm isExecutableFileAtPath:@"/usr/sbin/sysrc"]) {
                isFreeBSD = YES;
            }
        }

        if (!isFreeBSD) {
            /* Last resort: uname (unreliable with Linux ABI compat) */
            struct utsname uts;
            if (uname(&uts) == 0 && strcmp(uts.sysname, "FreeBSD") == 0) {
                isFreeBSD = YES;
            }
        }

        if (isFreeBSD) {
            NSDebugLLog(@"gwcomp", @"[Network] Detected FreeBSD, using BSD backend");
            backend = [[BSDBackend alloc] init];
        } else {
            NSDebugLLog(@"gwcomp", @"[Network] Detected Linux/other, using NetworkManager backend");
            backend = [[NMBackend alloc] init];
        }
        [backend setDelegate:self];
        
        /* No backendVersion here: it runs the backend's command line tool,
           and the controller is also created when the pane is only indexed. */
        if (![backend isAvailable]) {
            NSDebugLLog(@"gwcomp", @"[Network] %@ backend is not available", [backend backendName]);
        } else {
            NSDebugLLog(@"gwcomp", @"[Network] Using %@ backend", [backend backendName]);
        }
    }
    return self;
}

- (void)dealloc
{
    [self stopRefreshing];
    [wlanTabItem release];
    [(id)backend release];
    [interfaces release];
    [wlanNetworks release];
    [mainView release];
    /* The pulse of a default button must not outlive the button. */
    [advancedPanel setDefaultButtonCell:nil];
    [passwordPanel setDefaultButtonCell:nil];
    [joinNetworkPanel setDefaultButtonCell:nil];
    [advancedPanel release];
    [passwordPanel release];
    [joinNetworkPanel release];
    [joinNetworkJoinButton release];
    [pendingNetwork release];
    [serviceContextMenu release];
    [super dealloc];
}

#pragma mark - Main View Creation

- (NSView *)createMainView
{
    if (mainView) {
        return mainView;
    }
    
    // Use dynamic width based on what SystemPreferences provides
    // Default to kWindowWidth if no parent view exists yet
    CGFloat actualWidth = kWindowWidth;
    CGFloat actualHeight = kWindowHeight;
    
    mainView = [[NetworkMainView alloc] initWithFrame:NSMakeRect(0, 0, actualWidth, actualHeight)];
    [(NetworkMainView *)mainView setLayoutOwner:self];
    /* No autoresizing: the host's +5px-inflated contentView would otherwise
       stretch the pane past the window. viewDidMoveToWindow clamps it. */
    
    // Check if backend is available
    if (![backend isAvailable]) {
        [self createUnavailableView];
        return mainView;
    }
    
    // Get actual dimensions from mainView bounds
    NSRect viewBounds = [mainView bounds];
    CGFloat viewWidth = NSWidth(viewBounds);
    CGFloat viewHeight = NSHeight(viewBounds);
    
    // Create the split view area (HIG spacing).  No bottom button bar, so
    // the panes extend down to the bottom margin.
    CGFloat splitTop = viewHeight;
    CGFloat splitBottom = kContentBottomMargin;
    CGFloat splitHeight = splitTop - splitBottom;
    
    // Service list on the left
    [self createServiceListViewWithFrame:NSMakeRect(kContentSideMargin, splitBottom, 
                                                     kServiceListWidth, splitHeight)];
    
    // Detail view on the right (12px gap between panels)
    CGFloat detailX = kContentSideMargin + kServiceListWidth + kSpace12;
    CGFloat detailWidth = viewWidth - detailX - kContentSideMargin;
    [self createDetailViewWithFrame:NSMakeRect(detailX, splitBottom, 
                                                detailWidth, splitHeight)];
    
    /* Nothing is loaded here: the host also builds this view just to
       index its widgets for search, without ever selecting the pane.
       Data comes from -startRefreshing at selection, and the sheets are
       built on first use. */
    return mainView;
}

/* The host sizes the pane view to its content area, which is not the
   kWindowHeight we built at (it is ~11px shorter on this stack).  Keep the
   two panels filling from the bottom margin to the top of whatever height
   the view actually has, so no panel content is clipped. */
- (void)relayoutWithWidth:(CGFloat)width
{
    NSRect bounds = [mainView bounds];
    CGFloat h = NSHeight(bounds);
    CGFloat splitBottom = kContentBottomMargin;
    CGFloat splitHeight = h - splitBottom;

    if (serviceBox) {
        NSRect f = [serviceBox frame];
        f.origin.y = splitBottom;
        f.size.height = splitHeight;
        [serviceBox setFrame:f];
    }
    if (detailBox) {
        NSRect f = [detailBox frame];
        f.origin.y = splitBottom;
        f.size.height = splitHeight;
        [detailBox setFrame:f];
    }
    if (detailView) {
        /* detailView is the detailBox contentView; keep it exactly filling
           the box's content area and re-fit the status area (top-anchored)
           and the tab view (fills the rest) to the new height. */
        NSRect f = [detailView frame];
        f.size.height = splitHeight;
        [detailView setFrame:f];

        if (statusIcon) {
            NSView *statusView = [statusIcon superview];
            if (statusView) {
                NSRect sf = [statusView frame];
                sf.origin.y = NSHeight(f) - kStatusAreaHeight;
                [statusView setFrame:sf];
            }
        }
        if (detailTabView) {
            NSRect tf = [detailTabView frame];
            tf.size.height = NSHeight(f) - kStatusAreaHeight - kSpace8;
            [detailTabView setFrame:tf];
        }
    }
}

- (void)createUnavailableView
{
    CGFloat viewWidth = NSWidth([mainView bounds]);
    CGFloat viewHeight = NSHeight([mainView bounds]);
    
    NSTextField *errorLabel = [[NSTextField alloc] initWithFrame:
                               NSMakeRect(kContentSideMargin, viewHeight/2 - 40, viewWidth - kContentSideMargin*2, 80)];
    [errorLabel setStringValue:@"Network configuration is not available.\n\n"
                                "NetworkManager is required but was not found.\n"
                                "Please install the 'network-manager' package."];
    [errorLabel setBezeled:NO];
    [errorLabel setDrawsBackground:NO];
    [errorLabel setEditable:NO];
    [errorLabel setSelectable:NO];
    [errorLabel setFont:[NSFont systemFontOfSize:13]];
    [errorLabel setAlignment:NSCenterTextAlignment];
    [mainView addSubview:errorLabel];
    [errorLabel release];
}

#pragma mark - Service List View

- (void)createServiceListViewWithFrame:(NSRect)frame
{
    // Container with bezel border (standard appearance, no dark colors)
    serviceBox = [[NSBox alloc] initWithFrame:frame];
    [serviceBox setBoxType:NSBoxCustom];
    [serviceBox setBorderType:NSBezelBorder];
    [serviceBox setTitlePosition:NSNoTitle];
    [serviceBox setContentViewMargins:NSMakeSize(0, 0)];
    [mainView addSubview:serviceBox];
    [serviceBox release];
    
    // Table view for services
    CGFloat buttonAreaH = kSpace8 + kButtonHeight + kSpace8;
    NSRect tableFrame = NSMakeRect(0, buttonAreaH, frame.size.width, frame.size.height - buttonAreaH);
    serviceScrollView = [[NSScrollView alloc] initWithFrame:tableFrame];
    [serviceScrollView setHasVerticalScroller:YES];
    [serviceScrollView setHasHorizontalScroller:NO];
    [serviceScrollView setBorderType:NSBezelBorder];
    [serviceScrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    serviceTable = [[NSTableView alloc] initWithFrame:[[serviceScrollView contentView] bounds]];
    [serviceTable setDelegate:self];
    [serviceTable setDataSource:self];
    [serviceTable setRowHeight:36];
    [serviceTable setHeaderView:nil];
    [serviceTable setAllowsEmptySelection:NO];
    [serviceTable setAllowsMultipleSelection:NO];
    [serviceTable setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    
    NSTableColumn *iconColumn = [[NSTableColumn alloc] initWithIdentifier:@"icon"];
    [iconColumn setWidth:32];
    [iconColumn setMinWidth:32];
    [iconColumn setMaxWidth:32];
    [iconColumn setEditable:NO];
    [serviceTable addTableColumn:iconColumn];
    [iconColumn release];
    
    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [nameColumn setWidth:frame.size.width - 40];
    [nameColumn setMinWidth:100];
    [nameColumn setEditable:NO];
    [nameColumn setResizingMask:NSTableColumnAutoresizingMask];
    [serviceTable addTableColumn:nameColumn];
    [nameColumn release];
    
    [serviceScrollView setDocumentView:serviceTable];
    [serviceBox addSubview:serviceScrollView];
    
    // Create context menu for table
    serviceContextMenu = [[NSMenu alloc] initWithTitle:@"Service"];
    [serviceContextMenu setDelegate:self];
    NSMenuItem *enableItem = [[NSMenuItem alloc] initWithTitle:@"Enable" 
                                                         action:@selector(enableInterface:) 
                                                  keyEquivalent:@""];
    [enableItem setTarget:self];
    [serviceContextMenu addItem:enableItem];
    [enableItem release];
    
    NSMenuItem *disableItem = [[NSMenuItem alloc] initWithTitle:@"Disable" 
                                                          action:@selector(disableInterface:) 
                                                   keyEquivalent:@""];
    [disableItem setTarget:self];
    [serviceContextMenu addItem:disableItem];
    [disableItem release];
    
    [serviceTable setMenu:serviceContextMenu];
    
    // Bottom button bar with enable/disable buttons, sized to fit the panel
    CGFloat buttonY = kSpace8;
    CGFloat btnSpacing = kSpace8;
    CGFloat btnWidth = (frame.size.width - 3 * btnSpacing) / 2.0;

    enableButton = [[NSButton alloc] initWithFrame:
                    NSMakeRect(btnSpacing, buttonY, btnWidth, kButtonHeight)];
    [enableButton setBezelStyle:NSRoundedBezelStyle];
    [enableButton setTitle:@"Enable"];
    [enableButton setTarget:self];
    [enableButton setAction:@selector(enableInterface:)];
    [enableButton setEnabled:NO];
    [serviceBox addSubview:enableButton];
    
    disableButton = [[NSButton alloc] initWithFrame:
                     NSMakeRect(btnSpacing * 2 + btnWidth, buttonY, btnWidth, kButtonHeight)];
    [disableButton setBezelStyle:NSRoundedBezelStyle];
    [disableButton setTitle:@"Disable"];
    [disableButton setTarget:self];
    [disableButton setAction:@selector(disableInterface:)];
    [disableButton setEnabled:NO];
    [serviceBox addSubview:disableButton];
}

#pragma mark - Detail View

- (void)createDetailViewWithFrame:(NSRect)frame
{
    // Container with border - use standard bezel for Eau theme compliance
    detailBox = [[NSBox alloc] initWithFrame:frame];
    [detailBox setBoxType:NSBoxCustom];
    [detailBox setBorderType:NSBezelBorder];
    [detailBox setTitlePosition:NSNoTitle];
    [detailBox setContentViewMargins:NSMakeSize(0, 0)];
    [mainView addSubview:detailBox];
    [detailBox release];
    
    detailView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    [detailBox setContentView:detailView];
    
    // Status area at top of detail view
    [self createStatusAreaWithFrame:NSMakeRect(0, frame.size.height - kStatusAreaHeight, 
                                                 frame.size.width, kStatusAreaHeight)];
    
    // Tab view fills remaining space below status area
    CGFloat tabY = kSpace8;
    CGFloat tabHeight = frame.size.height - kStatusAreaHeight - tabY;
    
    detailTabView = [[NSTabView alloc] initWithFrame:
                     NSMakeRect(kSpace12, tabY, frame.size.width - kSpace12 * 2, tabHeight)];
    [detailTabView setTabViewType:NSTopTabsBezelBorder];
    [detailTabView setFont:[NSFont systemFontOfSize:11]];
    [detailTabView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    // TCP/IP tab
    NSTabViewItem *tcpipTab = [[NSTabViewItem alloc] initWithIdentifier:@"tcpip"];
    [tcpipTab setLabel:@"TCP/IP"];
    [self createTCPIPViewForTab:tcpipTab];
    [detailTabView addTabViewItem:tcpipTab];
    [tcpipTab release];
    
    // DNS tab
    NSTabViewItem *dnsTab = [[NSTabViewItem alloc] initWithIdentifier:@"dns"];
    [dnsTab setLabel:@"DNS"];
    [self createDNSViewForTab:dnsTab];
    [detailTabView addTabViewItem:dnsTab];
    [dnsTab release];
    
    /* The WLAN tab starts out present so that its widgets are in the
       view hierarchy before any interface is known (the host indexes them
       for search); updateDetailView keeps it only for wireless interfaces. */
    wlanTabItem = [[NSTabViewItem alloc] initWithIdentifier:@"wlan"];
    [wlanTabItem setLabel:@"WLAN"];
    [self createWLANViewForTab:wlanTabItem];
    [detailTabView addTabViewItem:wlanTabItem];
    
    [detailView addSubview:detailTabView];
}

- (void)createStatusAreaWithFrame:(NSRect)frame
{
    NSView *statusView = [[NSView alloc] initWithFrame:frame];
    [statusView setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    
    // Status icon
    statusIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(kSpace12, kSpace12, 48, 48)];
    [statusIcon setImageScaling:NSImageScaleProportionallyUpOrDown];
    [statusView addSubview:statusIcon];
    
    // Status label
    statusLabel = [[NSTextField alloc] initWithFrame:
                   NSMakeRect(70, 35, frame.size.width - 90, 20)];
    [statusLabel setBezeled:NO];
    [statusLabel setDrawsBackground:NO];
    [statusLabel setEditable:NO];
    [statusLabel setSelectable:NO];
    [statusLabel setFont:[NSFont boldSystemFontOfSize:13]];
    [statusLabel setStringValue:@""];
    [statusView addSubview:statusLabel];
    
    // Status detail label
    statusDetailLabel = [[NSTextField alloc] initWithFrame:
                         NSMakeRect(70, 10, frame.size.width - 90, 30)];
    [statusDetailLabel setBezeled:NO];
    [statusDetailLabel setDrawsBackground:NO];
    [statusDetailLabel setEditable:NO];
    [statusDetailLabel setSelectable:YES];
    [statusDetailLabel setFont:[NSFont systemFontOfSize:11]];
    [statusDetailLabel setTextColor:[NSColor colorWithCalibratedWhite:0.4 alpha:1.0]];
    [statusDetailLabel setStringValue:@""];
    [statusView addSubview:statusDetailLabel];
    
    [detailView addSubview:statusView];
    [statusView release];
}

- (void)createTCPIPViewForTab:(NSTabViewItem *)tab
{
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    [view setAutoresizingMask:NSViewWidthSizable];
    
    CGFloat y = NSHeight([view frame]) - kFieldHeight - kSpace8;
    CGFloat labelX = kSpace12;
    CGFloat fieldX = kSpace12 + kLabelWidth + kSpace8;
    CGFloat fieldWidth = NSWidth([view frame]) - fieldX - kSpace12;

    // Configure IPv4 popup
    NSTextField *configLabel = [[NSTextField alloc] initWithFrame:
                                 NSMakeRect(labelX, y, kLabelWidth, kFieldHeight)];
    [configLabel setStringValue:@"Configure IPv4:"];
    [configLabel setBezeled:NO];
    [configLabel setDrawsBackground:NO];
    [configLabel setEditable:NO];
    [configLabel setAlignment:NSRightTextAlignment];
    [configLabel setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:configLabel];
    [configLabel release];
    
    configureIPv4Popup = [[NSPopUpButton alloc] initWithFrame:
                          NSMakeRect(fieldX, y, fieldWidth, kFieldHeight)];
    [configureIPv4Popup addItemWithTitle:@"Using DHCP"];
    [configureIPv4Popup addItemWithTitle:@"Manually"];
    [configureIPv4Popup addItemWithTitle:@"Off"];
    [configureIPv4Popup setTarget:self];
    [configureIPv4Popup setAction:@selector(configureIPv4Changed:)];
    [configureIPv4Popup setAutoresizingMask:NSViewWidthSizable];
    [view addSubview:configureIPv4Popup];
    
    y -= kFieldHeight + kSpace8;
    
    // IP Address
    NSTextField *ipLabel = [[NSTextField alloc] initWithFrame:
                            NSMakeRect(labelX, y, kLabelWidth, kFieldHeight)];
    [ipLabel setStringValue:@"IP Address:"];
    [ipLabel setBezeled:NO];
    [ipLabel setDrawsBackground:NO];
    [ipLabel setEditable:NO];
    [ipLabel setAlignment:NSRightTextAlignment];
    [ipLabel setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:ipLabel];
    [ipLabel release];
    
    ipAddressField = [[NSTextField alloc] initWithFrame:
                      NSMakeRect(fieldX, y, fieldWidth, kFieldHeight)];
    [ipAddressField setEditable:NO];
    [ipAddressField setPlaceholderString:@""];
    [ipAddressField setAutoresizingMask:NSViewWidthSizable];
    [view addSubview:ipAddressField];
    
    y -= kFieldHeight + kSpace8;
    
    // Subnet Mask
    NSTextField *subnetLabel = [[NSTextField alloc] initWithFrame:
                                NSMakeRect(labelX, y, kLabelWidth, kFieldHeight)];
    [subnetLabel setStringValue:@"Subnet Mask:"];
    [subnetLabel setBezeled:NO];
    [subnetLabel setDrawsBackground:NO];
    [subnetLabel setEditable:NO];
    [subnetLabel setAlignment:NSRightTextAlignment];
    [subnetLabel setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:subnetLabel];
    [subnetLabel release];
    
    subnetMaskField = [[NSTextField alloc] initWithFrame:
                       NSMakeRect(fieldX, y, fieldWidth, kFieldHeight)];
    [subnetMaskField setEditable:NO];
    [subnetMaskField setPlaceholderString:@""];
    [subnetMaskField setAutoresizingMask:NSViewWidthSizable];
    [view addSubview:subnetMaskField];
    
    y -= kFieldHeight + kSpace8;
    
    // Router
    NSTextField *routerLabel = [[NSTextField alloc] initWithFrame:
                                NSMakeRect(labelX, y, kLabelWidth, kFieldHeight)];
    [routerLabel setStringValue:@"Router:"];
    [routerLabel setBezeled:NO];
    [routerLabel setDrawsBackground:NO];
    [routerLabel setEditable:NO];
    [routerLabel setAlignment:NSRightTextAlignment];
    [routerLabel setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:routerLabel];
    [routerLabel release];
    
    routerField = [[NSTextField alloc] initWithFrame:
                   NSMakeRect(fieldX, y, fieldWidth, kFieldHeight)];
    [routerField setEditable:NO];
    [routerField setPlaceholderString:@""];
    [routerField setAutoresizingMask:NSViewWidthSizable];
    [view addSubview:routerField];
    
    y -= 28;
    
    // Configure IPv6 popup
    NSTextField *config6Label = [[NSTextField alloc] initWithFrame:
                                 NSMakeRect(labelX, y, kLabelWidth, kFieldHeight)];
    [config6Label setStringValue:@"Configure IPv6:"];
    [config6Label setBezeled:NO];
    [config6Label setDrawsBackground:NO];
    [config6Label setEditable:NO];
    [config6Label setAlignment:NSRightTextAlignment];
    [config6Label setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:config6Label];
    [config6Label release];
    
    configureIPv6Popup = [[NSPopUpButton alloc] initWithFrame:
                          NSMakeRect(fieldX, y, fieldWidth, kFieldHeight)];
    [configureIPv6Popup addItemWithTitle:@"Automatically"];
    [configureIPv6Popup addItemWithTitle:@"Manually"];
    [configureIPv6Popup addItemWithTitle:@"Link-local only"];
    [configureIPv6Popup addItemWithTitle:@"Off"];
    [configureIPv6Popup setTarget:self];
    [configureIPv6Popup setAction:@selector(configureIPv6Changed:)];
    [configureIPv6Popup setAutoresizingMask:NSViewWidthSizable];
    [view addSubview:configureIPv6Popup];
    
    y -= kFieldHeight + kSpace8;
    
    // IPv6 Address (display only for now)
    NSTextField *ipv6Label = [[NSTextField alloc] initWithFrame:
                              NSMakeRect(labelX, y, kLabelWidth, kFieldHeight)];
    [ipv6Label setStringValue:@"IPv6 Address:"];
    [ipv6Label setBezeled:NO];
    [ipv6Label setDrawsBackground:NO];
    [ipv6Label setEditable:NO];
    [ipv6Label setAlignment:NSRightTextAlignment];
    [ipv6Label setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:ipv6Label];
    [ipv6Label release];
    
    ipv6AddressField = [[NSTextField alloc] initWithFrame:
                        NSMakeRect(fieldX, y, fieldWidth, kFieldHeight)];
    [ipv6AddressField setEditable:NO];
    [ipv6AddressField setPlaceholderString:@""];
    [ipv6AddressField setAutoresizingMask:NSViewWidthSizable];
    [view addSubview:ipv6AddressField];
    
    y -= kFieldHeight + kSpace8;
    
    // Renew DHCP Lease button
    dhcpLeaseButton = [[NSButton alloc] initWithFrame:
                       NSMakeRect(fieldX, y, 150, kButtonHeight)];
    [dhcpLeaseButton setBezelStyle:NSRoundedBezelStyle];
    [dhcpLeaseButton setTitle:@"Renew DHCP Lease"];
    [dhcpLeaseButton setTarget:self];
    [dhcpLeaseButton setAction:@selector(renewDHCPLease:)];
    [dhcpLeaseButton setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:dhcpLeaseButton];
    
    [tab setView:view];
    [view release];
}

- (void)createDNSViewForTab:(NSTabViewItem *)tab
{
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 180)];
    [view setAutoresizingMask:NSViewWidthSizable];
    
    CGFloat y = NSHeight([view frame]) - kFieldHeight - kSpace8;
    CGFloat labelX = kSpace12;
    CGFloat fieldX = kSpace12 + kLabelWidth + kSpace8;
    CGFloat fieldWidth = NSWidth([view frame]) - fieldX - kSpace12;
    
    // DNS Servers
    NSTextField *dnsLabel = [[NSTextField alloc] initWithFrame:
                             NSMakeRect(labelX, y, kLabelWidth, kFieldHeight)];
    [dnsLabel setStringValue:@"DNS Servers:"];
    [dnsLabel setBezeled:NO];
    [dnsLabel setDrawsBackground:NO];
    [dnsLabel setEditable:NO];
    [dnsLabel setAlignment:NSRightTextAlignment];
    [dnsLabel setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:dnsLabel];
    [dnsLabel release];
    
    dnsServersField = [[NSTextField alloc] initWithFrame:
                       NSMakeRect(fieldX, y, fieldWidth, kFieldHeight)];
    [dnsServersField setEditable:NO];
    [dnsServersField setPlaceholderString:@"e.g., 8.8.8.8, 8.8.4.4"];
    [dnsServersField setAutoresizingMask:NSViewWidthSizable];
    [view addSubview:dnsServersField];
    
    y -= kFieldHeight + kSpace8;
    
    // Search Domains
    NSTextField *searchLabel = [[NSTextField alloc] initWithFrame:
                                NSMakeRect(labelX, y, kLabelWidth, kFieldHeight)];
    [searchLabel setStringValue:@"Search Domains:"];
    [searchLabel setBezeled:NO];
    [searchLabel setDrawsBackground:NO];
    [searchLabel setEditable:NO];
    [searchLabel setAlignment:NSRightTextAlignment];
    [searchLabel setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:searchLabel];
    [searchLabel release];
    
    searchDomainsField = [[NSTextField alloc] initWithFrame:
                          NSMakeRect(fieldX, y, fieldWidth, kFieldHeight)];
    [searchDomainsField setEditable:NO];
    [searchDomainsField setPlaceholderString:@"e.g., local, home"];
    [searchDomainsField setAutoresizingMask:NSViewWidthSizable];
    [view addSubview:searchDomainsField];
    
    [tab setView:view];
    [view release];
}

- (void)createWLANViewForTab:(NSTabViewItem *)tab
{
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    [view setAutoresizingMask:NSViewWidthSizable];
    wlanView = view;
    
    // WLAN power button (top)
    wlanPowerButton = [[NSButton alloc] initWithFrame:NSMakeRect(10, 272, 130, kButtonHeight)];
    [wlanPowerButton setBezelStyle:NSRoundedBezelStyle];
    [wlanPowerButton setTitle:@"Turn WLAN Off"];
    [wlanPowerButton setTarget:self];
    [wlanPowerButton setAction:@selector(toggleWLANPower:)];
    [wlanPowerButton setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:wlanPowerButton];
    
    // Scan progress indicator
    scanProgress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(150, 273, 16, 16)];
    [scanProgress setStyle:NSProgressIndicatorSpinningStyle];
    [scanProgress setDisplayedWhenStopped:NO];
    [scanProgress setControlSize:NSSmallControlSize];
    [scanProgress setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:scanProgress];
    
    // Network Name label
    NSTextField *networkLabel = [[NSTextField alloc] initWithFrame:
                                  NSMakeRect(10, 242, 100, kFieldHeight)];
    [networkLabel setStringValue:@"Network Name:"];
    [networkLabel setBezeled:NO];
    [networkLabel setDrawsBackground:NO];
    [networkLabel setEditable:NO];
    [networkLabel setFont:[NSFont systemFontOfSize:11]];
    [networkLabel setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:networkLabel];
    [networkLabel release];
    
    // WLAN network table (fills the space above the bottom row)
    wlanScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, 35, 380, 199)];
    [wlanScrollView setHasVerticalScroller:YES];
    [wlanScrollView setHasHorizontalScroller:NO];
    [wlanScrollView setBorderType:NSBezelBorder];
    [wlanScrollView setAutoresizingMask:NSViewWidthSizable];
    
    wlanTable = [[NSTableView alloc] initWithFrame:[[wlanScrollView contentView] bounds]];
    [wlanTable setDelegate:self];
    [wlanTable setDataSource:self];
    [wlanTable setRowHeight:17];  // Smaller row height for compact display
    [wlanTable setAllowsEmptySelection:YES];
    [wlanTable setDoubleAction:@selector(wlanTableDoubleClicked:)];
    [wlanTable setTarget:self];
    [wlanTable setFont:[NSFont systemFontOfSize:11]];  // Use small font
    [wlanTable setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    NSTableColumn *signalColumn = [[NSTableColumn alloc] initWithIdentifier:@"signal"];
    [signalColumn setWidth:40];
    [signalColumn setEditable:NO];
    [[signalColumn headerCell] setStringValue:@""];
    [wlanTable addTableColumn:signalColumn];
    [signalColumn release];
    
    NSTableColumn *ssidColumn = [[NSTableColumn alloc] initWithIdentifier:@"ssid"];
    [ssidColumn setWidth:200];
    [ssidColumn setEditable:NO];
    [[ssidColumn headerCell] setStringValue:@"Network"];
    [[ssidColumn headerCell] setFont:[NSFont systemFontOfSize:11]];
    [wlanTable addTableColumn:ssidColumn];
    [ssidColumn release];
    
    NSTableColumn *securityColumn = [[NSTableColumn alloc] initWithIdentifier:@"security"];
    [securityColumn setWidth:80];
    [securityColumn setEditable:NO];
    [[securityColumn headerCell] setStringValue:@"Security"];
    [[securityColumn headerCell] setFont:[NSFont systemFontOfSize:11]];
    [wlanTable addTableColumn:securityColumn];
    [securityColumn release];
    
    NSTableColumn *statusColumn = [[NSTableColumn alloc] initWithIdentifier:@"status"];
    [statusColumn setWidth:60];
    [statusColumn setEditable:NO];
    [[statusColumn headerCell] setStringValue:@""];
    [wlanTable addTableColumn:statusColumn];
    [statusColumn release];
    
    [wlanScrollView setDocumentView:wlanTable];
    [view addSubview:wlanScrollView];
    
    // Bottom buttons
    joinNetworkButton = [[NSButton alloc] initWithFrame:NSMakeRect(10, 5, 50, kButtonHeight)];
    [joinNetworkButton setBezelStyle:NSRoundedBezelStyle];
    [joinNetworkButton setTitle:@"Join"];
    [joinNetworkButton setTarget:self];
    [joinNetworkButton setAction:@selector(joinNetwork:)];
    [joinNetworkButton setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:joinNetworkButton];
    
    disconnectButton = [[NSButton alloc] initWithFrame:NSMakeRect(68, 5, 80, kButtonHeight)];
    [disconnectButton setBezelStyle:NSRoundedBezelStyle];
    [disconnectButton setTitle:@"Disconnect"];
    [disconnectButton setTarget:self];
    [disconnectButton setAction:@selector(disconnectWLAN:)];
    [disconnectButton setAutoresizingMask:NSViewMaxXMargin];
    [view addSubview:disconnectButton];
    
    // MAC Address cloning popup, right-aligned (aligned with the buttons)
    const CGFloat macPopupW = 135;
    const CGFloat macLabelW = 40;
    CGFloat macPopupX = NSWidth([view frame]) - 10 - macPopupW;
    clonedMacPopup = [[NSPopUpButton alloc] initWithFrame:
        NSMakeRect(macPopupX, 5, macPopupW, kButtonHeight)];
    [[clonedMacPopup menu] removeAllItems];
    [clonedMacPopup addItemWithTitle:@"Default (Permanent)"];
    [[clonedMacPopup lastItem] setRepresentedObject:@"permanent"];
    [clonedMacPopup addItemWithTitle:@"Random"];
    [[clonedMacPopup lastItem] setRepresentedObject:@"random"];
    [clonedMacPopup addItemWithTitle:@"Stable"];
    [[clonedMacPopup lastItem] setRepresentedObject:@"stable"];
    [clonedMacPopup addItemWithTitle:@"Preserve"];
    [[clonedMacPopup lastItem] setRepresentedObject:@"preserve"];
    [clonedMacPopup setTarget:self];
    [clonedMacPopup setAction:@selector(clonedMacChanged:)];
    [clonedMacPopup setAutoresizingMask:NSViewMinXMargin];
    [clonedMacPopup setEnabled:NO];
    [view addSubview:clonedMacPopup];
    [clonedMacPopup release];

    clonedMacLabel = [[NSTextField alloc] initWithFrame:
        NSMakeRect(macPopupX - kSpace8 - macLabelW, 5, macLabelW, kButtonHeight)];
    [clonedMacLabel setStringValue:@"MAC:"];
    [clonedMacLabel setBezeled:NO];
    [clonedMacLabel setDrawsBackground:NO];
    [clonedMacLabel setEditable:NO];
    [clonedMacLabel setFont:[NSFont systemFontOfSize:11]];
    [clonedMacLabel setAutoresizingMask:NSViewMinXMargin];
    [view addSubview:clonedMacLabel];
    [clonedMacLabel release];
    
    [tab setView:view];
}

#pragma mark - Password Panel

- (void)createPasswordPanel
{
    // 24 px for the window edges and the icon, the text column starts at 104.
    const CGFloat width = 480;
    const CGFloat textLeft = METRICS_TEXT_LEFT;
    const CGFloat right = width - METRICS_CONTENT_SIDE_MARGIN;
    const CGFloat labelWidth = DialogTextWidth(@"Password:", [NSFont systemFontOfSize:13]);
    const CGFloat fieldLeft = textLeft + labelWidth + METRICS_SPACE_8;

    // Height from the top down: icon margin, title, info, field row, checkbox
    // row, gap between groups, button, bottom margin.
    const CGFloat height = METRICS_ICON_TOP + kDialogTitleHeight + METRICS_TITLE_MESSAGE_GAP
        + kDialogInfoHeight + METRICS_SPACE_16 + METRICS_TEXT_INPUT_FIELD_HEIGHT
        + METRICS_SPACE_16 + METRICS_RADIO_BUTTON_SIZE + METRICS_SPACE_20
        + METRICS_BUTTON_HEIGHT + METRICS_CONTENT_BOTTOM_MARGIN;

    passwordPanel = DialogPanel(@"Enter Password", NSMakeSize(width, height));
    NSView *content = [passwordPanel contentView];

    CGFloat y = height - METRICS_ICON_TOP;

    // The pane's own icon: the lock image this used to ask for is not shipped.
    NSImageView *icon = [[NSImageView alloc] initWithFrame:
        NSMakeRect(METRICS_ICON_LEFT, y - METRICS_ICON_SIDE, METRICS_ICON_SIDE, METRICS_ICON_SIDE)];
    NSString *iconPath = [[NSBundle bundleForClass:[NetworkController class]]
                          pathForImageResource:@"Network"];
    NSImage *iconImage = [[NSImage alloc] initWithContentsOfFile:iconPath];
    [icon setImage:iconImage];
    [iconImage release];
    [icon setImageScaling:NSImageScaleProportionallyUpOrDown];
    [content addSubview:icon];
    [icon release];

    y -= kDialogTitleHeight;
    passwordSSIDLabel = [DialogSingleLineLabel(@"", [NSFont boldSystemFontOfSize:13],
        NSMakeRect(textLeft, y, right - textLeft, kDialogTitleHeight)) retain];
    [content addSubview:passwordSSIDLabel];

    y -= METRICS_TITLE_MESSAGE_GAP + kDialogInfoHeight;
    [content addSubview:DialogSingleLineLabel(@"This WLAN network requires a password.",
        [NSFont systemFontOfSize:11],
        NSMakeRect(textLeft, y, right - textLeft, kDialogInfoHeight))];

    y -= METRICS_SPACE_16 + METRICS_TEXT_INPUT_FIELD_HEIGHT;
    [content addSubview:DialogLabel(@"Password:", [NSFont systemFontOfSize:13], NSRightTextAlignment,
        NSMakeRect(textLeft, y + kDialogLabelInset, labelWidth, kDialogTitleHeight))];

    passwordField = [[NSSecureTextField alloc] initWithFrame:
        NSMakeRect(fieldLeft, y, right - fieldLeft, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
    // The Join button follows what has been typed.
    [passwordField setDelegate:self];
    [content addSubview:passwordField];

    y -= METRICS_SPACE_16 + METRICS_RADIO_BUTTON_SIZE;
    rememberPasswordCheckbox = [[NSButton alloc] initWithFrame:
        NSMakeRect(fieldLeft, y, right - fieldLeft, METRICS_RADIO_BUTTON_SIZE)];
    [rememberPasswordCheckbox setButtonType:NSSwitchButton];
    [rememberPasswordCheckbox setTitle:@"Remember this network"];
    [rememberPasswordCheckbox setState:NSOnState];
    [content addSubview:rememberPasswordCheckbox];

    passwordCancelButton = [DialogButton(@"Cancel", self, @selector(passwordCancel:), @"\033") retain];
    passwordConnectButton = [DialogButton(@"Join", self, @selector(passwordConnect:), @"\r") retain];
    [passwordConnectButton setEnabled:NO];
    DialogPlaceButtons(passwordPanel,
        [NSArray arrayWithObjects:passwordCancelButton, passwordConnectButton, nil]);

    // Typing goes first; Tab then reaches the option and the buttons.
    [passwordPanel setInitialFirstResponder:passwordField];
    [passwordField setNextKeyView:rememberPasswordCheckbox];
    [rememberPasswordCheckbox setNextKeyView:passwordCancelButton];
    [passwordCancelButton setNextKeyView:passwordConnectButton];
    [passwordConnectButton setNextKeyView:passwordField];
}

#pragma mark - Join Other Network Panel

- (void)createJoinNetworkPanel
{
    NSFont *font = [NSFont systemFontOfSize:13];
    const CGFloat labelWidth = MAX(DialogTextWidth(@"Network name:", font),
                                   DialogTextWidth(@"Security:", font));
    const CGFloat fieldLeft = METRICS_CONTENT_SIDE_MARGIN + labelWidth + METRICS_SPACE_8;

    NSButton *cancelButton = DialogButton(@"Cancel", self, @selector(joinOtherNetworkCancel:), @"\033");
    joinNetworkJoinButton = [DialogButton(@"Join", self, @selector(joinOtherNetworkConfirm:), @"\r") retain];
    NSArray *buttons = [NSArray arrayWithObjects:cancelButton, joinNetworkJoinButton, nil];

    // Wide enough for the button row, and for a network name of a usual length.
    const CGFloat width = MAX(DialogButtonsWidth(buttons) + 2 * METRICS_CONTENT_SIDE_MARGIN, 420);
    const CGFloat right = width - METRICS_CONTENT_SIDE_MARGIN;

    // The first row is a field, the second a pop-up: 20 px below the top
    // edge, 16 px between rows, 20 px above the buttons.
    const CGFloat height = METRICS_SPACE_20 + METRICS_TEXT_INPUT_FIELD_HEIGHT
        + METRICS_SPACE_16 + METRICS_TEXT_INPUT_FIELD_HEIGHT + METRICS_SPACE_20
        + METRICS_BUTTON_HEIGHT + METRICS_CONTENT_BOTTOM_MARGIN;

    joinNetworkPanel = DialogPanel(@"Join Other Network", NSMakeSize(width, height));
    NSView *content = [joinNetworkPanel contentView];

    CGFloat y = height - METRICS_SPACE_20 - METRICS_TEXT_INPUT_FIELD_HEIGHT;
    [content addSubview:DialogLabel(@"Network name:", font, NSRightTextAlignment,
        NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, y + kDialogLabelInset, labelWidth, kDialogTitleHeight))];
    joinNetworkSSIDField = [[NSTextField alloc] initWithFrame:
        NSMakeRect(fieldLeft, y, right - fieldLeft, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
    // The Join button follows what has been typed.
    [joinNetworkSSIDField setDelegate:self];
    [content addSubview:joinNetworkSSIDField];

    y -= METRICS_SPACE_16 + METRICS_TEXT_INPUT_FIELD_HEIGHT;
    [content addSubview:DialogLabel(@"Security:", font, NSRightTextAlignment,
        NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, y + kDialogLabelInset, labelWidth, kDialogTitleHeight))];
    joinNetworkSecurityPopup = [[NSPopUpButton alloc] initWithFrame:
        NSMakeRect(fieldLeft, y, right - fieldLeft, METRICS_TEXT_INPUT_FIELD_HEIGHT) pullsDown:NO];
    [joinNetworkSecurityPopup addItemWithTitle:@"None"];
    [joinNetworkSecurityPopup addItemWithTitle:@"WPA/WPA2 Personal"];
    [joinNetworkSecurityPopup addItemWithTitle:@"WPA2/WPA3 Personal"];
    [joinNetworkSecurityPopup addItemWithTitle:@"WPA Enterprise"];
    [content addSubview:joinNetworkSecurityPopup];

    [joinNetworkJoinButton setEnabled:NO];
    DialogPlaceButtons(joinNetworkPanel, buttons);

    [joinNetworkPanel setInitialFirstResponder:joinNetworkSSIDField];
    [joinNetworkSSIDField setNextKeyView:joinNetworkSecurityPopup];
    [joinNetworkSecurityPopup setNextKeyView:cancelButton];
    [cancelButton setNextKeyView:joinNetworkJoinButton];
    [joinNetworkJoinButton setNextKeyView:joinNetworkSSIDField];
}

#pragma mark - Advanced Panel

- (void)createAdvancedPanel
{
    NSButton *cancelButton = DialogButton(@"Cancel", self, @selector(closeAdvanced:), @"\033");
    NSButton *doneButton = DialogButton(@"Done", self, @selector(closeAdvanced:), @"\r");
    NSArray *buttons = [NSArray arrayWithObjects:cancelButton, doneButton, nil];

    const CGFloat width = 550;
    const CGFloat height = 400;
    advancedPanel = DialogPanel(@"Advanced", NSMakeSize(width, height));
    NSView *content = [advancedPanel contentView];
    DialogPlaceButtons(advancedPanel, buttons);

    // The tab view takes the whole area above the button row: 16 px below
    // the top edge, 24 px from the sides, 20 px above the buttons.
    const CGFloat tabBottom = METRICS_CONTENT_BOTTOM_MARGIN + METRICS_BUTTON_HEIGHT + METRICS_SPACE_20;
    advancedTabView = [[NSTabView alloc] initWithFrame:
        NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, tabBottom,
                   width - 2 * METRICS_CONTENT_SIDE_MARGIN,
                   height - METRICS_SPACE_16 - tabBottom)];
    [advancedTabView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    // TCP/IP tab
    NSTabViewItem *tcpipTab = [[NSTabViewItem alloc] initWithIdentifier:@"tcpip"];
    [tcpipTab setLabel:@"TCP/IP"];
    [advancedTabView addTabViewItem:tcpipTab];
    [tcpipTab release];
    
    // DNS tab
    NSTabViewItem *dnsTab = [[NSTabViewItem alloc] initWithIdentifier:@"dns"];
    [dnsTab setLabel:@"DNS"];
    [advancedTabView addTabViewItem:dnsTab];
    [dnsTab release];
    
    // Proxies tab
    NSTabViewItem *proxiesTab = [[NSTabViewItem alloc] initWithIdentifier:@"proxies"];
    [proxiesTab setLabel:@"Proxies"];
    [advancedTabView addTabViewItem:proxiesTab];
    [proxiesTab release];
    
    // 802.1X tab
    NSTabViewItem *dot1xTab = [[NSTabViewItem alloc] initWithIdentifier:@"8021x"];
    [dot1xTab setLabel:@"802.1X"];
    [advancedTabView addTabViewItem:dot1xTab];
    [dot1xTab release];
    
    [content addSubview:advancedTabView];
}

#pragma mark - Refresh and Data

- (void)startRefreshing
{
    [self refreshInterfaces:nil];
    if (!refreshTimer) {
        refreshTimer = [[NSTimer scheduledTimerWithTimeInterval:5.0
                                                         target:self
                                                       selector:@selector(refreshInterfaces:)
                                                       userInfo:nil
                                                        repeats:YES] retain];
    }
}

- (void)stopRefreshing
{
    if (refreshTimer) {
        [refreshTimer invalidate];
        [refreshTimer release];
        refreshTimer = nil;
    }
    /* updateDetailView restarts WLAN scanning on the next selection, so an
       unselected pane must not keep scanning in the background. */
    [self stopWLANRefreshTimer];
}

- (void)refreshInterfaces:(NSTimer *)timer
{
    @try {
        NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: starting...");
        
        if (!backend) {
            NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: backend is nil");
            return;
        }
        
        if (![backend isAvailable]) {
            NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: backend not available");
            return;
        }
        
        NSArray *newInterfaces = [backend availableInterfaces];
        if (!newInterfaces) {
            NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: newInterfaces is nil");
            newInterfaces = [NSArray array];
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: got %lu interfaces", (unsigned long)[newInterfaces count]);
        
        if (!interfaces) {
            NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: ERROR - interfaces array is nil!");
            return;
        }
        
        // Try to preserve the selected interface by name
        NSString *selectedName = selectedInterface ? [selectedInterface name] : nil;
        
        [interfaces removeAllObjects];
        [interfaces addObjectsFromArray:newInterfaces];
        
        // Try to find the same interface in the new list by name
        if (selectedName) {
            NetworkInterface *foundInterface = nil;
            for (NetworkInterface *iface in interfaces) {
                if ([[iface name] isEqualToString:selectedName]) {
                    foundInterface = iface;
                    break;
                }
            }
            
            if (foundInterface) {
                selectedInterface = foundInterface;
                NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: preserved selection of '%@'", selectedName);
            } else {
                NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: selected interface '%@' no longer available", selectedName);
                selectedInterface = nil;
            }
        }
        
        // If no selection, select first interface
        if (!selectedInterface && [interfaces count] > 0) {
            selectedInterface = [interfaces objectAtIndex:0];
            NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: auto-selected first interface '%@'", [selectedInterface name]);
        }
        
        if (!serviceTable) {
            NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: serviceTable is nil");
            return;
        }
        
        [serviceTable reloadData];
        
        // Ensure table selection matches selectedInterface
        if (selectedInterface) {
            NSInteger index = [interfaces indexOfObject:selectedInterface];
            if (index != NSNotFound) {
                [serviceTable selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
                NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: synchronized table selection to row %ld", (long)index);
            }
        }
        
        [self updateDetailView];
        [self updateStatusDisplay];
        
        NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: complete");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] refreshInterfaces: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

- (void)refreshWLANNetworks
{
    if (!backend || ![backend isAvailable]) {
        return;
    }
    
    [scanProgress startAnimation:nil];
    
    // Perform scan in background using NSThread
    [self performSelectorInBackground:@selector(doWLANScanInBackground) withObject:nil];
}

- (void)startWLANRefreshTimer
{
    [self stopWLANRefreshTimer];
    
    // Refresh WLAN networks every 10 seconds
    wlanRefreshTimer = [[NSTimer scheduledTimerWithTimeInterval:10.0
                                                         target:self
                                                       selector:@selector(wlanRefreshTimerFired:)
                                                       userInfo:nil
                                                        repeats:YES] retain];
}

- (void)stopWLANRefreshTimer
{
    if (wlanRefreshTimer) {
        [wlanRefreshTimer invalidate];
        [wlanRefreshTimer release];
        wlanRefreshTimer = nil;
    }
}

- (void)wlanRefreshTimerFired:(NSTimer *)timer
{
    @try {
        if (selectedInterface && [selectedInterface type] == NetworkInterfaceTypeWLAN) {
            [self refreshWLANNetworks];
            [self updateClonedMacPopup];
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] wlanRefreshTimerFired: EXCEPTION: %@ - %@",
                    [exception name], [exception reason]);
    }
}

- (void)doWLANScanInBackground
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSArray *networks = [backend scanForWLANs];
    
    // Update UI on main thread
    [self performSelectorOnMainThread:@selector(wlanScanCompleted:) 
                           withObject:networks 
                        waitUntilDone:NO];
    
    [pool release];
}

- (void)wlanScanCompleted:(NSArray *)networks
{
    @try {
        if (!wlanNetworks) {
            NSDebugLLog(@"gwcomp", @"[Network] wlanScanCompleted: wlanNetworks is nil!");
            return;
        }
        
        [wlanNetworks removeAllObjects];
        if (networks && [networks count] > 0) {
            [wlanNetworks addObjectsFromArray:networks];
            NSDebugLLog(@"gwcomp", @"[Network] wlanScanCompleted: added %lu networks", (unsigned long)[networks count]);
        }
        
        if (wlanTable) {
            [wlanTable reloadData];
        }
        
        if (scanProgress) {
            [scanProgress stopAnimation:nil];
        }

        [self updateClonedMacPopup];
        
        NSDebugLLog(@"gwcomp", @"[Network] wlanScanCompleted: done");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] wlanScanCompleted: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

- (void)updateStatusDisplay
{
    @try {
        if (!selectedInterface) {
            if (statusLabel) [statusLabel setStringValue:@"No Network Services"];
            if (statusDetailLabel) [statusDetailLabel setStringValue:@""];
            if (statusIcon) [statusIcon setImage:nil];
            return;
        }
        
        if (![interfaces containsObject:selectedInterface]) {
            if (statusLabel) [statusLabel setStringValue:@"No Network Services"];
            if (statusDetailLabel) [statusDetailLabel setStringValue:@""];
            if (statusIcon) [statusIcon setImage:nil];
            return;
        }
        
        // Set status icon
        NSImage *icon = [self statusIconForInterface:selectedInterface];
        if (statusIcon && icon) {
            [statusIcon setImage:icon];
        }
        
        // Set status text
        NSString *stateStr = [selectedInterface stateString];
        if (statusLabel && stateStr) {
            [statusLabel setStringValue:[NSString stringWithFormat:@"%@: %@", 
                                         [selectedInterface displayName], stateStr]];
        }
        
        // Set detail text
        NSString *detail = [self descriptionForInterface:selectedInterface];
        if (statusDetailLabel && detail) {
            [statusDetailLabel setStringValue:detail];
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] updateStatusDisplay: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

- (void)updateEnableDisableButtons
{
    @try {
        if (!selectedInterface) {
            [enableButton setEnabled:NO];
            [disableButton setEnabled:NO];
            return;
        }
        
        BOOL isEnabled = [selectedInterface isEnabled];
        BOOL isActive = [selectedInterface isActive];
        
        // Enable button is available when interface is disabled
        [enableButton setEnabled:!isEnabled];
        
        // Disable button is available when interface is enabled
        [disableButton setEnabled:isEnabled || isActive];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] updateEnableDisableButtons: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

/* The WLAN tab item exists from view creation on (see
   createDetailViewWithFrame:) but is only shown while a wireless interface
   is selected. */
- (void)setWLANTabShown:(BOOL)shown
{
    BOOL present = ([detailTabView indexOfTabViewItem:wlanTabItem] != NSNotFound);

    if (shown) {
        if (!present) {
            [detailTabView addTabViewItem:wlanTabItem];
        }
        // Select WLAN only when it appears; on later refreshes keep the
        // tab the user is currently on.
        if (!wlanTabShown) {
            [detailTabView selectTabViewItem:wlanTabItem];
        }
    } else {
        if (present) {
            [detailTabView removeTabViewItem:wlanTabItem];
        }
        [detailTabView selectTabViewItemWithIdentifier:@"tcpip"];
    }
    wlanTabShown = shown;
}

- (void)updateDetailView
{
    @try {
        if (!selectedInterface) {
            NSDebugLLog(@"gwcomp", @"[Network] updateDetailView: no interface selected");
            [self setWLANTabShown:NO];
            return;
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] updateDetailView: updating for interface '%@' (type=%d)", 
              [selectedInterface name], (int)[selectedInterface type]);
        
        if (![interfaces containsObject:selectedInterface]) {
            NSDebugLLog(@"gwcomp", @"[Network] updateDetailView: WARNING - selected interface not in list, trying to find by name");
            // Try to find by name
            NSString *name = [selectedInterface name];
            BOOL found = NO;
            for (NetworkInterface *iface in interfaces) {
                if ([[iface name] isEqualToString:name]) {
                    selectedInterface = iface;
                    found = YES;
                    NSDebugLLog(@"gwcomp", @"[Network] updateDetailView: found matching interface by name");
                    break;
                }
            }
            
            if (!found) {
                NSDebugLLog(@"gwcomp", @"[Network] updateDetailView: interface really not in list, clearing");
                selectedInterface = nil;
                [self setWLANTabShown:NO];
                return;
            }
        }
        
        // Update TCP/IP fields
        IPConfiguration *ipv4 = [selectedInterface ipv4Config];
        if (ipv4) {
            NSString *addr = [ipv4 address];
            if (ipAddressField && addr) [ipAddressField setStringValue:addr];
            
            NSString *mask = [ipv4 subnetMask];
            if (subnetMaskField && mask) [subnetMaskField setStringValue:mask];
            
            NSString *gw = [ipv4 router];
            if (routerField && gw) [routerField setStringValue:gw];
            
            NSArray *dns = [ipv4 dnsServers];
            if (dnsServersField) {
                if (dns && [dns count] > 0) {
                    [dnsServersField setStringValue:[dns componentsJoinedByString:@", "]];
                } else {
                    [dnsServersField setStringValue:@""];
                }
            }
            
            NSArray *search = [ipv4 searchDomains];
            if (searchDomainsField) {
                if (search && [search count] > 0) {
                    [searchDomainsField setStringValue:[search componentsJoinedByString:@", "]];
                } else {
                    [searchDomainsField setStringValue:@""];
                }
            }
            
            // Set configure popup
            if (configureIPv4Popup) {
                switch ([ipv4 method]) {
                    case IPConfigMethodDHCP:
                        [configureIPv4Popup selectItemAtIndex:0];
                        break;
                    case IPConfigMethodManual:
                        [configureIPv4Popup selectItemAtIndex:1];
                        break;
                    case IPConfigMethodDisabled:
                        [configureIPv4Popup selectItemAtIndex:2];
                        break;
                    default:
                        [configureIPv4Popup selectItemAtIndex:0];
                        break;
                }
            }
        }
        
        // Update IPv6 fields
        IPConfiguration *ipv6 = [selectedInterface ipv6Config];
        if (ipv6) {
            NSString *addr6 = [ipv6 address];
            if (ipv6AddressField) {
                [ipv6AddressField setStringValue:addr6 ? addr6 : @""];
            }
            
            // Set configure popup for IPv6
            if (configureIPv6Popup) {
                switch ([ipv6 method]) {
                    case IPConfigMethodDHCP:  // Automatically
                        [configureIPv6Popup selectItemAtIndex:0];
                        break;
                    case IPConfigMethodManual:
                        [configureIPv6Popup selectItemAtIndex:1];
                        break;
                    case IPConfigMethodLinkLocal:
                        [configureIPv6Popup selectItemAtIndex:2];
                        break;
                    case IPConfigMethodDisabled:
                        [configureIPv6Popup selectItemAtIndex:3];
                        break;
                    default:
                        [configureIPv6Popup selectItemAtIndex:0];
                        break;
                }
            }
        } else {
            // No IPv6 config, clear fields
            if (ipv6AddressField) [ipv6AddressField setStringValue:@""];
            if (configureIPv6Popup) [configureIPv6Popup selectItemAtIndex:0];
        }
        
        if ([selectedInterface type] == NetworkInterfaceTypeWLAN) {
            [self setWLANTabShown:YES];
            
            if (backend) {
                BOOL wlanOn = [backend isWLANEnabled];
                if (wlanPowerButton) {
                    [wlanPowerButton setTitle:wlanOn ? @"Turn WLAN Off" : @"Turn WLAN On"];
                }
                
                // Start auto-refresh and do initial refresh
                if (wlanOn) {
                    [self startWLANRefreshTimer];
                }
                [self refreshWLANNetworks];
            }
        } else {
            [self setWLANTabShown:NO];
            [self stopWLANRefreshTimer];
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] updateDetailView: complete");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] updateDetailView: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

- (void)selectInterface:(NetworkInterface *)interface
{
    selectedInterface = interface;
    
    // Update table selection
    NSInteger index = [interfaces indexOfObject:interface];
    if (index != NSNotFound) {
        [serviceTable selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
    }
    
    [self updateDetailView];
    [self updateStatusDisplay];
}

#pragma mark - Actions

- (IBAction)enableInterface:(id)sender
{
    @try {
        if (![self validateSelectedInterface]) {
            [self showWarningAlert:@"No Service Selected" 
                   informativeText:@"Select a network service to enable."];
            return;
        }
        
        if (!backend || ![backend isAvailable]) {
            [self showErrorAlert:@"Cannot Enable Interface" 
                 informativeText:@"The network management service is not available."];
            return;
        }
        
        NSString *displayName = [selectedInterface displayName];
        if (!displayName) {
            displayName = [selectedInterface name];
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] Enabling interface: %@", displayName);
        
        BOOL success = [backend enableInterface:selectedInterface];
        
        if (success) {
            // Schedule a refresh after a short delay
            [NSTimer scheduledTimerWithTimeInterval:1.0
                                             target:self
                                           selector:@selector(refreshInterfaces:)
                                           userInfo:nil
                                            repeats:NO];
        } else {
            [self showErrorAlert:@"Enable Failed" 
                 informativeText:[NSString stringWithFormat:
                     @"\"%@\" could not be enabled. Check the system log for details.",
                     displayName]];
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in enableInterface: %@ - %@", [exception name], [exception reason]);
        [self showErrorAlert:@"Cannot Enable Interface" forException:exception];
    }
}

- (IBAction)disableInterface:(id)sender
{
    @try {
        if (![self validateSelectedInterface]) {
            [self showWarningAlert:@"No Service Selected" 
                   informativeText:@"Select a network service to disable."];
            return;
        }
        
        if (!backend || ![backend isAvailable]) {
            [self showErrorAlert:@"Cannot Disable Interface" 
                 informativeText:@"The network management service is not available."];
            return;
        }
        
        NSString *displayName = [selectedInterface displayName];
        if (!displayName) {
            displayName = [selectedInterface name];
        }
        
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:[NSString stringWithFormat:@"Disable \"%@\"?", displayName]];
        [alert setInformativeText:@"Active connections through it will be disconnected."];
        /* Cancel is added first so that it is the default button: Return must
           not cut a connection by accident. */
        [alert addButtonWithTitle:@"Cancel"];
        [alert addButtonWithTitle:@"Disable"];
        [alert setAlertStyle:NSWarningAlertStyle];
        
        NSModalResponse response = [alert runModal];
        [alert release];
        
        if (response == NSAlertSecondButtonReturn) {
            NSDebugLLog(@"gwcomp", @"[Network] Disabling interface: %@", displayName);
            
            BOOL success = [backend disableInterface:selectedInterface];
            
            if (success) {
                // Schedule a refresh after a short delay
                [NSTimer scheduledTimerWithTimeInterval:1.0
                                                 target:self
                                               selector:@selector(refreshInterfaces:)
                                               userInfo:nil
                                                repeats:NO];
            } else {
                [self showErrorAlert:@"Disable Failed" 
                     informativeText:[NSString stringWithFormat:
                         @"\"%@\" could not be disabled. Check the system log for details.",
                         displayName]];
            }
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in disableInterface: %@ - %@", [exception name], [exception reason]);
        [self showErrorAlert:@"Cannot Disable Interface" forException:exception];
    }
}

/* Removed - action button was removed in favor of context menu
- (IBAction)actionMenuClicked:(id)sender
{
    NSMenu *menu = [[NSMenu alloc] init];
    
    [menu addItemWithTitle:@"Set Service Order..." action:nil keyEquivalent:@""];
    [menu addItemWithTitle:@"Make Service Inactive" action:@selector(toggleServiceActive:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Duplicate Service..." action:nil keyEquivalent:@""];
    [menu addItemWithTitle:@"Rename Service..." action:nil keyEquivalent:@""];
    
    for (NSMenuItem *item in [menu itemArray]) {
        [item setTarget:self];
    }
    
    [NSMenu popUpContextMenu:menu withEvent:[NSApp currentEvent] forView:enableButton];
    [menu release];
}
*/

- (IBAction)configureIPv4Changed:(id)sender
{
    NSInteger index = [configureIPv4Popup indexOfSelectedItem];
    BOOL manual = (index == 1);
    
    [ipAddressField setEditable:manual];
    [subnetMaskField setEditable:manual];
    [routerField setEditable:manual];
    
    isEditing = YES;
}

- (IBAction)configureIPv6Changed:(id)sender
{
    NSInteger index = [configureIPv6Popup indexOfSelectedItem];
    BOOL manual = (index == 1);  // "Manually" option
    
    [ipv6AddressField setEditable:manual];
    
    isEditing = YES;
    
    // TODO: When applying, use the selected IPv6 mode:
    // 0 = Automatically (SLAAC/DHCPv6)
    // 1 = Manually
    // 2 = Link-local only
    // 3 = Off (disable IPv6)
}

- (IBAction)renewDHCPLease:(id)sender
{
    @try {
        if (![self validateSelectedInterface]) {
            [self showWarningAlert:@"No Service Selected" 
                   informativeText:@"Select a network service to renew its DHCP lease."];
            return;
        }
        
        if (!backend || ![backend isAvailable]) {
            [self showErrorAlert:@"Cannot Renew DHCP Lease" 
                 informativeText:@"The network management service is not available."];
            return;
        }
        
        NSString *interfaceName = [selectedInterface identifier];
        NSDebugLLog(@"gwcomp", @"[Network] Renewing DHCP lease for: %@ (%@)", [selectedInterface name], interfaceName);
        
        // Try using the network helper for DHCP renewal (more reliable than NetworkManager for some systems)
        if ([backend respondsToSelector:@selector(runPrivilegedHelper:error:)]) {
            NSError *error = nil;
            NSArray *args = @[@"dhcp-renew", interfaceName];
            BOOL success = [(NMBackend *)backend runPrivilegedHelper:args error:&error];
            
            if (success) {
                NSDebugLLog(@"gwcomp", @"[Network] DHCP renewal initiated successfully");
                [self showInfoAlert:@"Renewing DHCP Lease" 
                    informativeText:@"The network address is being renewed. This may take a few moments."];
                
                // Schedule a refresh after a short delay
                [NSTimer scheduledTimerWithTimeInterval:3.0
                                                 target:self
                                               selector:@selector(refreshInterfaces:)
                                               userInfo:nil
                                                repeats:NO];
                return;
            } else {
                NSDebugLLog(@"gwcomp", @"[Network] DHCP renewal via helper failed: %@", error);
            }
        }
        
        // Fallback: Disconnect and reconnect to renew DHCP via NetworkManager
        NSDebugLLog(@"gwcomp", @"[Network] Falling back to NetworkManager interface restart");
        [backend disableInterface:selectedInterface];
        
        // Schedule reconnection after delay
        [NSTimer scheduledTimerWithTimeInterval:1.0
                                         target:self
                                       selector:@selector(doEnableInterfaceAfterDelay:)
                                       userInfo:nil
                                        repeats:NO];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in renewDHCPLease: %@ - %@", [exception name], [exception reason]);
        [self showErrorAlert:@"Cannot Renew DHCP Lease" forException:exception];
    }
}

- (void)doEnableInterfaceAfterDelay:(NSTimer *)timer
{
    if (selectedInterface) {
        [backend enableInterface:selectedInterface];
        [self refreshInterfaces:nil];
    }
}

#pragma mark - WLAN Actions

- (IBAction)toggleWLANPower:(id)sender
{
    @try {
        if (!backend || ![backend isAvailable]) {
            [self showErrorAlert:@"Cannot Toggle WLAN" 
                 informativeText:@"The network management service is not available."];
            return;
        }
        
        BOOL currentState = [backend isWLANEnabled];
        BOOL newState = !currentState;
        
        [backend setWLANEnabled:newState];
        [wlanPowerButton setTitle:newState ? @"Turn WLAN Off" : @"Turn WLAN On"];
        
        if (newState) {
            // Start auto-refresh and do initial refresh
            [self startWLANRefreshTimer];
            [self refreshWLANNetworks];
        } else {
            // Stop auto-refresh when WLAN is off
            [self stopWLANRefreshTimer];
            [wlanNetworks removeAllObjects];
            [wlanTable reloadData];
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in toggleWLANPower: %@ - %@", [exception name], [exception reason]);
        [self showErrorAlert:@"Cannot Switch WLAN On or Off" forException:exception];
    }
}

- (IBAction)joinNetwork:(id)sender
{
    @try {
        if (!wlanNetworks) {
            [self joinOtherNetwork:sender];
            return;
        }
        
        NSInteger row = [wlanTable selectedRow];
        if (row < 0 || row >= (NSInteger)[wlanNetworks count]) {
            [self joinOtherNetwork:sender];
            return;
        }
        
        WLAN *network = [wlanNetworks objectAtIndex:row];
        if (!network) {
            [self showErrorAlert:@"Cannot Join Network" informativeText:@"No network is selected."];
            return;
        }
        [self connectToNetwork:network];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in joinNetwork: %@ - %@", [exception name], [exception reason]);
        [self showErrorAlert:@"Cannot Join Network" forException:exception];
    }
}

- (void)wlanTableDoubleClicked:(id)sender
{
    @try {
        if (!wlanNetworks) {
            return;
        }
        
        NSInteger row = [wlanTable clickedRow];
        if (row < 0 || row >= (NSInteger)[wlanNetworks count]) {
            return;
        }
        
        WLAN *network = [wlanNetworks objectAtIndex:row];
        if (network) {
            [self connectToNetwork:network];
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in wlanTableDoubleClicked: %@ - %@", [exception name], [exception reason]);
    }
}

- (void)connectToNetwork:(WLAN *)network
{
    NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: called");
    
    @try {
        if (!network) {
            NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: network is nil");
            [self showErrorAlert:@"Cannot Connect to Network" informativeText:@"No network is selected."];
            return;
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: network SSID = '%@', security = %d, isConnected = %@",
              [network ssid], (int)[network security], [network isConnected] ? @"YES" : @"NO");
        
        if (!backend) {
            NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: backend is nil");
            [self showErrorAlert:@"Cannot Connect to Network" 
                 informativeText:@"The network management service is not available."];
            return;
        }
        
        if (![backend isAvailable]) {
            NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: backend not available");
            [self showErrorAlert:@"Cannot Connect to Network" 
                 informativeText:@"The network management service is not available."];
            return;
        }
        
        if ([network isConnected]) {
            NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: already connected, returning");
            return; // Already connected
        }
        
        if ([network security] == WLANSecurityNone) {
            // Open network, connect directly
            NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: open network, connecting directly");
            [backend connectToWLAN:network withPassword:nil];
            [self refreshWLANNetworks];
        } else {
            // Secured network, show password dialog
            NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: secured network, showing password dialog");
            [self showPasswordPanelForNetwork:network];
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: done");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] connectToNetwork: EXCEPTION: %@ - %@", [exception name], [exception reason]);
        [self showErrorAlert:@"Cannot Connect to Network" forException:exception];
    }
}

- (IBAction)joinOtherNetwork:(id)sender
{
    @try {
        if (!joinNetworkPanel) {
            [self createJoinNetworkPanel];
        }
        
        // Reset fields
        [joinNetworkSSIDField setStringValue:@""];
        [joinNetworkSecurityPopup selectItemAtIndex:0];
        [joinNetworkJoinButton setEnabled:NO];
        
        // Show panel as sheet
        [NSApp beginSheet:joinNetworkPanel
           modalForWindow:[[mainView window] isKindOfClass:[NSWindow class]] ? [mainView window] : nil
            modalDelegate:nil
           didEndSelector:nil
              contextInfo:nil];
        
        // Make SSID field first responder
        [joinNetworkPanel makeFirstResponder:joinNetworkSSIDField];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in joinOtherNetwork: %@", [exception reason]);
        [self showErrorAlert:@"Cannot Join Network" forException:exception];
    }
}

- (IBAction)joinOtherNetworkConfirm:(id)sender
{
    @try {
        NSString *ssid = [joinNetworkSSIDField stringValue];
        
        if ([ssid length] == 0) {
            [self showWarningAlert:@"Network Name Required" 
                   informativeText:@"Enter the name of the network to join."];
            return;
        }
        
        // Close the panel
        [NSApp endSheet:joinNetworkPanel];
        [joinNetworkPanel orderOut:nil];
        
        // Create a temporary network object
        WLAN *network = [[WLAN alloc] init];
        [network setSsid:ssid];
        
        NSInteger secIndex = [joinNetworkSecurityPopup indexOfSelectedItem];
        if (secIndex == 0) {
            [network setSecurity:WLANSecurityNone];
            [backend connectToWLAN:network withPassword:nil];
            [self refreshWLANNetworks];
        } else {
            [network setSecurity:WLANSecurityWPA2];
            [self showPasswordPanelForNetwork:network];
        }
        [network release];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in joinOtherNetworkConfirm: %@", [exception reason]);
        [self showErrorAlert:@"Cannot Join Network" forException:exception];
    }
}

- (IBAction)joinOtherNetworkCancel:(id)sender
{
    [NSApp endSheet:joinNetworkPanel];
    [joinNetworkPanel orderOut:nil];
}

- (IBAction)disconnectWLAN:(id)sender
{
    @try {
        NSDebugLLog(@"gwcomp", @"[Network] disconnectWLAN: called");
        
        if (!backend) {
            NSDebugLLog(@"gwcomp", @"[Network] disconnectWLAN: backend is nil");
            [self showErrorAlert:@"Cannot Disconnect" informativeText:@"The network management service is not available."];
            return;
        }
        
        if (![backend isAvailable]) {
            NSDebugLLog(@"gwcomp", @"[Network] disconnectWLAN: backend not available");
            [self showErrorAlert:@"Cannot Disconnect" informativeText:@"The network management service is not available."];
            return;
        }
        
        BOOL success = [backend disconnectFromWLAN];
        NSDebugLLog(@"gwcomp", @"[Network] disconnectWLAN: backend returned %@", success ? @"YES" : @"NO");
        
        // Schedule refresh after a short delay
        [NSTimer scheduledTimerWithTimeInterval:1.0
                                         target:self
                                       selector:@selector(doRefreshAfterDisconnect:)
                                       userInfo:nil
                                        repeats:NO];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] disconnectWLAN: EXCEPTION: %@ - %@", [exception name], [exception reason]);
        [self showErrorAlert:@"Cannot Disconnect" forException:exception];
    }
}

- (void)doRefreshAfterDisconnect:(NSTimer *)timer
{
    NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterDisconnect: refreshing...");
    @try {
        [self refreshWLANNetworks];
        [self refreshInterfaces:nil];
        NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterDisconnect: complete");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterDisconnect: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

#pragma mark - MAC Address Cloning

- (void)updateClonedMacPopup
{
    @try {
        if (!clonedMacPopup) return;
        NSString *ssid = nil;
        NSInteger row = [wlanTable selectedRow];
        if (wlanNetworks && row >= 0 && row < (NSInteger)[wlanNetworks count]) {
            ssid = [[wlanNetworks objectAtIndex:row] ssid];
        }
        if (!ssid && selectedWLANNetwork) {
            ssid = [selectedWLANNetwork ssid];
        }
        if (!ssid) {
            ssid = [backend connectedWLANSSID];
        }
        if (!ssid) {
            [clonedMacPopup setEnabled:NO];
            return;
        }
        NSLog(@"[Network] updateClonedMacPopup: looking up cloned MAC for SSID '%@'", ssid);
        NSString *current = [backend clonedMacAddressForSSID:ssid];
        NSLog(@"[Network] updateClonedMacPopup: current value = '%@'", current);
        for (NSMenuItem *item in [[clonedMacPopup menu] itemArray]) {
            if ([[item representedObject] isEqualToString:current]) {
                [clonedMacPopup selectItem:item];
                break;
            }
        }
        [clonedMacPopup setEnabled:YES];
    } @catch (NSException *exception) {
        NSLog(@"[Network] updateClonedMacPopup: EXCEPTION: %@ - %@",
              [exception name], [exception reason]);
        [clonedMacPopup setEnabled:NO];
    }
}

- (IBAction)clonedMacChanged:(id)sender
{
    NSString *value = [[clonedMacPopup selectedItem] representedObject];
    if (!value) return;
    NSString *ssid = nil;
    NSInteger row = [wlanTable selectedRow];
    if (wlanNetworks && row >= 0 && row < (NSInteger)[wlanNetworks count]) {
        ssid = [[wlanNetworks objectAtIndex:row] ssid];
    }
    if (!ssid && selectedWLANNetwork) {
        ssid = [selectedWLANNetwork ssid];
    }
    if (!ssid) {
        ssid = [[backend connectedWLAN] ssid];
    }
    if (!ssid) {
        NSLog(@"[Network] clonedMacChanged: no SSID available, cannot set cloned MAC");
        return;
    }
    NSLog(@"[Network] clonedMacChanged: setting cloned MAC for '%@' to '%@'", ssid, value);
    if ([backend setClonedMacAddress:value forSSID:ssid]) {
        NSLog(@"[Network] clonedMacChanged: successfully set cloned MAC for %@ to %@", ssid, value);
    }
}

- (IBAction)refreshWLAN:(id)sender
{
    [self refreshWLANNetworks];
}

#pragma mark - Password Panel

- (void)showPasswordPanelForNetwork:(WLAN *)network
{
    NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: called");
    
    @try {
        if (!network) {
            NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: network is nil");
            [self showErrorAlert:@"Cannot Connect to Network" informativeText:@"No network is selected."];
            return;
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: network SSID = '%@'", [network ssid]);
        
        // Release previous pending network if any
        if (pendingNetwork) {
            NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: releasing previous pendingNetwork");
            [pendingNetwork release];
            pendingNetwork = nil;
        }
        
        // Retain the new pending network
        pendingNetwork = [network retain];
        NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: pendingNetwork retained (retainCount: %lu)", 
              (unsigned long)[pendingNetwork retainCount]);
        
        if (!passwordPanel) {
            [self createPasswordPanel];
        }
        
        if (!passwordSSIDLabel) {
            NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: ERROR - passwordSSIDLabel is nil!");
        } else {
            NSString *labelText = [NSString stringWithFormat:
                                   @"Join \"%@\"",
                                   [network ssid] ?: @"(unknown)"];
            [passwordSSIDLabel setStringValue:labelText];
            NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: set label to '%@'", labelText);
        }
        
        if (!passwordField) {
            NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: ERROR - passwordField is nil!");
        } else {
            [passwordField setStringValue:@""];
            [passwordConnectButton setEnabled:NO];
        }
        
        NSWindow *parentWindow = [mainView window];
        NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: parentWindow = %@", parentWindow);
        
        if (parentWindow) {
            [NSApp beginSheet:passwordPanel
               modalForWindow:parentWindow
                modalDelegate:nil
               didEndSelector:nil
                  contextInfo:nil];
            [passwordPanel makeFirstResponder:passwordField];
            NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: sheet displayed");
        } else {
            NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: no parent window, showing as regular window");
            [passwordPanel makeKeyAndOrderFront:self];
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] showPasswordPanelForNetwork: EXCEPTION: %@ - %@", 
              [exception name], [exception reason]);
        [self showErrorAlert:@"Cannot Connect to Network" forException:exception];
    }
}

- (IBAction)passwordConnect:(id)sender
{
    NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: called");
    
    @try {
        // Close the sheet first
        NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: ending sheet...");
        [NSApp endSheet:passwordPanel];
        [passwordPanel orderOut:self];
        NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: sheet closed");
        
        if (!pendingNetwork) {
            NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: ERROR - pendingNetwork is nil!");
            [self showErrorAlert:@"Cannot Connect to Network" informativeText:@"No network is selected."];
            return;
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: pendingNetwork SSID = '%@'", [pendingNetwork ssid]);
        
        if (!passwordField) {
            NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: ERROR - passwordField is nil!");
            [pendingNetwork release];
            pendingNetwork = nil;
            [self showErrorAlert:@"Cannot Connect to Network" informativeText:@"The password could not be read."];
            return;
        }
        
        NSString *password = [passwordField stringValue];
        NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: password length = %lu", (unsigned long)[password length]);
        
        if (!backend) {
            NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: ERROR - backend is nil!");
            [pendingNetwork release];
            pendingNetwork = nil;
            [self showErrorAlert:@"Cannot Connect to Network" informativeText:@"The network management service is not available."];
            return;
        }
        
        if (![backend isAvailable]) {
            NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: ERROR - backend not available!");
            [pendingNetwork release];
            pendingNetwork = nil;
            [self showErrorAlert:@"Cannot Connect to Network" informativeText:@"The network management service is not available."];
            return;
        }
        
        // Copy the network reference before releasing
        WLAN *networkToConnect = [pendingNetwork retain];
        NSString *ssidToConnect = [[pendingNetwork ssid] copy];
        
        NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: calling backend connectToWLAN for '%@'", ssidToConnect);
        
        // Release pending network before the potentially blocking call
        [pendingNetwork release];
        pendingNetwork = nil;
        
        // Now connect
        BOOL success = [backend connectToWLAN:networkToConnect withPassword:password];
        NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: backend returned success = %@", success ? @"YES" : @"NO");
        
        [networkToConnect release];
        [ssidToConnect release];
        
        // Refresh after a delay to show new connection
        NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: scheduling refresh timer");
        [NSTimer scheduledTimerWithTimeInterval:2.0
                                         target:self
                                       selector:@selector(doRefreshAfterConnect:)
                                       userInfo:nil
                                        repeats:NO];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] passwordConnect: EXCEPTION: %@ - %@", [exception name], [exception reason]);
        if (pendingNetwork) {
            [pendingNetwork release];
            pendingNetwork = nil;
        }
        [self showErrorAlert:@"Cannot Connect to Network" forException:exception];
    }
}

- (void)doRefreshAfterConnect:(NSTimer *)timer
{
    NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterConnect: refreshing...");
    @try {
        if (!backend || ![backend isAvailable]) {
            NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterConnect: backend not available");
            return;
        }
        
        // Refresh WLAN networks first
        [self refreshWLANNetworks];
        
        // Then refresh interfaces
        [self refreshInterfaces:nil];
        
        // Force update detail view to ensure correct interface is showing
        if (selectedInterface) {
            NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterConnect: forcing detail view update for %@", [selectedInterface name]);
            [self updateDetailView];
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterConnect: refresh complete");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterConnect: EXCEPTION: %@ - %@", 
              [exception name], [exception reason]);
    }
}

- (IBAction)passwordCancel:(id)sender
{
    NSDebugLLog(@"gwcomp", @"[Network] passwordCancel: called");
    
    @try {
        [NSApp endSheet:passwordPanel];
        [passwordPanel orderOut:self];
        
        if (pendingNetwork) {
            NSDebugLLog(@"gwcomp", @"[Network] passwordCancel: releasing pendingNetwork");
            [pendingNetwork release];
            pendingNetwork = nil;
        }
        NSDebugLLog(@"gwcomp", @"[Network] passwordCancel: done");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] passwordCancel: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

#pragma mark - Advanced

- (IBAction)showAdvanced:(id)sender
{
    if (!advancedPanel) {
        [self createAdvancedPanel];
    }
    [NSApp beginSheet:advancedPanel
       modalForWindow:[mainView window]
        modalDelegate:nil
       didEndSelector:nil
          contextInfo:nil];
}

- (IBAction)closeAdvanced:(id)sender
{
    [NSApp endSheet:advancedPanel];
    [advancedPanel orderOut:self];
}

- (IBAction)toggleServiceActive:(id)sender
{
    @try {
        if (!selectedInterface) {
            NSDebugLLog(@"gwcomp", @"[Network] toggleServiceActive: no interface selected");
            return;
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] toggleServiceActive: interface '%@' isActive=%@", 
              [selectedInterface name], [selectedInterface isActive] ? @"YES" : @"NO");
        
        BOOL success = NO;
        if ([selectedInterface isActive]) {
            success = [backend disableInterface:selectedInterface];
        } else {
            success = [backend enableInterface:selectedInterface];
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] toggleServiceActive: operation returned %@", success ? @"YES" : @"NO");
        
        // Refresh after a short delay to let NetworkManager update
        [NSTimer scheduledTimerWithTimeInterval:1.0
                                         target:self
                                       selector:@selector(doRefreshAfterToggle:)
                                       userInfo:nil
                                        repeats:NO];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] toggleServiceActive: EXCEPTION: %@ - %@", [exception name], [exception reason]);
        [self showErrorAlert:@"Cannot Switch Interface On or Off" forException:exception];
    }
}

- (void)doRefreshAfterToggle:(NSTimer *)timer
{
    NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterToggle: refreshing interfaces...");
    @try {
        if (!self) {
            NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterToggle: self is nil!");
            return;
        }
        
        if (!backend) {
            NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterToggle: backend is nil");
            return;
        }
        
        [self refreshInterfaces:nil];
        NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterToggle: refresh complete");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] doRefreshAfterToggle: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

#pragma mark - Helper Methods

- (NSImage *)iconForInterfaceType:(NetworkInterfaceType)type
{
    NSString *iconName;
    
    switch (type) {
        case NetworkInterfaceTypeEthernet:
            iconName = @"network-wired";
            break;
        case NetworkInterfaceTypeWLAN:
            iconName = @"network-wireless";
            break;
        case NetworkInterfaceTypeBluetooth:
            iconName = @"bluetooth";
            break;
        case NetworkInterfaceTypeVPN:
            iconName = @"network-vpn";
            break;
        default:
            iconName = @"network-idle";
            break;
    }
    
    NSImage *icon = [NSImage imageNamed:iconName];
    if (!icon) {
        icon = [NSImage imageNamed:@"NSNetwork"];
    }
    
    return icon;
}

- (NSImage *)statusIconForInterface:(NetworkInterface *)interface
{
    if (!interface) {
        return [NSImage imageNamed:@"NSNetwork"];
    }
    
    NSImage *icon = [self iconForInterfaceType:[interface type]];
    
    // For now just return the base icon
    // Could overlay status indicators in the future
    
    return icon;
}

- (NSString *)descriptionForInterface:(NetworkInterface *)interface
{
    if (!interface) {
        return @"";
    }
    
    NSMutableString *desc = [NSMutableString string];
    
    if ([interface state] == NetworkConnectionStateConnected) {
        IPConfiguration *ipv4 = [interface ipv4Config];
        if (ipv4 && [ipv4 address]) {
            [desc appendFormat:@"IP Address: %@", [ipv4 address]];
        }
        
        if ([interface hardwareAddress]) {
            if ([desc length] > 0) [desc appendString:@"\n"];
            [desc appendFormat:@"Hardware Address: %@", [interface hardwareAddress]];
        }
    } else {
        if ([interface hardwareAddress]) {
            [desc appendFormat:@"Hardware Address: %@", [interface hardwareAddress]];
        }
    }
    
    return desc;
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    @try {
        if (tableView == serviceTable) {
            return interfaces ? [interfaces count] : 0;
        } else if (tableView == wlanTable) {
            return wlanNetworks ? [wlanNetworks count] : 0;
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in numberOfRowsInTableView: %@", [exception reason]);
    }
    return 0;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    @try {
        if (!tableColumn) return nil;
        NSString *identifier = [tableColumn identifier];
        if (!identifier) return nil;
        
        if (tableView == serviceTable) {
            if (!interfaces || row < 0 || row >= (NSInteger)[interfaces count]) return nil;
            NetworkInterface *iface = [interfaces objectAtIndex:row];
            if (!iface) return nil;
            
            if ([identifier isEqualToString:@"icon"]) {
                return [self iconForInterfaceType:[iface type]];
            } else if ([identifier isEqualToString:@"name"]) {
                return [iface displayName] ?: [iface name] ?: @"Unknown";
            }
        } else if (tableView == wlanTable) {
            if (!wlanNetworks || row < 0 || row >= (NSInteger)[wlanNetworks count]) return nil;
            WLAN *network = [wlanNetworks objectAtIndex:row];
            if (!network) return nil;
            
            if ([identifier isEqualToString:@"signal"]) {
                // Return signal strength as icon or text
                int bars = [network signalBars];
                return [NSString stringWithFormat:@"%@", 
                        bars >= 3 ? @"●●●●" : (bars >= 2 ? @"●●●○" : (bars >= 1 ? @"●●○○" : @"●○○○"))];
            } else if ([identifier isEqualToString:@"ssid"]) {
                return [network ssid] ?: @"Unknown";
            } else if ([identifier isEqualToString:@"security"]) {
                return [network securityString] ?: @"";
            } else if ([identifier isEqualToString:@"status"]) {
                return [network isConnected] ? @"✓" : @"";
            }
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in tableView:objectValueForTableColumn:row: %@", [exception reason]);
    }
    
    return nil;
}

#pragma mark - NSTableViewDelegate

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    @try {
        NSTableView *tableView = [notification object];
        if (!tableView) return;
        
        if (tableView == serviceTable) {
            NSInteger row = [serviceTable selectedRow];
            if (interfaces && row >= 0 && row < (NSInteger)[interfaces count]) {
                selectedInterface = [interfaces objectAtIndex:row];
                [self updateDetailView];
                [self updateStatusDisplay];
                [self updateEnableDisableButtons];
            } else {
                selectedInterface = nil;
                [self updateEnableDisableButtons];
            }
        } else if (tableView == wlanTable) {
            NSInteger row = [wlanTable selectedRow];
            if (wlanNetworks && row >= 0 && row < (NSInteger)[wlanNetworks count]) {
                selectedWLANNetwork = [wlanNetworks objectAtIndex:row];
            } else {
                selectedWLANNetwork = nil;
            }
            [self updateClonedMacPopup];
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception in tableViewSelectionDidChange: %@", [exception reason]);
    }
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row
{
    return YES;
}

- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if (tableView == serviceTable) {
        if ([[tableColumn identifier] isEqualToString:@"icon"]) {
            if ([cell isKindOfClass:[NSImageCell class]]) {
                [(NSImageCell *)cell setImageScaling:NSImageScaleProportionallyDown];
            }
        }
    }
}

#pragma mark - NetworkBackendDelegate

- (void)networkBackend:(id<NetworkBackend>)aBackend didUpdateInterfaces:(NSArray *)newInterfaces
{
    // Ensure we're on the main thread
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(handleUpdatedInterfaces:) 
                               withObject:newInterfaces 
                            waitUntilDone:NO];
        return;
    }
    [self handleUpdatedInterfaces:newInterfaces];
}

- (void)handleUpdatedInterfaces:(NSArray *)newInterfaces
{
    @try {
        if (!interfaces) {
            NSDebugLLog(@"gwcomp", @"[Network] handleUpdatedInterfaces: interfaces array is nil!");
            return;
        }
        
        [interfaces removeAllObjects];
        if (newInterfaces && [newInterfaces count] > 0) {
            [interfaces addObjectsFromArray:newInterfaces];
            NSDebugLLog(@"gwcomp", @"[Network] handleUpdatedInterfaces: added %lu interfaces", (unsigned long)[newInterfaces count]);
        }
        
        if (serviceTable) {
            [serviceTable reloadData];
        }
        
        [self updateStatusDisplay];

        // Check for captive portal when WLAN connection changes
        NSString *currentWLANSSID = nil;
        for (NetworkInterface *iface in interfaces) {
            if ([iface type] == NetworkInterfaceTypeWLAN && [iface state] == NetworkConnectionStateConnected) {
                currentWLANSSID = [iface name];
                break;
            }
        }
        if (currentWLANSSID && ![currentWLANSSID isEqualToString:previousWLANSSID]) {
            [previousWLANSSID release];
            previousWLANSSID = [currentWLANSSID retain];
            [[self retain] autorelease];
            [CaptivePortalDetector checkForCaptivePortalWithCompletion:^(BOOL isCaptive, NSString *redirectURL) {
                if (isCaptive && redirectURL) {
                    [self captivePortalDetected:redirectURL];
                }
            }];
        } else if (!currentWLANSSID) {
            [previousWLANSSID release];
            previousWLANSSID = nil;
        }

        [self updateClonedMacPopup];
        
        NSDebugLLog(@"gwcomp", @"[Network] handleUpdatedInterfaces: complete");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] handleUpdatedInterfaces: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

- (void)networkBackend:(id<NetworkBackend>)aBackend didFinishWLANScan:(NSArray *)networks
{
    // Ensure we're on the main thread
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(wlanScanCompleted:) 
                               withObject:networks 
                            waitUntilDone:NO];
        return;
    }
    [self wlanScanCompleted:networks];
}

- (void)networkBackend:(id<NetworkBackend>)aBackend didEncounterError:(NSError *)error
{
    // Ensure we're on the main thread
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(handleNetworkError:) 
                               withObject:error 
                            waitUntilDone:NO];
        return;
    }
    [self handleNetworkError:error];
}

- (void)handleNetworkError:(NSError *)error
{
    @try {
        if (!error) {
            NSDebugLLog(@"gwcomp", @"[Network] handleNetworkError: error is nil");
            return;
        }
        
        NSString *errorDesc = [error localizedDescription];
        if (!errorDesc) {
            errorDesc = @"An unknown error occurred";
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] handleNetworkError: showing alert for: %@", errorDesc);
        
        // Use showErrorAlert which is more defensive
        [self showErrorAlert:@"Network Error" informativeText:errorDesc];
        
        NSDebugLLog(@"gwcomp", @"[Network] handleNetworkError: alert dismissed");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[Network] handleNetworkError: EXCEPTION: %@ - %@", [exception name], [exception reason]);
    }
}

- (void)networkBackend:(id<NetworkBackend>)aBackend WLANEnabledDidChange:(BOOL)enabled
{
    // Ensure we're on the main thread  
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(handleWlanEnabledChange:) 
                               withObject:[NSNumber numberWithBool:enabled] 
                            waitUntilDone:NO];
        return;
    }
    [self handleWlanEnabledChange:[NSNumber numberWithBool:enabled]];
}

- (void)handleWlanEnabledChange:(NSNumber *)enabledNum
{
    BOOL enabled = [enabledNum boolValue];
    [wlanPowerButton setTitle:enabled ? @"Turn WLAN Off" : @"Turn WLAN On"];
    
    if (!enabled) {
        [wlanNetworks removeAllObjects];
        [wlanTable reloadData];
    }
}

#pragma mark - Menu Validation

- (void)menuNeedsUpdate:(NSMenu *)menu
{
    if (menu == serviceContextMenu) {
        // Update menu items based on selected interface state
        for (NSMenuItem *item in [menu itemArray]) {
            SEL action = [item action];
            if (action == @selector(enableInterface:)) {
                if (selectedInterface) {
                    BOOL isEnabled = [selectedInterface isEnabled];
                    [item setEnabled:!isEnabled];
                } else {
                    [item setEnabled:NO];
                }
            } else if (action == @selector(disableInterface:)) {
                if (selectedInterface) {
                    BOOL isEnabled = [selectedInterface isEnabled];
                    BOOL isActive = [selectedInterface isActive];
                    [item setEnabled:isEnabled || isActive];
                } else {
                    [item setEnabled:NO];
                }
            }
        }
    }
}

#pragma mark - Dialog input

/* A sheet's primary button is only offered once there is something to act on. */
- (void)controlTextDidChange:(NSNotification *)notification
{
    id field = [notification object];
    if (field == joinNetworkSSIDField) {
        [joinNetworkJoinButton setEnabled:[[joinNetworkSSIDField stringValue] length] > 0];
    } else if (field == passwordField) {
        [passwordConnectButton setEnabled:[[passwordField stringValue] length] > 0];
    }
}

#pragma mark - Error Handling Helpers

- (void)showErrorAlert:(NSString *)message informativeText:(NSString *)info
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:message ? message : @"Error"];
    [alert setInformativeText:info ? info : @"An unknown error occurred."];
    /* Critical is for what endangers data; a failed connection attempt is
       an ordinary warning. */
    [alert setAlertStyle:NSWarningAlertStyle];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    [alert release];
}

/* The exception's reason comes from the backend or the frameworks; it is the
   detail under a title that says what could not be done. */
- (void)showErrorAlert:(NSString *)message forException:(NSException *)exception
{
    [self showErrorAlert:message
         informativeText:[NSString stringWithFormat:
                          @"The operation could not be completed: %@", [exception reason]]];
}

- (void)showWarningAlert:(NSString *)message informativeText:(NSString *)info
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:message ? message : @"Warning"];
    [alert setInformativeText:info ? info : @""];
    [alert setAlertStyle:NSWarningAlertStyle];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    [alert release];
}

- (void)showInfoAlert:(NSString *)message informativeText:(NSString *)info
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:message ? message : @"Information"];
    [alert setInformativeText:info ? info : @""];
    [alert setAlertStyle:NSInformationalAlertStyle];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    [alert release];
}

- (BOOL)validateSelectedInterface
{
    if (!selectedInterface) {
        return NO;
    }
    
    // Check if the selected interface is still in our interfaces array
    if (![interfaces containsObject:selectedInterface]) {
        selectedInterface = nil;
        return NO;
    }
    
    return YES;
}

#pragma mark - Captive Portal Detection

- (void)captivePortalDetected:(NSString *)redirectURL
{
    if (!redirectURL || [redirectURL length] == 0) {
        return;
    }

    NSDebugLLog(@"gwcomp", @"[Network] Captive portal detected, redirect to: %@", redirectURL);

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Sign In to the WLAN Network"];
    [alert setInformativeText:@"The network requires you to sign in before you can use the internet. "
        @"Open the sign-in page in your browser?"];
    [alert setAlertStyle:NSInformationalAlertStyle];
    [alert addButtonWithTitle:@"Open in Browser"];
    [alert addButtonWithTitle:@"Cancel"];

    NSInteger result = [alert runModal];
    [alert release];

    if (result == NSAlertFirstButtonReturn) {
        NSURL *url = [NSURL URLWithString:redirectURL];
        /* The URL comes from the network; only web pages may be opened. */
        NSString *scheme = [[url scheme] lowercaseString];
        if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
            /* NSWorkspace openURL: connects to the target app (the browser)
               via DO and calls it synchronously; on the main thread that
               would freeze the UI while the browser is busy.  Defer. */
            [NSThread detachNewThreadWithBlock: ^{
                [[NSWorkspace sharedWorkspace] openURL:url];
            }];
        }
    }
}

@end
