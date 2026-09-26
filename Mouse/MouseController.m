/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MouseController.h"
#import "MouseBackend.h"
#import "AppearanceMetrics.h"
#include <stdlib.h>
#include <math.h>
#import <dispatch/dispatch.h>

static NSString *const kMouseDomain = @"MousePreferences";
/* Indexed like the profile pop-up and like libinput's "Accel Profile
   Enabled" flags (adaptive, flat, custom). */
static NSString *const kCurveProfiles[] = { @"system", @"flat", @"custom" };
static const NSUInteger kCurveProfileCount = 3;
static const CGFloat kCurveLabelWidth = 74;
static const CGFloat kCurveSliderWidth = 100;
static const CGFloat kCurveValueWidth = 60;

static NSInteger CurveProfileIndex(NSString *profile)
{
    for (NSUInteger i = 0; i < kCurveProfileCount; i++) {
        if ([kCurveProfiles[i] isEqualToString:profile]) {
            return i;
        }
    }
    return -1;
}

@interface MouseController ()
- (BOOL)applyCurveProfile:(NSString *)profile curve:(AccelerationCurve)curve;
- (void)updateCurveControls;
- (void)applyAllSettings;
- (void)updateStatus:(NSString *)message;

/* Layout helpers (HIG group boxes and rows). */
- (NSBox *)groupBoxWithTitle:(NSString *)title frame:(NSRect)frame inView:(NSView *)parent;
- (NSTextField *)labelWithText:(NSString *)text frame:(NSRect)frame alignment:(NSTextAlignment)align;
- (void)addCheckbox:(NSButton *)checkbox toBox:(NSBox *)box y:(CGFloat)y width:(CGFloat)w;
- (void)addSliderRowWithLabel:(NSString *)label
                       slider:(NSSlider *)slider
                        value:(NSTextField *)value
                        toBox:(NSBox *)box
                            y:(CGFloat)y
                        width:(CGFloat)w;

/* Tab builders */
- (NSTabViewItem *)tabItemWithIdentifier:(NSString *)identifier
                                   label:(NSString *)label
                                    size:(NSSize)size;
- (NSSlider *)curveSliderRowWithLabel:(NSString *)text
                               inView:(NSView *)view
                                    x:(CGFloat)x
                                    y:(CGFloat)y
                                label:(NSTextField **)label
                                value:(NSTextField **)value;
- (void)createGeneralTab:(NSTabViewItem *)tab;
- (void)createAccelerationTab:(NSTabViewItem *)tab;
@end

/* The pane view. When the host window gives us a width (which is not the
   560px base we built at), re-lay out the group boxes so the left/right
   margins to the window edge stay symmetric. */
@interface MouseMainView : NSView
{
    MouseController *_layoutOwner;
}
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
        isRefreshing = YES;
        backend = [[MouseBackend alloc] init];
        currentCurveProfile = [@"custom" copy];
        pendingCurve = AccelerationCurveDefaults();
        savedCurve = pendingCurve;
    }
    return self;
}

- (void)dealloc
{
    [mainView release];
    [mouseBox release];
    [trackpadBox release];
    [trackpadTabView release];
    [trackpadSpeedSlider release];
    [trackpadSpeedLabel release];
    [naturalScrollingCheckbox release];
    [tapToClickCheckbox release];
    [twoFingerRightClickCheckbox release];
    [threeFingerMiddleClickCheckbox release];
    [disableWhileTypingCheckbox release];
    [curveView release];
    [curveProfilePopup release];
    [precisionLabel release];
    [precisionValue release];
    [precisionSlider release];
    [startLabel release];
    [startValue release];
    [startSlider release];
    [endLabel release];
    [endValue release];
    [endSlider release];
    [fastLabel release];
    [fastValue release];
    [fastSlider release];
    [applyCurveButton release];
    [restoreCurveButton release];
    [mouseSpeedSlider release];
    [mouseSpeedLabel release];
    [leftHandedCheckbox release];
    [trackpointSpeedSlider release];
    [trackpointSpeedLabel release];
    [statusLabel release];
    [backend release];
    [currentCurveProfile release];
    [super dealloc];
}

/* ---- Tab builders ---- */

- (void)createGeneralTab:(NSTabViewItem *)tab
{
    NSView *content = [tab view];
    const CGFloat tabW = [content frame].size.width;
    const CGFloat rowH = 20;
    const CGFloat rowGap = METRICS_SPACE_8;
    const CGFloat sliderRowH = METRICS_TEXT_INPUT_FIELD_HEIGHT;

    CGFloat by = [content frame].size.height - METRICS_SPACE_16 - rowH;

    [self addCheckbox:tapToClickCheckbox =
               [[NSButton alloc] initWithFrame:NSZeroRect]
                toView:content y:by width:tabW];
    [tapToClickCheckbox setButtonType:NSSwitchButton];
    [tapToClickCheckbox setTitle:@"Tap to click"];
    [tapToClickCheckbox setTarget:self];
    [tapToClickCheckbox setAction:@selector(settingChanged:)];
    by -= rowH;

    [self addCheckbox:twoFingerRightClickCheckbox =
               [[NSButton alloc] initWithFrame:NSZeroRect]
                toView:content y:by width:tabW];
    [twoFingerRightClickCheckbox setButtonType:NSSwitchButton];
    [twoFingerRightClickCheckbox setTitle:@"Two-finger tap = right click"];
    [twoFingerRightClickCheckbox setTarget:self];
    [twoFingerRightClickCheckbox setAction:@selector(settingChanged:)];
    by -= rowH;

    [self addCheckbox:threeFingerMiddleClickCheckbox =
               [[NSButton alloc] initWithFrame:NSZeroRect]
                toView:content y:by width:tabW];
    [threeFingerMiddleClickCheckbox setButtonType:NSSwitchButton];
    [threeFingerMiddleClickCheckbox setTitle:@"Three-finger tap = middle click"];
    [threeFingerMiddleClickCheckbox setTarget:self];
    [threeFingerMiddleClickCheckbox setAction:@selector(settingChanged:)];
    by -= rowH;

    [self addCheckbox:disableWhileTypingCheckbox =
               [[NSButton alloc] initWithFrame:NSZeroRect]
                toView:content y:by width:tabW];
    [disableWhileTypingCheckbox setButtonType:NSSwitchButton];
    [disableWhileTypingCheckbox setTitle:@"Disable trackpad while typing"];
    [disableWhileTypingCheckbox setTarget:self];
    [disableWhileTypingCheckbox setAction:@selector(settingChanged:)];
    by -= rowH;

    [self addCheckbox:naturalScrollingCheckbox =
               [[NSButton alloc] initWithFrame:NSZeroRect]
                toView:content y:by width:tabW];
    [naturalScrollingCheckbox setButtonType:NSSwitchButton];
    [naturalScrollingCheckbox setTitle:@"Reverse scrolling direction"];
    [naturalScrollingCheckbox setTarget:self];
    [naturalScrollingCheckbox setAction:@selector(settingChanged:)];
    by -= rowGap + sliderRowH;

    [self addSliderRowWithLabel:@"Tracking speed:"
                         slider:trackpadSpeedSlider =
                         [[NSSlider alloc] initWithFrame:NSZeroRect]
                          value:trackpadSpeedLabel =
                         [[NSTextField alloc] initWithFrame:NSZeroRect]
                          toView:content y:by width:tabW];
    [trackpadSpeedSlider setMinValue:-1.0];
    [trackpadSpeedSlider setMaxValue:1.0];
    [trackpadSpeedSlider setFloatValue:0.0];
    [trackpadSpeedSlider setNumberOfTickMarks:11];
    [trackpadSpeedSlider setAllowsTickMarkValuesOnly:NO];
    [trackpadSpeedSlider setContinuous:YES];
    [trackpadSpeedSlider setTarget:self];
    [trackpadSpeedSlider setAction:@selector(settingChanged:)];
    [trackpadSpeedLabel setStringValue:@"0.00"];
}

- (void)createAccelerationTab:(NSTabViewItem *)tab
{
    NSView *content = [tab view];
    const CGFloat tabW = [content frame].size.width;
    const CGFloat tabH = [content frame].size.height;
    const CGFloat pad = METRICS_SPACE_16;
    const CGFloat gap = METRICS_SPACE_8;
    const CGFloat rowH = METRICS_TEXT_INPUT_FIELD_HEIGHT;
    const CGFloat btnW = METRICS_BUTTON_MIN_WIDTH;
    const CGFloat btnH = METRICS_BUTTON_HEIGHT;
    const CGFloat profileLabelW = 50;
    /* The tab is too short for the curve to sit above four slider rows, so
       the sliders stack beside it and the curve gets the full height. */
    const CGFloat columnW = kCurveLabelWidth + gap + kCurveSliderWidth + gap + kCurveValueWidth;
    const CGFloat columnX = tabW - pad - columnW;

    /* Profile row: pop-up on the left, Restore and Apply on the right */
    CGFloat by = tabH - pad - rowH;

    NSTextField *profileLabel = [self labelWithText:@"Profile:"
                                             frame:NSMakeRect(pad, by + 1, profileLabelW, 20)
                                         alignment:NSTextAlignmentLeft];
    [profileLabel setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
    [content addSubview:profileLabel];
    [profileLabel release];

    curveProfilePopup = [[NSPopUpButton alloc] initWithFrame:
        NSMakeRect(pad + profileLabelW + gap, by, 140, rowH) pullsDown:NO];
    [curveProfilePopup removeAllItems];
    [curveProfilePopup addItemsWithTitles:@[@"System", @"Flat", @"Custom"]];
    /* Items follow the profiles the device offers, not the menu's own
       validation. */
    [curveProfilePopup setAutoenablesItems:NO];
    [curveProfilePopup setTarget:self];
    [curveProfilePopup setAction:@selector(curveProfileChanged:)];
    [curveProfilePopup setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
    [content addSubview:curveProfilePopup];

    restoreCurveButton = [[NSButton alloc] initWithFrame:
        NSMakeRect(tabW - pad - 2 * btnW - gap, by + 1, btnW, btnH)];
    [restoreCurveButton setTitle:@"Restore"];
    [restoreCurveButton setBezelStyle:NSRoundedBezelStyle];
    [restoreCurveButton setTarget:self];
    [restoreCurveButton setAction:@selector(restoreCurve:)];
    [restoreCurveButton setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [content addSubview:restoreCurveButton];

    applyCurveButton = [[NSButton alloc] initWithFrame:
        NSMakeRect(tabW - pad - btnW, by + 1, btnW, btnH)];
    [applyCurveButton setTitle:@"Apply"];
    [applyCurveButton setBezelStyle:NSRoundedBezelStyle];
    [applyCurveButton setTarget:self];
    [applyCurveButton setAction:@selector(applyCurve:)];
    [applyCurveButton setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [content addSubview:applyCurveButton];

    /* Curve editor on the left, slider column on the right */
    CGFloat top = by - gap;
    curveView = [[CurveView alloc] initWithFrame:
        NSMakeRect(pad, pad, columnX - 2 * pad, top - pad)];
    [curveView setDelegate:self];
    [curveView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [content addSubview:curveView];

    by = top - rowH;
    precisionSlider = [self curveSliderRowWithLabel:@"Precision:" inView:content
                                                  x:columnX y:by
                                              label:&precisionLabel value:&precisionValue];
    [precisionSlider setMinValue:0.01];
    [precisionSlider setMaxValue:2.0];

    by -= rowH + gap;
    startSlider = [self curveSliderRowWithLabel:@"Start:" inView:content
                                              x:columnX y:by
                                          label:&startLabel value:&startValue];
    [startSlider setMinValue:0.0];
    [startSlider setMaxValue:1.0];

    by -= rowH + gap;
    endSlider = [self curveSliderRowWithLabel:@"End:" inView:content
                                            x:columnX y:by
                                        label:&endLabel value:&endValue];
    [endSlider setMinValue:0.0];
    [endSlider setMaxValue:1.0];

    by -= rowH + gap;
    fastSlider = [self curveSliderRowWithLabel:@"Fast swipes:" inView:content
                                             x:columnX y:by
                                         label:&fastLabel value:&fastValue];
    [fastSlider setMinValue:0.01];
    [fastSlider setMaxValue:2.0];

    [self updateCurveControls];
}

- (NSView *)createMainView
{
    if (mainView) {
        return mainView;
    }

    /* The pane area the host currently provides; the Trackpad box stretches
       to whatever it really is. */
    const CGFloat winW = 560, winH = 440;
    const CGFloat sideMargin = METRICS_CONTENT_SIDE_MARGIN;
    const CGFloat topMargin = METRICS_CONTENT_TOP_MARGIN;
    const CGFloat bottomMargin = METRICS_CONTENT_BOTTOM_MARGIN;
    const CGFloat boxGap = METRICS_SPACE_12;
    const CGFloat rowH = 20;
    const CGFloat sliderRowH = METRICS_TEXT_INPUT_FIELD_HEIGHT;
    const CGFloat statusH = 20;
    const CGFloat boxTitleInset = 14.0;
    /* The TrackPoint speed shares the Mouse box because a third box does not
       fit the pane height. */
    const CGFloat mouseBoxH = 126;

    mainView = [[MouseMainView alloc] initWithFrame:NSMakeRect(0, 0, winW, winH)];
    [(MouseMainView *)mainView setLayoutOwner:self];
    [mainView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    CGFloat contentW = winW - 2 * sideMargin;
    CGFloat boxW = contentW;

    CGFloat y = winH - topMargin;

    /* ---- Mouse group box ---- */
    mouseBox = [self groupBoxWithTitle:@"Mouse"
                                frame:NSMakeRect(sideMargin, y - mouseBoxH, boxW, mouseBoxH)
                               inView:mainView];
    {
        CGFloat by = mouseBoxH - boxTitleInset - METRICS_SPACE_16 - rowH;
        [self addCheckbox:leftHandedCheckbox = [[NSButton alloc]
                    initWithFrame:NSZeroRect]
                    toBox:mouseBox y:by width:boxW];
        [leftHandedCheckbox setButtonType:NSSwitchButton];
        [leftHandedCheckbox setTitle:@"Swap left and right buttons"];
        [leftHandedCheckbox setTarget:self];
        [leftHandedCheckbox setAction:@selector(settingChanged:)];

        by -= METRICS_SPACE_8 + sliderRowH;
        [self addSliderRowWithLabel:@"Tracking speed:"
                             slider:mouseSpeedSlider =
                             [[NSSlider alloc] initWithFrame:NSZeroRect]
                              value:mouseSpeedLabel =
                             [[NSTextField alloc] initWithFrame:NSZeroRect]
                              toBox:mouseBox y:by width:boxW];
        [mouseSpeedSlider setMinValue:-1.0];
        [mouseSpeedSlider setMaxValue:1.0];
        [mouseSpeedSlider setFloatValue:0.0];
        [mouseSpeedSlider setNumberOfTickMarks:11];
        [mouseSpeedSlider setAllowsTickMarkValuesOnly:NO];
        [mouseSpeedSlider setContinuous:YES];
        [mouseSpeedSlider setTarget:self];
        [mouseSpeedSlider setAction:@selector(settingChanged:)];
        [mouseSpeedLabel setStringValue:@"0.00"];

        by -= METRICS_SPACE_8 + sliderRowH;
        [self addSliderRowWithLabel:@"TrackPoint speed:"
                             slider:trackpointSpeedSlider =
                             [[NSSlider alloc] initWithFrame:NSZeroRect]
                              value:trackpointSpeedLabel =
                             [[NSTextField alloc] initWithFrame:NSZeroRect]
                              toBox:mouseBox y:by width:boxW];
        [trackpointSpeedSlider setMinValue:-1.0];
        [trackpointSpeedSlider setMaxValue:1.0];
        [trackpointSpeedSlider setFloatValue:0.0];
        [trackpointSpeedSlider setNumberOfTickMarks:11];
        [trackpointSpeedSlider setAllowsTickMarkValuesOnly:NO];
        [trackpointSpeedSlider setContinuous:YES];
        [trackpointSpeedSlider setTarget:self];
        [trackpointSpeedSlider setAction:@selector(settingChanged:)];
        [trackpointSpeedLabel setStringValue:@"0.00"];
    }
    y -= mouseBoxH + boxGap;

    /* ---- Trackpad group box (with tabs) ---- */
    CGFloat trackpadBoxH = y - (bottomMargin + statusH + METRICS_SPACE_8);
    trackpadBox = [self groupBoxWithTitle:@"Trackpad"
                                    frame:NSMakeRect(sideMargin, y - trackpadBoxH, boxW, trackpadBoxH)
                                   inView:mainView];
    [trackpadBox setAutoresizingMask:NSViewHeightSizable];
    {
        trackpadTabView = [[NSTabView alloc] initWithFrame:
            NSMakeRect(8, 8, boxW - 16, trackpadBoxH - 8 - boxTitleInset)];
        [trackpadTabView setTabViewType:NSTopTabsBezelBorder];
        [trackpadTabView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        /* Tab contents are laid out top-down from their real size; built at a
           placeholder size their rows end up outside the tab. */
        NSSize tabSize = [trackpadTabView contentRect].size;

        NSTabViewItem *generalTab = [self tabItemWithIdentifier:@"general"
                                                          label:@"General"
                                                           size:tabSize];
        [self createGeneralTab:generalTab];
        [trackpadTabView addTabViewItem:generalTab];
        [generalTab release];

        NSTabViewItem *accelTab = [self tabItemWithIdentifier:@"accel"
                                                        label:@"Acceleration Curve"
                                                         size:tabSize];
        [self createAccelerationTab:accelTab];
        [trackpadTabView addTabViewItem:accelTab];
        [accelTab release];

        [trackpadBox addSubview:trackpadTabView];
    }

    /* Status label at the bottom */
    statusLabel = [self labelWithText:@""
                                frame:NSMakeRect(sideMargin, bottomMargin,
                                                contentW, statusH)
                              alignment:NSTextAlignmentLeft];
    [statusLabel setFont:[NSFont systemFontOfSize:10]];
    [statusLabel setAutoresizingMask:(NSViewWidthSizable | NSViewMaxYMargin)];
    [mainView addSubview:statusLabel];

    /* The host may build this view without ever selecting the pane (to index
       its labels for search), so device discovery, hiding and disabling of
       device-dependent controls and value loading are left to
       refreshFromSystem, which runs on selection. */
    return mainView;
}

- (void)relayoutWithWidth:(CGFloat)width
{
    const CGFloat sideMargin = METRICS_CONTENT_SIDE_MARGIN;
    NSRect f;

    if (mouseBox) {
        f = [mouseBox frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [mouseBox setFrame:f];
    }
    if (trackpadBox) {
        f = [trackpadBox frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [trackpadBox setFrame:f];
    }
    if (trackpadTabView) {
        f = [trackpadTabView frame];
        f.size.width = [(NSView *)[trackpadBox contentView] frame].size.width - 16;
        [trackpadTabView setFrame:f];
    }
    if (statusLabel) {
        f = [statusLabel frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [statusLabel setFrame:f];
    }
}

/* ---- Layout helpers ---- */

/* Builders return retained objects so they can go straight into ivars that
   dealloc releases; callers that do not keep one release it themselves. */
- (NSBox *)groupBoxWithTitle:(NSString *)title frame:(NSRect)frame inView:(NSView *)parent
{
    NSBox *box = [[NSBox alloc] initWithFrame:frame];
    [box setTitle:title];
    [box setBoxType:NSBoxPrimary];
    [box setTitlePosition:NSAtTop];
    [box setBorderType:NSBezelBorder];
    [box setAutoresizingMask:NSViewMinYMargin];
    [parent addSubview:box];
    return box;
}

- (NSTextField *)labelWithText:(NSString *)text frame:(NSRect)frame alignment:(NSTextAlignment)align
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    [label setStringValue:text ?: @""];
    [label setBezeled:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setDrawsBackground:NO];
    [label setFont:[NSFont systemFontOfSize:11]];
    [label setAlignment:align];
    return label;
}

- (void)addCheckbox:(NSButton *)checkbox toBox:(NSBox *)box y:(CGFloat)y width:(CGFloat)w
{
    [checkbox setFrame:NSMakeRect(METRICS_SPACE_16, y, w - 2 * METRICS_SPACE_16, 18)];
    [checkbox setAutoresizingMask:NSViewWidthSizable];
    [box addSubview:checkbox];
}

/* Tab contents follow the tab's height, so their rows keep their distance
   from its top. */
- (void)addCheckbox:(NSButton *)checkbox toView:(NSView *)view y:(CGFloat)y width:(CGFloat)w
{
    [checkbox setFrame:NSMakeRect(METRICS_SPACE_16, y, w - 2 * METRICS_SPACE_16, 18)];
    [checkbox setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [view addSubview:checkbox];
}

- (void)addSliderRowWithLabel:(NSString *)label
                       slider:(NSSlider *)slider
                        value:(NSTextField *)value
                        toBox:(NSBox *)box
                            y:(CGFloat)y
                        width:(CGFloat)w
{
    const CGFloat pad = METRICS_SPACE_16;
    const CGFloat labelW = 110;
    const CGFloat valueW = 50;
    const CGFloat gap = METRICS_SPACE_8;
    const CGFloat sliderW = w - 2 * pad - labelW - valueW - 2 * gap;

    NSTextField *labelField = [self labelWithText:label
                                            frame:NSMakeRect(pad, y + 1, labelW, 20)
                                        alignment:NSTextAlignmentRight];
    [labelField setFont:[NSFont systemFontOfSize:11]];
    [labelField setAutoresizingMask:NSViewMaxXMargin];
    [box addSubview:labelField];
    [labelField release];

    [slider setFrame:NSMakeRect(pad + labelW + gap, y, sliderW, 22)];
    [slider setAutoresizingMask:NSViewWidthSizable];
    [box addSubview:slider];

    [value setFrame:NSMakeRect(pad + labelW + gap + sliderW + gap, y, valueW, 20)];
    [value setAutoresizingMask:NSViewMinXMargin];
    [value setBezeled:NO];
    [value setEditable:NO];
    [value setSelectable:NO];
    [value setDrawsBackground:NO];
    [value setFont:[NSFont systemFontOfSize:11]];
    [box addSubview:value];
}

- (void)addSliderRowWithLabel:(NSString *)label
                       slider:(NSSlider *)slider
                        value:(NSTextField *)value
                        toView:(NSView *)view
                            y:(CGFloat)y
                        width:(CGFloat)w
{
    const CGFloat pad = METRICS_SPACE_16;
    const CGFloat labelW = 110;
    const CGFloat valueW = 50;
    const CGFloat gap = METRICS_SPACE_8;
    const CGFloat sliderW = w - 2 * pad - labelW - valueW - 2 * gap;

    NSTextField *labelField = [self labelWithText:label
                                            frame:NSMakeRect(pad, y + 1, labelW, 20)
                                        alignment:NSTextAlignmentRight];
    [labelField setFont:[NSFont systemFontOfSize:11]];
    [labelField setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
    [view addSubview:labelField];
    [labelField release];

    [slider setFrame:NSMakeRect(pad + labelW + gap, y, sliderW, 22)];
    [slider setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [view addSubview:slider];

    [value setFrame:NSMakeRect(pad + labelW + gap + sliderW + gap, y, valueW, 20)];
    [value setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [value setBezeled:NO];
    [value setEditable:NO];
    [value setSelectable:NO];
    [value setDrawsBackground:NO];
    [value setFont:[NSFont systemFontOfSize:11]];
    [view addSubview:value];
}

- (NSTabViewItem *)tabItemWithIdentifier:(NSString *)identifier
                                   label:(NSString *)label
                                    size:(NSSize)size
{
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:identifier];
    [item setLabel:label];
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    [view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [item setView:view];
    [view release];
    return item;
}

/* One row of the slider column beside the curve, anchored to the tab's top
   right corner; the label and value fields come back retained for their
   ivars. */
- (NSSlider *)curveSliderRowWithLabel:(NSString *)text
                               inView:(NSView *)view
                                    x:(CGFloat)x
                                    y:(CGFloat)y
                                label:(NSTextField **)label
                                value:(NSTextField **)value
{
    const CGFloat gap = METRICS_SPACE_8;
    const NSUInteger mask = NSViewMinXMargin | NSViewMinYMargin;

    *label = [self labelWithText:text
                           frame:NSMakeRect(x, y + 1, kCurveLabelWidth, 20)
                       alignment:NSTextAlignmentRight];
    [*label setAutoresizingMask:mask];
    [view addSubview:*label];

    NSSlider *slider = [[NSSlider alloc] initWithFrame:
        NSMakeRect(x + kCurveLabelWidth + gap, y, kCurveSliderWidth,
                   METRICS_TEXT_INPUT_FIELD_HEIGHT)];
    [slider setContinuous:YES];
    [slider setTarget:self];
    [slider setAction:@selector(sliderValueChanged:)];
    [slider setAutoresizingMask:mask];
    [view addSubview:slider];

    *value = [self labelWithText:@""
                           frame:NSMakeRect(x + kCurveLabelWidth + gap + kCurveSliderWidth + gap,
                                            y + 1, kCurveValueWidth, 20)
                       alignment:NSTextAlignmentLeft];
    [*value setAutoresizingMask:mask];
    [view addSubview:*value];
    return slider;
}

/* ---- Curve helpers ---- */

- (void)syncCurveSlidersFromCurve:(AccelerationCurve)curve showsRange:(BOOL)showsRange
{
    [precisionSlider setDoubleValue:curve.precision];
    [precisionValue setStringValue:[NSString stringWithFormat:@"%.2fx", curve.precision]];
    [startSlider setDoubleValue:curve.start];
    [endSlider setDoubleValue:curve.end];
    if (showsRange) {
        [startValue setStringValue:[NSString stringWithFormat:@"%.0f mm/s",
            curve.start * AccelerationCurveMaxSpeed]];
        [endValue setStringValue:[NSString stringWithFormat:@"%.0f mm/s",
            curve.end * AccelerationCurveMaxSpeed]];
    } else {
        /* Flat accelerates nowhere, so there is no range to report. */
        [startValue setStringValue:@"-"];
        [endValue setStringValue:@"-"];
    }
    [fastSlider setDoubleValue:curve.fast];
    [fastValue setStringValue:[NSString stringWithFormat:@"%.2fx", curve.fast]];
}

- (void)updateCurveControls
{
    BOOL isCustom = [currentCurveProfile isEqualToString:@"custom"];
    BOOL edited = !AccelerationCurveEqualToCurve(pendingCurve, savedCurve);
    double speed = [trackpadSpeedSlider doubleValue];
    AccelerationCurve shown = pendingCurve;
    NSArray *gains = nil;
    BOOL showsRange = YES;

    /* The built-in profiles are shown, read-only, as what they do at the
       current tracking speed, so a custom curve can be compared with them. */
    if ([currentCurveProfile isEqualToString:@"system"]) {
        shown = AccelerationAdaptiveCurve(speed);
        gains = AccelerationAdaptiveGains(speed, 101);
    } else if ([currentCurveProfile isEqualToString:@"flat"]) {
        double gain = AccelerationFlatGain(speed);
        shown.precision = gain;
        shown.start = 0.0;
        shown.end = 1.0;
        shown.fast = gain;
        showsRange = NO;
    }

    [curveProfilePopup selectItemAtIndex:CurveProfileIndex(currentCurveProfile)];
    /* Fast speed settings push the built-in curves above the editing range. */
    [curveView setMaximum:MAX(2.0, ceil(MAX(shown.precision, shown.fast) * 2.0) / 2.0)];
    [curveView setDisplayedGains:gains];
    [curveView setShowsRange:showsRange];
    [curveView setCurve:shown];
    [curveView setCurveEnabled:isCustom];
    [self syncCurveSlidersFromCurve:shown showsRange:showsRange];
    [precisionSlider setEnabled:isCustom];
    [startSlider setEnabled:isCustom];
    [endSlider setEnabled:isCustom];
    [fastSlider setEnabled:isCustom];
    [applyCurveButton setEnabled:(isCustom && edited)];
    [restoreCurveButton setEnabled:(isCustom && edited)];
    /* libinput ignores the speed setting while the custom profile is on. */
    [trackpadSpeedSlider setEnabled:!isCustom];
}

- (BOOL)applyCurveProfile:(NSString *)profile curve:(AccelerationCurve)curve
{
    if (![backend touchpadName]) {
        return NO;
    }
    NSArray *points = nil;
    double step = 0.0;
    if ([profile isEqualToString:@"custom"]) {
        if (touchpadUnitsPerMM <= 0.0) {
            return NO;
        }
        points = AccelerationCurvePoints(curve, touchpadUnitsPerMM);
        step = AccelerationCurvePointStep(touchpadUnitsPerMM);
    }
    return [backend applyTrackpadAccelProfile:profile customPoints:points step:step];
}

- (void)updateSectionTitles
{
    BOOL hasTrackpoint = ([[backend trackpointName] length] > 0);
    [trackpointSpeedSlider setEnabled:hasTrackpoint];
    [trackpadTabView setHidden:(![[backend touchpadName] length])];
}

/* ---- Actions ---- */

- (IBAction)settingChanged:(id)sender
{
    (void)sender;
    if (isRefreshing) {
        return;
    }
    [self applyAllSettings];
    /* The built-in profiles' curves depend on the tracking speed. */
    [self updateCurveControls];
}

- (IBAction)curveProfileChanged:(id)sender
{
    (void)sender;
    if (isRefreshing) {
        return;
    }
    NSString *profile = kCurveProfiles[[curveProfilePopup indexOfSelectedItem]];
    /* Custom takes the curve on screen; a built-in profile drops unapplied
       edits so the editor never shows a curve the device does not have. */
    AccelerationCurve curve = [profile isEqualToString:@"custom"] ? pendingCurve : savedCurve;
    if ([self applyCurveProfile:profile curve:curve]) {
        [currentCurveProfile release];
        currentCurveProfile = [profile copy];
        savedCurve = curve;
        pendingCurve = curve;
        [self persistSettings];
        [self updateStatus:@"Acceleration profile applied"];
    } else {
        [self updateStatus:@"Could not change the trackpad acceleration profile"];
    }
    [self updateCurveControls];
}

- (IBAction)sliderValueChanged:(id)sender
{
    if (isRefreshing) return;

    if (sender == precisionSlider) {
        pendingCurve.precision = [precisionSlider doubleValue];
        if (pendingCurve.precision > pendingCurve.fast) {
            pendingCurve.fast = pendingCurve.precision;
        }
    } else if (sender == startSlider) {
        pendingCurve.start = [startSlider doubleValue];
        if (pendingCurve.start >= pendingCurve.end - 0.02) {
            pendingCurve.start = pendingCurve.end - 0.02;
        }
    } else if (sender == endSlider) {
        pendingCurve.end = [endSlider doubleValue];
        if (pendingCurve.end <= pendingCurve.start + 0.02) {
            pendingCurve.end = pendingCurve.start + 0.02;
        }
    } else if (sender == fastSlider) {
        pendingCurve.fast = [fastSlider doubleValue];
        if (pendingCurve.fast < pendingCurve.precision) {
            pendingCurve.fast = pendingCurve.precision;
        }
    }
    [self updateCurveControls];
}

- (IBAction)applyCurve:(id)sender
{
    (void)sender;
    if (isRefreshing) return;
    if (![self applyCurveProfile:@"custom" curve:pendingCurve]) {
        [self updateStatus:@"Could not apply the acceleration curve"];
        return;
    }
    [currentCurveProfile release];
    currentCurveProfile = [@"custom" copy];
    savedCurve = pendingCurve;
    [self persistSettings];
    [self updateCurveControls];
    [self updateStatus:@"Acceleration curve applied"];
}

- (IBAction)restoreCurve:(id)sender
{
    (void)sender;
    if (isRefreshing) return;
    pendingCurve = savedCurve;
    [self updateCurveControls];
    [self updateStatus:@"Acceleration curve restored"];
}

/* CurveViewDelegate */
- (void)curveViewDidChange:(CurveView *)cv
{
    (void)cv;
    pendingCurve = [curveView curve];
    [self updateCurveControls];
}

/* ---- Settings application ---- */

- (void)applyAllSettings
{
    if (isRefreshing) {
        return;
    }
    [backend applyNaturalScrolling:([naturalScrollingCheckbox state] == NSOnState)];
    [backend applyLeftHanded:([leftHandedCheckbox state] == NSOnState)];

    float mSpeed = [mouseSpeedSlider floatValue];
    [mouseSpeedLabel setFloatValue:mSpeed];
    [backend applyMouseSpeed:mSpeed];

    float tSpeed = [trackpadSpeedSlider floatValue];
    [trackpadSpeedLabel setFloatValue:tSpeed];
    [backend applyTrackpadSpeed:tSpeed];

    float tpSpeed = [trackpointSpeedSlider floatValue];
    [trackpointSpeedLabel setFloatValue:tpSpeed];
    [backend applyTrackpointSpeed:tpSpeed];

    [backend applyTapToClick:([tapToClickCheckbox state] == NSOnState)];
    [backend applyTwoFingerRightClick:([twoFingerRightClickCheckbox state] == NSOnState)
               threeFingerMiddleClick:([threeFingerMiddleClickCheckbox state] == NSOnState)];
    [backend applyDisableWhileTyping:([disableWhileTypingCheckbox state] == NSOnState)];

    [self persistSettings];
}

- (void)refreshFromSystem
{
    isRefreshing = YES;
    /* Enumerate even without xinput so the device-dependent controls show
       that no device is available instead of keeping their built state. */
    [backend refresh];
    [self updateSectionTitles];
    if (![backend xinputPath]) {
        [self updateStatus:@"xinput not found. Install xinput package."];
        isRefreshing = NO;
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *tpProps = nil;
        NSDictionary *mProps = nil;
        NSDictionary *tppProps = nil;
        if ([backend touchpadName]) {
            tpProps = [backend propertiesForDevice:[backend touchpadName]];
        }
        if ([backend mouseName]) {
            mProps = [backend propertiesForDevice:[backend mouseName]];
        }
        if ([backend trackpointName]) {
            tppProps = [backend propertiesForDevice:[backend trackpointName]];
        }
        /* Reads the evdev node, so it stays off the main thread too. */
        double unitsPerMM = [MouseBackend unitsPerMMForProperties:tpProps];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *tpSpeedStr = [MouseBackend propertyValue:tpProps name:@"Accel Speed"];
            NSString *mSpeedStr = [MouseBackend propertyValue:mProps name:@"Accel Speed"];
            NSString *tppSpeedStr = [MouseBackend propertyValue:tppProps name:@"Accel Speed"];
            NSString *tpTapStr = [MouseBackend propertyValue:tpProps name:@"Tapping Enabled"];
            NSString *tpNaturalStr = [MouseBackend propertyValue:tpProps name:@"Natural Scrolling Enabled"];
            NSString *mNaturalStr = [MouseBackend propertyValue:mProps name:@"Natural Scrolling Enabled"];
            NSString *tpLeftStr = [MouseBackend propertyValue:tpProps name:@"Left Handed Enabled"];
            NSString *mLeftStr = [MouseBackend propertyValue:mProps name:@"Left Handed Enabled"];
            NSString *tpDwtStr = [MouseBackend propertyValue:tpProps name:@"Disable While Typing Enabled"];
            NSString *tpBtnMapStr = [MouseBackend propertyValue:tpProps name:@"Tapping Button Mapping Enabled"];

            if (mSpeedStr) {
                [mouseSpeedSlider setFloatValue:[mSpeedStr floatValue]];
                [mouseSpeedLabel setStringValue:[NSString stringWithFormat:@"%.2f", [mSpeedStr floatValue]]];
            } else if (tpSpeedStr) {
                [mouseSpeedSlider setFloatValue:[tpSpeedStr floatValue]];
                [mouseSpeedLabel setStringValue:[NSString stringWithFormat:@"%.2f", [tpSpeedStr floatValue]]];
            }
            if (tpSpeedStr) {
                [trackpadSpeedSlider setFloatValue:[tpSpeedStr floatValue]];
                [trackpadSpeedLabel setStringValue:[NSString stringWithFormat:@"%.2f", [tpSpeedStr floatValue]]];
            }
            if (tppSpeedStr) {
                [trackpointSpeedSlider setFloatValue:[tppSpeedStr floatValue]];
                [trackpointSpeedLabel setStringValue:[NSString stringWithFormat:@"%.2f", [tppSpeedStr floatValue]]];
            }
            if (tpNaturalStr) {
                [naturalScrollingCheckbox setState:([tpNaturalStr intValue] ? NSOnState : NSOffState)];
            } else if (mNaturalStr) {
                [naturalScrollingCheckbox setState:([mNaturalStr intValue] ? NSOnState : NSOffState)];
            }
            if (tpLeftStr) {
                [leftHandedCheckbox setState:([tpLeftStr intValue] ? NSOnState : NSOffState)];
            } else if (mLeftStr) {
                [leftHandedCheckbox setState:([mLeftStr intValue] ? NSOnState : NSOffState)];
            }
            if (tpTapStr) {
                [tapToClickCheckbox setState:([tpTapStr intValue] ? NSOnState : NSOffState)];
            }
            if (tpBtnMapStr) {
                NSArray *parts = [tpBtnMapStr componentsSeparatedByString:@","];
                if ([parts count] >= 2) {
                    int v1 = [[parts objectAtIndex:0] intValue];
                    int v2 = [[parts objectAtIndex:1] intValue];
                    [twoFingerRightClickCheckbox setState:(v1 != 0 ? NSOnState : NSOffState)];
                    [threeFingerMiddleClickCheckbox setState:(v1 == 0 && v2 == 0 ? NSOnState : NSOffState)];
                }
            }
            if (tpDwtStr) {
                [disableWhileTypingCheckbox setState:([tpDwtStr intValue] ? NSOnState : NSOffState)];
            }

            /* Restore persisted settings */
            {
                NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                NSDictionary *persisted = [defaults persistentDomainForName:kMouseDomain];
                if (persisted) {
                    NSNumber *val;

                    val = [persisted objectForKey:@"naturalScrolling"];
                    if (val) {
                        [naturalScrollingCheckbox setState:[val boolValue] ? NSOnState : NSOffState];
                    }
                    val = [persisted objectForKey:@"leftHanded"];
                    if (val) {
                        [leftHandedCheckbox setState:[val boolValue] ? NSOnState : NSOffState];
                    }
                    val = [persisted objectForKey:@"tapToClick"];
                    if (val) {
                        [tapToClickCheckbox setState:[val boolValue] ? NSOnState : NSOffState];
                    }
                    val = [persisted objectForKey:@"twoFingerRightClick"];
                    if (val) {
                        [twoFingerRightClickCheckbox setState:[val boolValue] ? NSOnState : NSOffState];
                    }
                    val = [persisted objectForKey:@"threeFingerMiddleClick"];
                    if (val) {
                        [threeFingerMiddleClickCheckbox setState:[val boolValue] ? NSOnState : NSOffState];
                    }
                    val = [persisted objectForKey:@"disableWhileTyping"];
                    if (val) {
                        [disableWhileTypingCheckbox setState:[val boolValue] ? NSOnState : NSOffState];
                    }
                    val = [persisted objectForKey:@"mouseSpeed"];
                    if (val) {
                        [mouseSpeedSlider setFloatValue:[val floatValue]];
                        [mouseSpeedLabel setStringValue:[NSString stringWithFormat:@"%.2f", [val floatValue]]];
                    }
                    val = [persisted objectForKey:@"trackpadSpeed"];
                    if (val) {
                        [trackpadSpeedSlider setFloatValue:[val floatValue]];
                        [trackpadSpeedLabel setStringValue:[NSString stringWithFormat:@"%.2f", [val floatValue]]];
                    }
                    val = [persisted objectForKey:@"trackpointSpeed"];
                    if (val) {
                        [trackpointSpeedSlider setFloatValue:[val floatValue]];
                        [trackpointSpeedLabel setStringValue:[NSString stringWithFormat:@"%.2f", [val floatValue]]];
                    }

                    /* Only the last applied curve lives solely in the
                       defaults; the active profile is read from the device
                       below. */
                    val = [persisted objectForKey:@"curvePrecision"];
                    if (val) savedCurve.precision = [val doubleValue];
                    val = [persisted objectForKey:@"curveStart"];
                    if (val) savedCurve.start = [val doubleValue];
                    val = [persisted objectForKey:@"curveEnd"];
                    if (val) savedCurve.end = [val doubleValue];
                    val = [persisted objectForKey:@"curveFast"];
                    if (val) savedCurve.fast = [val doubleValue];
                }
            }
            pendingCurve = savedCurve;

            /* The device, not the defaults, says which profile is active:
               nothing re-applies the saved one at login. */
            NSArray *available = [[MouseBackend propertyValue:tpProps name:@"Accel Profiles Available"]
                componentsSeparatedByString:@","];
            NSArray *enabled = [[MouseBackend propertyValue:tpProps name:@"Accel Profile Enabled"]
                componentsSeparatedByString:@","];
            touchpadUnitsPerMM = unitsPerMM;
            for (NSUInteger i = 0; i < kCurveProfileCount; i++) {
                BOOL offered = (i < [available count]
                                && [[available objectAtIndex:i] intValue] == 1);
                /* Without the resolution the curve cannot be converted, so
                   Custom is not offered rather than applied wrongly. */
                if ([kCurveProfiles[i] isEqualToString:@"custom"] && touchpadUnitsPerMM <= 0.0) {
                    offered = NO;
                }
                [[curveProfilePopup itemAtIndex:i] setEnabled:offered];
                if (i < [enabled count] && [[enabled objectAtIndex:i] intValue] == 1) {
                    [currentCurveProfile release];
                    currentCurveProfile = [kCurveProfiles[i] copy];
                }
            }
            [self updateCurveControls];

            isRefreshing = NO;
            NSMutableString *status = [NSMutableString stringWithFormat:@"Applied"];
            if ([backend touchpadName]) {
                [status appendFormat:@" | Trackpad: %@", [backend touchpadName]];
            }
            if ([backend mouseName]) {
                [status appendFormat:@" | Mouse: %@", [backend mouseName]];
            }
            if ([backend trackpointName]) {
                [status appendFormat:@" | TrackPoint: %@", [backend trackpointName]];
            }
            if ([backend touchpadName] && touchpadUnitsPerMM <= 0.0) {
                [status appendString:@" | Custom curve unavailable: touchpad resolution unreadable"];
            }
            [self updateStatus:status];
        });
    });
}

- (void)persistSettings
{
    NSMutableDictionary *domain = [NSMutableDictionary dictionary];
    [domain setObject:[NSNumber numberWithFloat:[mouseSpeedSlider floatValue]] forKey:@"mouseSpeed"];
    [domain setObject:[NSNumber numberWithFloat:[trackpadSpeedSlider floatValue]] forKey:@"trackpadSpeed"];
    [domain setObject:[NSNumber numberWithFloat:[trackpointSpeedSlider floatValue]] forKey:@"trackpointSpeed"];
    [domain setObject:[NSNumber numberWithBool:([naturalScrollingCheckbox state] == NSOnState)] forKey:@"naturalScrolling"];
    [domain setObject:[NSNumber numberWithBool:([leftHandedCheckbox state] == NSOnState)] forKey:@"leftHanded"];
    [domain setObject:[NSNumber numberWithBool:([tapToClickCheckbox state] == NSOnState)] forKey:@"tapToClick"];
    [domain setObject:[NSNumber numberWithBool:([twoFingerRightClickCheckbox state] == NSOnState)] forKey:@"twoFingerRightClick"];
    [domain setObject:[NSNumber numberWithBool:([threeFingerMiddleClickCheckbox state] == NSOnState)] forKey:@"threeFingerMiddleClick"];
    [domain setObject:[NSNumber numberWithBool:([disableWhileTypingCheckbox state] == NSOnState)] forKey:@"disableWhileTyping"];

    /* Curve settings */
    [domain setObject:currentCurveProfile forKey:@"curveProfile"];
    [domain setObject:[NSNumber numberWithDouble:savedCurve.precision] forKey:@"curvePrecision"];
    [domain setObject:[NSNumber numberWithDouble:savedCurve.start] forKey:@"curveStart"];
    [domain setObject:[NSNumber numberWithDouble:savedCurve.end] forKey:@"curveEnd"];
    [domain setObject:[NSNumber numberWithDouble:savedCurve.fast] forKey:@"curveFast"];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setPersistentDomain:domain forName:kMouseDomain];
    [defaults synchronize];
}

- (void)updateStatus:(NSString *)message
{
    [statusLabel setStringValue:(message ? message : @"")];
}

@end
