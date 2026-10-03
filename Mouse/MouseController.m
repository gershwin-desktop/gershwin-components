/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MouseController.h"
#import "MouseBackend.h"
#import "MousePreferences.h"
#import "MousePaneControls.h"
#import "AppearanceMetrics.h"
#import <dispatch/dispatch.h>
#include <math.h>

/* libs-back reads GSDoubleClickTime (ms) from NSGlobalDomain for every
   window of every app and treats anything below 200 ms as unset, using
   300 ms then. */
static NSString *const kDoubleClickKey = @"GSDoubleClickTime";
static const NSInteger kDoubleClickDefault = 300;
static const NSInteger kDoubleClickFastest = 200;
static const NSInteger kDoubleClickSlowest = 900;

static const CGFloat kStatusHeight = 20;
static const CGFloat kBoxTitleInset = 14;

/* The slider reads slow to fast from left to right while the default
   stores a time, which is the other way round. */
static double SliderValueForDoubleClickTime(NSInteger ms)
{
    return (double)(kDoubleClickFastest + kDoubleClickSlowest - ms);
}

static NSInteger DoubleClickTimeForSliderValue(double value)
{
    return kDoubleClickFastest + kDoubleClickSlowest - lround(value);
}

/* The pane view.  When the host gives it a width other than the one it was
   built at, the boxes are laid out again so the margins to the window edge
   stay symmetric. */
@interface MouseMainView : NSView
{
    MouseController *_layoutOwner;
}
- (void)setLayoutOwner:(MouseController *)owner;
@end

@implementation MouseMainView
- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    [_layoutOwner relayoutWithWidth:newSize.width];
}
- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    if ([self window] && [self superview]) {
        [self setFrame:[[self superview] bounds]];
        [_layoutOwner relayoutWithWidth:[self bounds].size.width];
    }
}
- (void)setLayoutOwner:(MouseController *)owner
{
    _layoutOwner = owner;
}
@end

@implementation MouseController

- (id)init
{
    self = [super init];
    if (self) {
        backend = [[MouseBackend alloc] init];
        NSMutableArray *list = [NSMutableArray array];
        for (NSNumber *k in @[@(PointerDeviceKindMouse), @(PointerDeviceKindTouchpad),
                              @(PointerDeviceKindTrackpoint)]) {
            PointerSection *s = [[PointerSection alloc] initWithKind:[k integerValue] backend:backend];
            [s setDelegate:self];
            [list addObject:s];
            [s release];
        }
        sections = [list copy];
        tabItems = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc
{
    for (PointerSection *s in sections) {
        [s setDelegate:nil];
    }
    [sections release];
    [tabItems release];
    [mainView release];
    [backend release];
    [super dealloc];
}

#pragma mark - Building

- (NSView *)createMainView
{
    if (mainView) {
        return mainView;
    }

    /* The pane area System Preferences gives every pane; the devices box
       takes whatever height is left, so it also follows another host. */
    const CGFloat winW = 640, winH = 440;
    const CGFloat side = METRICS_CONTENT_SIDE_MARGIN;
    const CGFloat bottom = METRICS_CONTENT_BOTTOM_MARGIN;
    const CGFloat contentW = winW - 2 * side;
    const CGFloat rowH = MousePaneRowHeight;

    mainView = [[MouseMainView alloc] initWithFrame:NSMakeRect(0, 0, winW, winH)];
    [(MouseMainView *)mainView setLayoutOwner:self];
    [mainView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    statusLabel = MousePaneLabel(@"", NSMakeRect(side, bottom, contentW, kStatusHeight),
                                 NSTextAlignmentLeft);
    [statusLabel setFont:[NSFont systemFontOfSize:10]];
    [statusLabel setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    [mainView addSubview:statusLabel];

    /* One setting for every pointer and every app, so it sits outside the
       per-device box. */
    CGFloat rowY = bottom + kStatusHeight + METRICS_SPACE_8;
    NSView *doubleClickRow = [[[NSView alloc] initWithFrame:
        NSMakeRect(side, rowY, contentW, rowH)] autorelease];
    [doubleClickRow setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    [mainView addSubview:doubleClickRow];
    MousePaneRow row = { 0, 0, contentW, 120, 60, MousePaneRowStretches };
    doubleClickSlider = MousePaneAddSliderRow(doubleClickRow, @"Double-click speed:", row,
                                              &doubleClickValue, self,
                                              @selector(doubleClickChanged:));
    [doubleClickSlider setMinValue:kDoubleClickFastest];
    [doubleClickSlider setMaxValue:kDoubleClickSlowest];

    CGFloat boxBottom = rowY + rowH + METRICS_SPACE_12;
    CGFloat boxH = winH - METRICS_CONTENT_TOP_MARGIN - boxBottom;
    devicesBox = [[[NSBox alloc] initWithFrame:NSMakeRect(side, boxBottom, contentW, boxH)] autorelease];
    [devicesBox setTitle:@"Pointing Devices"];
    [devicesBox setBoxType:NSBoxPrimary];
    [devicesBox setTitlePosition:NSAtTop];
    [devicesBox setBorderType:NSBezelBorder];
    [devicesBox setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [mainView addSubview:devicesBox];

    devicesTabView = [[[NSTabView alloc] initWithFrame:
        NSMakeRect(8, 8, contentW - 16, boxH - 8 - kBoxTitleInset)] autorelease];
    [devicesTabView setTabViewType:NSTopTabsBezelBorder];
    [devicesTabView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [devicesBox addSubview:devicesTabView];

    noDeviceLabel = MousePaneLabel(@"No mouse, trackpad or TrackPoint found.",
                                   NSMakeRect(8, (boxH - kBoxTitleInset) / 2 - 10, contentW - 16, 20),
                                   NSTextAlignmentCenter);
    [noDeviceLabel setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin | NSViewMaxYMargin];
    [noDeviceLabel setHidden:YES];
    [devicesBox addSubview:noDeviceLabel];

    /* Section contents are laid out top-down from the tab's real size;
       built at a placeholder size their rows end up outside the tab. */
    NSSize tabSize = [devicesTabView contentRect].size;
    for (PointerSection *s in sections) {
        NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:[s title]];
        [item setLabel:[s title]];
        [item setView:[s viewWithSize:tabSize]];
        [tabItems setObject:item forKey:[s title]];
        /* Every section is in place until the first device scan, so a host
           that indexes the pane's labels without showing it finds them all. */
        [devicesTabView addTabViewItem:item];
        [item release];
    }

    [self showDoubleClickTime];
    return mainView;
}

- (void)relayoutWithWidth:(CGFloat)width
{
    const CGFloat side = METRICS_CONTENT_SIDE_MARGIN;
    for (NSView *v in @[devicesBox, statusLabel]) {
        NSRect f = [v frame];
        f.origin.x = side;
        f.size.width = width - 2 * side;
        [v setFrame:f];
    }
    NSRect f = [devicesTabView frame];
    f.size.width = NSWidth([(NSView *)[devicesBox contentView] frame]) - 16;
    [devicesTabView setFrame:f];
}

#pragma mark - Devices

- (void)refreshFromSystem
{
    if (refreshing) {
        return;
    }
    if (![backend xinputPath]) {
        [self updateStatus:@"xinput not found; install the xinput package."];
        return;
    }
    refreshing = YES;
    [self updateStatus:@"Looking for pointing devices..."];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *devices = [[backend scanDevices] retain];
        dispatch_async(dispatch_get_main_queue(), ^{
            [backend useDevices:devices];
            [devices release];
            [self showDevices];
            refreshing = NO;
        });
    });
}

- (void)showDevices
{
    NSDictionary *domain = [MousePreferences currentDomain];
    NSMutableArray *present = [NSMutableArray array];
    NSMutableArray *summary = [NSMutableArray array];

    while ([devicesTabView numberOfTabViewItems] > 0) {
        [devicesTabView removeTabViewItem:[devicesTabView tabViewItemAtIndex:0]];
    }
    for (PointerSection *s in sections) {
        NSArray *devices = [backend devicesOfKind:[s kind]];
        if ([devices count] == 0) {
            continue;
        }
        [s showDevices:devices preferences:domain];
        [devicesTabView addTabViewItem:[tabItems objectForKey:[s title]]];
        [present addObject:s];
        [summary addObject:[NSString stringWithFormat:@"%@: %@", [s title],
                                     [[devices valueForKey:@"name"] componentsJoinedByString:@", "]]];
    }

    /* A single class needs no tabs; its name becomes the box title. */
    if ([present count] == 1) {
        [devicesTabView setTabViewType:NSNoTabsNoBorder];
        [devicesBox setTitle:[[present firstObject] title]];
    } else {
        [devicesTabView setTabViewType:NSTopTabsBezelBorder];
        [devicesBox setTitle:@"Pointing Devices"];
    }
    [devicesTabView setHidden:([present count] == 0)];
    [noDeviceLabel setHidden:([present count] > 0)];
    [devicesBox setNeedsDisplay:YES];

    [self updateStatus:([summary count] ? [summary componentsJoinedByString:@" | "]
                                         : @"No libinput pointing device found.")];
}

- (void)pointerSection:(PointerSection *)section reportFailure:(NSString *)message
{
    (void)section;
    [self updateStatus:message];
}

#pragma mark - Double-click speed

- (void)showDoubleClickTime
{
    NSInteger ms = [[NSUserDefaults standardUserDefaults] integerForKey:kDoubleClickKey];
    if (ms < kDoubleClickFastest) {
        ms = kDoubleClickDefault;
    }
    [doubleClickSlider setDoubleValue:SliderValueForDoubleClickTime(ms)];
    [doubleClickValue setStringValue:[NSString stringWithFormat:@"%ld ms", (long)ms]];
}

/* Applications read it when they start, so it takes effect in every app
   opened afterwards. */
- (void)doubleClickChanged:(id)sender
{
    NSInteger ms = DoubleClickTimeForSliderValue([sender doubleValue]);
    [doubleClickValue setStringValue:[NSString stringWithFormat:@"%ld ms", (long)ms]];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *global = [NSMutableDictionary dictionaryWithDictionary:
        [defaults persistentDomainForName:NSGlobalDomain]];
    [global setObject:[NSNumber numberWithInteger:ms] forKey:kDoubleClickKey];
    [defaults setPersistentDomain:global forName:NSGlobalDomain];
    [defaults synchronize];
}

- (void)updateStatus:(NSString *)message
{
    [statusLabel setStringValue:(message ? message : @"")];
}

@end
