/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "EnergyController.h"
#import "AppearanceMetrics.h"
#import "CPUGovernorBackend.h"
#import "EnergyBackend.h"
#import <dispatch/dispatch.h>

static NSString *const kEnergyDomain = @"EnergyPreferences";

@interface EnergyController ()
- (NSString *)readGovernor;
- (NSArray *)availableGovernors;
- (BOOL)writeGovernor:(NSString *)gov;
- (BOOL)readPreventSleep;
- (BOOL)writePreventSleep:(BOOL)enable;
- (void)applyAllSettings;
- (void)updateStatus:(NSString *)message;
- (void)stopInhibitor;
- (void)applicationWillTerminate:(NSNotification *)notification;

/* Layout helpers (HIG group boxes and rows). */
- (NSBox *)groupBoxWithTitle:(NSString *)title frame:(NSRect)frame inView:(NSView *)parent;
- (NSTextField *)labelWithText:(NSString *)text frame:(NSRect)frame alignment:(NSTextAlignment)align;
- (void)addCheckbox:(NSButton *)checkbox toBox:(NSBox *)box y:(CGFloat)y width:(CGFloat)w;
- (NSTextField *)addInfoRowWithText:(NSString *)text toBox:(NSBox *)box y:(CGFloat)y width:(CGFloat)w;
- (void)addPopUpRowWithLabel:(NSString *)label
                      popup:(NSPopUpButton *)popup
                      toBox:(NSBox *)box
                          y:(CGFloat)y
                      width:(CGFloat)w;
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
@interface EnergyMainView : NSView
{
    EnergyController *_layoutOwner;
}
@end

@implementation EnergyMainView
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
- (void)setLayoutOwner:(EnergyController *)owner
{
    _layoutOwner = owner;
}
@end

@implementation EnergyController

- (id)init
{
    self = [super init];
    if (self) {
        isRefreshing = YES;
        hddSleepState = NO;
        wakeNetworkState = NO;
        powerFailState = NO;
        /* The host does not release its panes when it quits, so dealloc never
           runs and the sleep inhibitor would otherwise outlive the app. */
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(applicationWillTerminate:)
                   name:NSApplicationWillTerminateNotification
                 object:nil];
    }
    return self;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    (void)notification;
    [self stopInhibitor];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopInhibitor];
    [mainView release];
    [powerBox release];
    [displayBox release];
    [powerMgmtBox release];
    [sourceLabel release];
    [batteryPercentLabel release];
    [governorPopUp release];
    [brightnessSlider release];
    [brightnessLabel release];
    [blankPopUp release];
    [preventSleepCheckbox release];
    [hddSleepCheckbox release];
    [wakeNetworkCheckbox release];
    [powerFailCheckbox release];
    [statusLabel release];
    [super dealloc];
}

#pragma mark - UI

- (NSView *)createMainView
{
    if (mainView) {
        return mainView;
    }
    const CGFloat winW = 560, winH = 440;
    const CGFloat sideMargin = METRICS_CONTENT_SIDE_MARGIN;      /* 24 */
    const CGFloat topMargin = METRICS_CONTENT_TOP_MARGIN;        /* 15 */
    const CGFloat bottomMargin = METRICS_SPACE_12;               /* under status line */
    const CGFloat boxGap = METRICS_SPACE_8;                      /* between group boxes */
    const CGFloat rowH = METRICS_TEXT_INPUT_FIELD_HEIGHT;        /* 22 */
    const CGFloat rowGap = METRICS_SPACE_8;
    const CGFloat checkboxRowH = METRICS_RADIO_BUTTON_LINE_SPACING; /* 20 */
    const CGFloat boxTitleInset = 14.0;
    /* Group-box heights sized to their content (title inset + rows +
       16px inner margin top and bottom). */
    const CGFloat powerBoxH = 128;      /* source, battery, governor */
    const CGFloat displayBoxH = 98;     /* brightness slider, blank popup */
    const CGFloat powerMgmtBoxH = 126;  /* 4 checkboxes */

    mainView = [[EnergyMainView alloc] initWithFrame:NSMakeRect(0, 0, winW, winH)];
    [(EnergyMainView *)mainView setLayoutOwner:self];
    [mainView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    CGFloat contentW = winW - 2 * sideMargin;
    CGFloat boxW = contentW;

    CGFloat y = winH - topMargin;

    /* ---- Power group box ---- */
    powerBox = [self groupBoxWithTitle:@"Power"
                                frame:NSMakeRect(sideMargin, y - powerBoxH, boxW, powerBoxH)
                               inView:mainView];
    {
        CGFloat by = powerBoxH - boxTitleInset - METRICS_SPACE_16 - rowH;
        sourceLabel = [self addInfoRowWithText:@"Source: reading..."
                                         toBox:powerBox y:by width:boxW];

        by -= rowGap + rowH;
        batteryPercentLabel = [self addInfoRowWithText:@"Battery: --%"
                                                 toBox:powerBox y:by width:boxW];

        by -= rowGap + rowH;
        [self addPopUpRowWithLabel:@"Governor:"
                            popup:governorPopUp =
                            [[NSPopUpButton alloc] initWithFrame:NSZeroRect]
                            toBox:powerBox y:by width:boxW];
    }
    y -= powerBoxH + boxGap;

    /* ---- Display group box ---- */
    displayBox = [self groupBoxWithTitle:@"Display"
                                  frame:NSMakeRect(sideMargin, y - displayBoxH, boxW, displayBoxH)
                                 inView:mainView];
    {
        CGFloat by = displayBoxH - boxTitleInset - METRICS_SPACE_16 - rowH;
        [self addSliderRowWithLabel:@"Brightness:"
                             slider:brightnessSlider =
                             [[NSSlider alloc] initWithFrame:NSZeroRect]
                              value:brightnessLabel =
                             [[NSTextField alloc] initWithFrame:NSZeroRect]
                              toBox:displayBox y:by width:boxW];
        [brightnessSlider setMinValue:1];
        [brightnessSlider setMaxValue:100];
        [brightnessSlider setFloatValue:100];
        [brightnessSlider setNumberOfTickMarks:11];
        [brightnessSlider setAllowsTickMarkValuesOnly:NO];
        [brightnessSlider setContinuous:YES];
        [brightnessSlider setTarget:self];
        [brightnessSlider setAction:@selector(settingChanged:)];
        [brightnessLabel setStringValue:@"100%"];

        by -= rowGap + rowH;
        [self addPopUpRowWithLabel:@"Screen blanks:"
                            popup:blankPopUp =
                            [[NSPopUpButton alloc] initWithFrame:NSZeroRect]
                            toBox:displayBox y:by width:boxW];
        for (NSNumber *seconds in [EnergyBackend screenBlankChoices]) {
            [blankPopUp addItemWithTitle:[EnergyBackend titleForScreenBlankSeconds:[seconds intValue]]];
        }
    }
    y -= displayBoxH + boxGap;

    /* ---- Power Management group box ---- */
    powerMgmtBox = [self groupBoxWithTitle:@"Power Management"
                                    frame:NSMakeRect(sideMargin, y - powerMgmtBoxH, boxW, powerMgmtBoxH)
                                   inView:mainView];
    {
        CGFloat by = powerMgmtBoxH - boxTitleInset - METRICS_SPACE_16 - checkboxRowH;
        [self addCheckbox:preventSleepCheckbox =
                   [[NSButton alloc] initWithFrame:NSZeroRect]
                    toBox:powerMgmtBox y:by width:boxW];
        [preventSleepCheckbox setButtonType:NSSwitchButton];
        [preventSleepCheckbox setTitle:@"Prevent computer from sleeping when display is off"];
        by -= checkboxRowH;

        [self addCheckbox:hddSleepCheckbox =
                   [[NSButton alloc] initWithFrame:NSZeroRect]
                    toBox:powerMgmtBox y:by width:boxW];
        [hddSleepCheckbox setButtonType:NSSwitchButton];
        [hddSleepCheckbox setTitle:@"Put hard disks to sleep when possible"];
        by -= checkboxRowH;

        [self addCheckbox:wakeNetworkCheckbox =
                   [[NSButton alloc] initWithFrame:NSZeroRect]
                    toBox:powerMgmtBox y:by width:boxW];
        [wakeNetworkCheckbox setButtonType:NSSwitchButton];
        [wakeNetworkCheckbox setTitle:@"Wake for network access"];
        by -= checkboxRowH;

        [self addCheckbox:powerFailCheckbox =
                   [[NSButton alloc] initWithFrame:NSZeroRect]
                    toBox:powerMgmtBox y:by width:boxW];
        [powerFailCheckbox setButtonType:NSSwitchButton];
        [powerFailCheckbox setTitle:@"Start up automatically after a power failure"];
    }

    /* Status label at the bottom, bottom-anchored */
    statusLabel = [self labelWithText:@""
                                frame:NSMakeRect(sideMargin, bottomMargin,
                                                contentW, 18)
                              alignment:NSTextAlignmentLeft];
    [statusLabel setFont:[NSFont systemFontOfSize:10]];
    [statusLabel setAutoresizingMask:(NSViewWidthSizable | NSViewMaxYMargin)];
    [mainView addSubview:statusLabel];

    return mainView;
}

/* Re-lay out the group boxes for the given view width, keeping the
   left and right margins equal. Called whenever the host resizes the
   pane view. */
- (void)relayoutWithWidth:(CGFloat)width
{
    const CGFloat sideMargin = METRICS_CONTENT_SIDE_MARGIN;  /* 24 */
    NSRect f;

    if (powerBox) {
        f = [powerBox frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [powerBox setFrame:f];
    }
    if (displayBox) {
        f = [displayBox frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [displayBox setFrame:f];
    }
    if (powerMgmtBox) {
        f = [powerMgmtBox frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [powerMgmtBox setFrame:f];
    }
    if (statusLabel) {
        f = [statusLabel frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [statusLabel setFrame:f];
    }
}

/* Build a titled group box, top-anchored. Width is managed by
   relayoutWithWidth: so margins stay symmetric. Builders return retained
   objects so they can go straight into ivars that dealloc releases;
   callers that do not keep one release it themselves. */
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
   Width-flexible so it tracks the box. */
- (void)addCheckbox:(NSButton *)checkbox toBox:(NSBox *)box y:(CGFloat)y width:(CGFloat)w
{
    [checkbox setFrame:NSMakeRect(METRICS_SPACE_16, y, w - 2 * METRICS_SPACE_16, 18)];
    [checkbox setAutoresizingMask:NSViewWidthSizable];
    [box addSubview:checkbox];
}

/* A plain info row (source / battery status); returns the label. */
- (NSTextField *)addInfoRowWithText:(NSString *)text toBox:(NSBox *)box y:(CGFloat)y width:(CGFloat)w
{
    NSTextField *label = [self labelWithText:text
                                      frame:NSMakeRect(METRICS_SPACE_16, y + 1,
                                                      w - 2 * METRICS_SPACE_16, 20)
                                  alignment:NSTextAlignmentLeft];
    [label setFont:[NSFont systemFontOfSize:12]];
    [label setAutoresizingMask:NSViewWidthSizable];
    [box addSubview:label];
    return label;
}

/* A label + pop-up row: label on the left (right aligned), pop-up
   stretching to fill the rest of the row. */
- (void)addPopUpRowWithLabel:(NSString *)label
                      popup:(NSPopUpButton *)popup
                      toBox:(NSBox *)box
                          y:(CGFloat)y
                      width:(CGFloat)w
{
    const CGFloat pad = METRICS_SPACE_16;
    const CGFloat labelW = 110;
    const CGFloat gap = METRICS_SPACE_8;
    const CGFloat popupW = w - 2 * pad - labelW - gap;

    NSTextField *labelField = [self labelWithText:label
                                            frame:NSMakeRect(pad, y + 1, labelW, 20)
                                        alignment:NSTextAlignmentRight];
    [labelField setFont:[NSFont systemFontOfSize:11]];
    [labelField setAutoresizingMask:NSViewMaxXMargin];
    [box addSubview:labelField];
    [labelField release];

    [popup setFrame:NSMakeRect(pad + labelW + gap, y, popupW, 22)];
    [popup setAutoresizingMask:NSViewWidthSizable];
    [popup setTarget:self];
    [popup setAction:@selector(settingChanged:)];
    [box addSubview:popup];
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
    [value setAlignment:NSTextAlignmentRight];
    [box addSubview:value];
}

#pragma mark - Actions

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
    // -- CPU Governor --
    NSString *gov = [[governorPopUp selectedItem] title];
    if (![gov isEqualToString:[self readGovernor]]) {
        [self writeGovernor:gov];
    }

    // -- Brightness --
    int brightness = (int)[brightnessSlider intValue];
    [brightnessLabel setStringValue:[NSString stringWithFormat:@"%d%%", brightness]];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        [EnergyBackend setBrightnessPercent:brightness];
    });

    // -- Screen blank --
    NSInteger blankIndex = [blankPopUp indexOfSelectedItem];
    if (blankIndex >= 0) {
        [EnergyBackend setScreenBlankSeconds:
            [[[EnergyBackend screenBlankChoices] objectAtIndex:blankIndex] intValue]];
    }

    // -- Prevent sleep --
    BOOL newPrevent = ([preventSleepCheckbox state] == NSControlStateValueOn);
    if (newPrevent != preventSleepState) {
        [self writePreventSleep:newPrevent];
        preventSleepState = newPrevent;
    }

    // -- Hard disk sleep --
    BOOL newHdd = ([hddSleepCheckbox state] == NSControlStateValueOn);
    if (newHdd != hddSleepState) {
        hddSleepState = newHdd;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            [EnergyBackend setHddSleep:newHdd];
        });
    }

    // -- Wake for network --
    BOOL newWake = ([wakeNetworkCheckbox state] == NSControlStateValueOn);
    if (newWake != wakeNetworkState) {
        wakeNetworkState = newWake;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            [EnergyBackend setWakeNetwork:newWake];
        });
    }

    // -- Power failure restart --
    BOOL newPower = ([powerFailCheckbox state] == NSControlStateValueOn);
    if (newPower != powerFailState) {
        powerFailState = newPower;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            [EnergyBackend setPowerFail:newPower];
        });
    }

    // -- Persist --
    [self persistSettings];
    [self updateStatus:@"Applied"];
}

- (void)refreshFromSystem
{
    isRefreshing = YES;

    // -- Power source / battery --
    NSDictionary *batt = [EnergyBackend readBatteryInfo];
    NSString *source = [batt objectForKey:@"source"];
    NSString *status = [batt objectForKey:@"status"];

    if ([source isEqualToString:@"AC"]) {
        NSString *src = @"Source: AC Power";
        if ([status length] > 0) {
            src = [src stringByAppendingFormat:@" (%@)", status];
        }
        [sourceLabel setStringValue:src];
    } else if ([source isEqualToString:@"Battery"]) {
        [sourceLabel setStringValue:@"Source: Battery"];
    } else {
        [sourceLabel setStringValue:@"Source: Unknown"];
    }

    int battPct = [[batt objectForKey:@"percent"] intValue];
    if (battPct >= 0) {
        [batteryPercentLabel setStringValue:[NSString stringWithFormat:@"Battery: %d%%", battPct]];
    } else {
        [batteryPercentLabel setStringValue:@"Battery: N/A"];
    }

    // -- CPU Governor --
    [governorPopUp removeAllItems];
    NSArray *govs = [self availableGovernors];
    for (NSString *gov in govs) {
        if ([gov length] > 0) {
            [governorPopUp addItemWithTitle:gov];
        }
    }
    NSString *currentGov = [self readGovernor];
    if ([currentGov length] > 0) {
        [governorPopUp selectItemWithTitle:currentGov];
    }

    // -- Brightness --
    int pct = [EnergyBackend readBrightnessPercent];
    [brightnessSlider setIntValue:pct];
    [brightnessLabel setStringValue:[NSString stringWithFormat:@"%d%%", pct]];

    // -- Screen blank (read from xset) --
    [blankPopUp selectItemAtIndex:
        [EnergyBackend screenBlankChoiceIndexForSeconds:[EnergyBackend currentScreenBlankSeconds]]];

    // -- Power Management --
    preventSleepState = [self readPreventSleep];
    [preventSleepCheckbox setState:preventSleepState ? NSControlStateValueOn : NSControlStateValueOff];
    hddSleepState = NO;
    wakeNetworkState = NO;
    powerFailState = NO;
    [hddSleepCheckbox setState:NSControlStateValueOff];
    [wakeNetworkCheckbox setState:NSControlStateValueOff];
    [powerFailCheckbox setState:NSControlStateValueOff];

    // -- Override with persisted user defaults --
    {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSDictionary *persisted = [defaults persistentDomainForName:kEnergyDomain];
        if (persisted) {
            NSNumber *val;

            val = [persisted objectForKey:@"brightness"];
            if (val) {
                [brightnessSlider setIntValue:[val intValue]];
                [brightnessLabel setStringValue:[NSString stringWithFormat:@"%d%%", [val intValue]]];
            }
            val = [persisted objectForKey:@"screenBlank"];
            if (val) {
                [blankPopUp selectItemAtIndex:[val intValue]];
            }

            val = [persisted objectForKey:@"preventSleep"];
            if (val) {
                BOOL on = [val boolValue];
                if (on != preventSleepState) {
                    preventSleepState = on;
                    [self writePreventSleep:on];
                }
                [preventSleepCheckbox setState:on ? NSControlStateValueOn : NSControlStateValueOff];
            }
            val = [persisted objectForKey:@"hddSleep"];
            if (val) {
                hddSleepState = [val boolValue];
                [hddSleepCheckbox setState:hddSleepState ? NSControlStateValueOn : NSControlStateValueOff];
            }
            val = [persisted objectForKey:@"wakeNetwork"];
            if (val) {
                wakeNetworkState = [val boolValue];
                [wakeNetworkCheckbox setState:wakeNetworkState ? NSControlStateValueOn : NSControlStateValueOff];
            }
            val = [persisted objectForKey:@"powerFail"];
            if (val) {
                powerFailState = [val boolValue];
                [powerFailCheckbox setState:powerFailState ? NSControlStateValueOn : NSControlStateValueOff];
            }
        }
    }

    isRefreshing = NO;
    [self updateStatus:@"Ready"];
}

- (void)persistSettings
{
    NSMutableDictionary *domain = [NSMutableDictionary dictionary];
    [domain setObject:[[governorPopUp selectedItem] title] forKey:@"governor"];
    [domain setObject:[NSNumber numberWithInt:[brightnessSlider intValue]] forKey:@"brightness"];
    [domain setObject:[NSNumber numberWithInt:[blankPopUp indexOfSelectedItem]] forKey:@"screenBlank"];
    [domain setObject:[NSNumber numberWithBool:([preventSleepCheckbox state] == NSControlStateValueOn)] forKey:@"preventSleep"];
    [domain setObject:[NSNumber numberWithBool:([hddSleepCheckbox state] == NSControlStateValueOn)] forKey:@"hddSleep"];
    [domain setObject:[NSNumber numberWithBool:([wakeNetworkCheckbox state] == NSControlStateValueOn)] forKey:@"wakeNetwork"];
    [domain setObject:[NSNumber numberWithBool:([powerFailCheckbox state] == NSControlStateValueOn)] forKey:@"powerFail"];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setPersistentDomain:domain forName:kEnergyDomain];
    [defaults synchronize];
}

- (void)updateStatus:(NSString *)message
{
    [statusLabel setStringValue:(message ? message : @"")];
}

#pragma mark - Platform Helpers

/* The governor list/read/write logic lives in CPUGovernorBackend.m in this
 * directory, built as libCPUGovernorBackend (Libraries/CPUGovernorBackend)
 * and linked by both this pane and the Battery menu extra, so the two never
 * show a different list or use a different privilege path for the same
 * setting. */
- (NSString *)readGovernor
{
    return [CPUGovernorBackend currentGovernor];
}

- (NSArray *)availableGovernors
{
    return [CPUGovernorBackend availableGovernors];
}

- (BOOL)writeGovernor:(NSString *)gov
{
    return [CPUGovernorBackend setGovernor:gov];
}

#pragma mark - Power Management

- (BOOL)readPreventSleep
{
    return (inhibitTask != nil && [inhibitTask isRunning]);
}

- (BOOL)writePreventSleep:(BOOL)enable
{
#if defined(__linux__)
    if (enable) {
        if (inhibitTask && [inhibitTask isRunning]) return YES;
        [self stopInhibitor];
        inhibitTask = [[NSTask alloc] init];
        [inhibitTask setLaunchPath:@"/usr/bin/systemd-inhibit"];
        /* The lock lives as long as the inhibited command. cat blocks on a
           pipe whose only writer is this process (NSTask children close
           inherited descriptors), so it sees EOF and releases the lock even
           when the app crashes or is killed without a termination
           notification; the next launch then cannot stack a second one. */
        [inhibitTask setStandardInput:[NSPipe pipe]];
        [inhibitTask setArguments:[NSArray arrayWithObjects:
            @"--what=sleep",
            @"--who=EnergyPreferences",
            @"--why=User preference",
            @"cat", nil]];
        [inhibitTask launch];
    } else {
        [self stopInhibitor];
    }
    return YES;
#else
    return YES;
#endif
}

- (void)stopInhibitor
{
    if (inhibitTask == nil) {
        return;
    }
    if ([inhibitTask isRunning]) {
        [inhibitTask terminate];
    }
    [inhibitTask release];
    inhibitTask = nil;
}

#pragma mark - Polling

- (void)pollBattery
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSDictionary *batt = [EnergyBackend readBatteryInfo];
        NSString *source = [batt objectForKey:@"source"];
        int percent = [[batt objectForKey:@"percent"] intValue];
        NSString *status = [batt objectForKey:@"status"];

        dispatch_async(dispatch_get_main_queue(), ^{
            if ([source isEqualToString:@"AC"]) {
                NSString *src = @"Source: AC Power";
                if ([status length] > 0) {
                    src = [src stringByAppendingFormat:@" (%@)", status];
                }
                [sourceLabel setStringValue:src];
            } else if ([source isEqualToString:@"Battery"]) {
                [sourceLabel setStringValue:@"Source: Battery"];
            }

            if (percent >= 0) {
                [batteryPercentLabel setStringValue:[NSString stringWithFormat:@"Battery: %d%%", percent]];
            }
        });
    });
}

@end
