/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MouseController.h"
#import "MouseBackend.h"
#import "AppearanceMetrics.h"
#import <dispatch/dispatch.h>

static NSString *const kMouseDomain = @"MousePreferences";

@interface MouseController ()
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
        /* The host window does not necessarily size the pane view to its
           content area; make it fill the box content and re-lay out so the
           left/right margins stay symmetric.  GNUstep's setFrame: bypasses
           setFrameSize:, so re-lay out explicitly here. */
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
    }
    return self;
}

- (void)dealloc
{
    [mainView release];
    [mouseBox release];
    [trackpadBox release];
    [trackpointBox release];
    [mouseSpeedSlider release];
    [mouseSpeedLabel release];
    [trackpadSpeedSlider release];
    [trackpadSpeedLabel release];
    [trackpointSpeedSlider release];
    [trackpointSpeedLabel release];
    [naturalScrollingCheckbox release];
    [tapToClickCheckbox release];
    [twoFingerRightClickCheckbox release];
    [threeFingerMiddleClickCheckbox release];
    [disableWhileTypingCheckbox release];
    [leftHandedCheckbox release];
    [statusLabel release];
    [backend release];
    [super dealloc];
}

- (NSView *)createMainView
{
    if (mainView) {
        return mainView;
    }

    const CGFloat winW = 560, winH = 445;
    const CGFloat sideMargin = METRICS_CONTENT_SIDE_MARGIN;      /* 24 */
    const CGFloat topMargin = METRICS_CONTENT_TOP_MARGIN;        /* 15 */
    const CGFloat bottomMargin = METRICS_CONTENT_BOTTOM_MARGIN;  /* 20 */
    const CGFloat boxGap = METRICS_SPACE_12;                     /* between group boxes */
    const CGFloat rowGap = METRICS_SPACE_8;
    const CGFloat rowH = 20;                                     /* checkbox line spacing */
    const CGFloat sliderRowH = METRICS_TEXT_INPUT_FIELD_HEIGHT;  /* 22 */
    /* NSBox with NSAtTop title reserves ~14px for the title text before
       its content area starts.  The first control must clear that. */
    const CGFloat boxTitleInset = 14.0;
    /* Group-box heights sized to their content (title inset + rows +
       16px inner margin top and bottom), so the status line at the
       bottom does not overlap the last box. */
    const CGFloat mouseBoxH = 96;
    const CGFloat trackpadBoxH = 176;
    const CGFloat trackpointBoxH = 68;

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

        by -= rowGap + sliderRowH;
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
    }
    y -= mouseBoxH + boxGap;

    /* ---- Trackpad group box ---- */
    trackpadBox = [self groupBoxWithTitle:@"Trackpad"
                                    frame:NSMakeRect(sideMargin, y - trackpadBoxH, boxW, trackpadBoxH)
                                   inView:mainView];
    {
        CGFloat by = trackpadBoxH - boxTitleInset - METRICS_SPACE_16 - rowH;
        [self addCheckbox:tapToClickCheckbox =
                   [[NSButton alloc] initWithFrame:NSZeroRect]
                    toBox:trackpadBox y:by width:boxW];
        [tapToClickCheckbox setButtonType:NSSwitchButton];
        [tapToClickCheckbox setTitle:@"Tap to click"];
        [tapToClickCheckbox setTarget:self];
        [tapToClickCheckbox setAction:@selector(settingChanged:)];
        by -= rowH;

        [self addCheckbox:twoFingerRightClickCheckbox =
                   [[NSButton alloc] initWithFrame:NSZeroRect]
                    toBox:trackpadBox y:by width:boxW];
        [twoFingerRightClickCheckbox setButtonType:NSSwitchButton];
        [twoFingerRightClickCheckbox setTitle:@"Two-finger tap = right click"];
        [twoFingerRightClickCheckbox setTarget:self];
        [twoFingerRightClickCheckbox setAction:@selector(settingChanged:)];
        by -= rowH;

        [self addCheckbox:threeFingerMiddleClickCheckbox =
                   [[NSButton alloc] initWithFrame:NSZeroRect]
                    toBox:trackpadBox y:by width:boxW];
        [threeFingerMiddleClickCheckbox setButtonType:NSSwitchButton];
        [threeFingerMiddleClickCheckbox setTitle:@"Three-finger tap = middle click"];
        [threeFingerMiddleClickCheckbox setTarget:self];
        [threeFingerMiddleClickCheckbox setAction:@selector(settingChanged:)];
        by -= rowH;

        [self addCheckbox:disableWhileTypingCheckbox =
                   [[NSButton alloc] initWithFrame:NSZeroRect]
                    toBox:trackpadBox y:by width:boxW];
        [disableWhileTypingCheckbox setButtonType:NSSwitchButton];
        [disableWhileTypingCheckbox setTitle:@"Disable trackpad while typing"];
        [disableWhileTypingCheckbox setTarget:self];
        [disableWhileTypingCheckbox setAction:@selector(settingChanged:)];
        by -= rowH;

        [self addCheckbox:naturalScrollingCheckbox =
                   [[NSButton alloc] initWithFrame:NSZeroRect]
                    toBox:trackpadBox y:by width:boxW];
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
                              toBox:trackpadBox y:by width:boxW];
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
    y -= trackpadBoxH + boxGap;

    /* ---- TrackPoint group box ---- */
    trackpointBox = [self groupBoxWithTitle:@"TrackPoint"
                                      frame:NSMakeRect(sideMargin, y - trackpointBoxH, boxW, trackpointBoxH)
                                     inView:mainView];
    {
        CGFloat by = trackpointBoxH - boxTitleInset - METRICS_SPACE_16 - sliderRowH;
        [self addSliderRowWithLabel:@"Tracking speed:"
                             slider:trackpointSpeedSlider =
                             [[NSSlider alloc] initWithFrame:NSZeroRect]
                              value:trackpointSpeedLabel =
                             [[NSTextField alloc] initWithFrame:NSZeroRect]
                              toBox:trackpointBox y:by width:boxW];
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

    // Status label at the bottom, bottom-anchored
    statusLabel = [self labelWithText:@""
                                frame:NSMakeRect(sideMargin, bottomMargin,
                                                contentW, 20)
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

/* Re-lay out the group boxes for the given view width, keeping the
   left and right margins equal. Called whenever the host resizes the
   pane view. */
- (void)relayoutWithWidth:(CGFloat)width
{
    const CGFloat sideMargin = METRICS_CONTENT_SIDE_MARGIN;  /* 24 */
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
    if (trackpointBox) {
        f = [trackpointBox frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [trackpointBox setFrame:f];
    }
    if (statusLabel) {
        f = [statusLabel frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [statusLabel setFrame:f];
    }
}

/* Build a titled group box, top-anchored and width-flexible. Builders return
   retained objects so they can go straight into ivars that dealloc releases;
   callers that do not keep one release it themselves. */
- (NSBox *)groupBoxWithTitle:(NSString *)title frame:(NSRect)frame inView:(NSView *)parent
{
    NSBox *box = [[NSBox alloc] initWithFrame:frame];
    [box setTitle:title];
    [box setBoxType:NSBoxPrimary];
    [box setTitlePosition:NSAtTop];
    /* Bezel border: Eau draws bezel boxes with rounded corners
       (drawDarkBezel:), a plain line border stays square. */
    [box setBorderType:NSBezelBorder];
    /* Width is managed by relayoutWithWidth: so margins stay symmetric;
       keep vertical position only. */
    [box setAutoresizingMask:NSViewMinYMargin];
    [parent addSubview:box];
    return box;
}

/* A plain read-only label. */
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

/* Position a checkbox in the top-left of a group box's content area.
   Width-flexible so it tracks the box when the pane is wider than the
   560px base layout the Mouse pane was designed for. */
- (void)addCheckbox:(NSButton *)checkbox toBox:(NSBox *)box y:(CGFloat)y width:(CGFloat)w
{
    [checkbox setFrame:NSMakeRect(METRICS_SPACE_16, y, w - 2 * METRICS_SPACE_16, 18)];
    [checkbox setAutoresizingMask:NSViewWidthSizable];
    [box addSubview:checkbox];
}

/* A label + slider + value row in a group box: label on the left (right
   aligned), slider stretching, value label on the right. */
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

- (void)updateSectionTitles
{
    BOOL hasTrackpoint = ([[backend trackpointName] length] > 0);
    [trackpointSpeedSlider setEnabled:hasTrackpoint];
}

- (IBAction)settingChanged:(id)sender
{
    (void)sender;
    if (isRefreshing) {
        return;
    }
    [self applyAllSettings];
}

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
            NSString *tpBtnMapStr = [MouseBackend propertyValue:tpProps name:@"Tapping Button Mapping"];
            // Set mouse speed (affects both touchpad and mouse via same slider)
            if (mSpeedStr) {
                [mouseSpeedSlider setFloatValue:[mSpeedStr floatValue]];
                [mouseSpeedLabel setStringValue:[NSString stringWithFormat:@"%.2f", [mSpeedStr floatValue]]];
            } else if (tpSpeedStr) {
                [mouseSpeedSlider setFloatValue:[tpSpeedStr floatValue]];
                [mouseSpeedLabel setStringValue:[NSString stringWithFormat:@"%.2f", [tpSpeedStr floatValue]]];
            }
            // Set trackpad speed
            if (tpSpeedStr) {
                [trackpadSpeedSlider setFloatValue:[tpSpeedStr floatValue]];
                [trackpadSpeedLabel setStringValue:[NSString stringWithFormat:@"%.2f", [tpSpeedStr floatValue]]];
            }
            // Set TrackPoint speed
            if (tppSpeedStr) {
                [trackpointSpeedSlider setFloatValue:[tppSpeedStr floatValue]];
                [trackpointSpeedLabel setStringValue:[NSString stringWithFormat:@"%.2f", [tppSpeedStr floatValue]]];
            }
            // Natural scrolling
            if (tpNaturalStr) {
                [naturalScrollingCheckbox setState:([tpNaturalStr intValue] ? NSOnState : NSOffState)];
            } else if (mNaturalStr) {
                [naturalScrollingCheckbox setState:([mNaturalStr intValue] ? NSOnState : NSOffState)];
            }
            // Left handed
            if (tpLeftStr) {
                [leftHandedCheckbox setState:([tpLeftStr intValue] ? NSOnState : NSOffState)];
            } else if (mLeftStr) {
                [leftHandedCheckbox setState:([mLeftStr intValue] ? NSOnState : NSOffState)];
            }
            // Tap to click
            if (tpTapStr) {
                [tapToClickCheckbox setState:([tpTapStr intValue] ? NSOnState : NSOffState)];
            }
            // Tap button mapping
            if (tpBtnMapStr) {
                NSArray *parts = [tpBtnMapStr componentsSeparatedByString:@","];
                if ([parts count] >= 2) {
                    int v1 = [[parts objectAtIndex:0] intValue];
                    int v2 = [[parts objectAtIndex:1] intValue];
                    // Default mapping: 1,0 = left/right; 0,1 = right/left; 0,0 = 3-finger
                    [twoFingerRightClickCheckbox setState:(v1 != 0 ? NSOnState : NSOffState)];
                    [threeFingerMiddleClickCheckbox setState:(v1 == 0 && v2 == 0 ? NSOnState : NSOffState)];
                }
            }
            // Disable while typing
            if (tpDwtStr) {
                [disableWhileTypingCheckbox setState:([tpDwtStr intValue] ? NSOnState : NSOffState)];
            }
            // Override with persisted user defaults (xinput may not persist across reboots)
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
                }
            }
            // Don't push here — let the user's toggle trigger applyAllSettings
            isRefreshing = NO;
            // Status message
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
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setPersistentDomain:domain forName:kMouseDomain];
    [defaults synchronize];
}

- (void)updateStatus:(NSString *)message
{
    [statusLabel setStringValue:(message ? message : @"")];
}

@end
