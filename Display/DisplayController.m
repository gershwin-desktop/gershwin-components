/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "DisplayController.h"
#import "DisplayView.h"
#import "X11DisplayManager.h"
#import "DisplayLayout.h"
#import "DisplayArrangement.h"
#import "AppearanceMetrics.h"
#import <math.h>

@class DisplayController;

/* The pane view. When the host window gives us a width (which is not the
   560px base we built at), re-lay out the group boxes so the left/right
   margins to the window edge stay symmetric. */
@interface DisplayMainView : NSView
{
    DisplayController *_layoutOwner;
}
@end

@implementation DisplayMainView
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
- (void)setLayoutOwner:(DisplayController *)owner
{
    _layoutOwner = owner;
}
@end

static NSInteger dialogIDCounter = 0;
static NSMutableDictionary *activeDialogsByID = nil;

@interface DisplayController ()
/* Layout helpers (HIG group boxes and rows). */
- (NSBox *)groupBoxWithTitle:(NSString *)title frame:(NSRect)frame inView:(NSView *)parent;
- (NSTextField *)labelWithText:(NSString *)text frame:(NSRect)frame alignment:(NSTextAlignment)align;
- (void)addCheckbox:(NSButton *)checkbox toBox:(NSBox *)box y:(CGFloat)y width:(CGFloat)w;
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

@implementation DisplayController

- (id)init
{
    self = [super init];
    if (self) {
        x11 = [[X11DisplayManager alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [layout release];
    [selectedOutputName release];
    [displayView release];
    [mainView release];
    [resolutionPopup release];
    [scaleSlider release];
    [scaleValueLabel release];
    [scaleFactorHintLabel release];
    [mirrorDisplaysCheckbox release];
    [x11 release];
    [super dealloc];
}

- (NSView *)createMainView
{
    if (mainView) {
        return mainView;
    }
    
    // Check if X11 RANDR is available before creating the view
    if (![x11 isAvailable]) {
        NSDebugLog(@"DisplayController: Cannot create main view - X11 not available");
        
        // Create a simple error view
        mainView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 320)];
        
        NSTextField *errorLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 140, 460, 40)];
        [errorLabel setStringValue:@"Display configuration is not available.\nThe X11 RANDR extension is required."];
        [errorLabel setBezeled:NO];
        [errorLabel setDrawsBackground:NO];
        [errorLabel setEditable:NO];
        [errorLabel setSelectable:NO];
        [errorLabel setFont:[NSFont systemFontOfSize:14]];
        [errorLabel setAlignment:NSCenterTextAlignment];
        [mainView addSubview:errorLabel];
        [errorLabel release];
        
        return mainView;
    }
    
    NSDebugLog(@"DisplayController: Creating main view with X11 RANDR available");
    
    const CGFloat winW = 560, winH = 440;
    const CGFloat sideMargin = METRICS_CONTENT_SIDE_MARGIN;      /* 24 */
    const CGFloat topMargin = METRICS_CONTENT_TOP_MARGIN;        /* 15 */
    const CGFloat bottomMargin = METRICS_SPACE_12;               /* under bottom controls */
    const CGFloat boxGap = METRICS_SPACE_8;                      /* between group boxes */
    const CGFloat rowH = METRICS_TEXT_INPUT_FIELD_HEIGHT;        /* 22 */
    const CGFloat checkboxRowH = METRICS_RADIO_BUTTON_LINE_SPACING; /* 20 */
    const CGFloat boxTitleInset = 14.0;
    const CGFloat arrangeBoxH = 230;      /* arrangement view */
    const CGFloat settingsBoxH = 126;     /* mirror, resolution, scale */

    mainView = [[DisplayMainView alloc] initWithFrame:NSMakeRect(0, 0, winW, winH)];
    [(DisplayMainView *)mainView setLayoutOwner:self];
    [mainView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    CGFloat contentW = winW - 2 * sideMargin;
    CGFloat boxW = contentW;

    CGFloat y = winH - topMargin;

    /* ---- Arrangement view directly on the pane (single item, no box) ---- */
    {
        /* No autoresizing mask: GNUstep's +5px contentView quirk would otherwise
           make this view track the inflated size and misalign its right edge
           with the box below. relayoutWithWidth: sets its width explicitly. */
        displayView = [[DisplayView alloc] initWithFrame:
            NSMakeRect(sideMargin, y - arrangeBoxH, boxW, arrangeBoxH)];
        [displayView setController:self];
        [mainView addSubview:displayView];
    }
    y -= arrangeBoxH + boxGap;

    /* ---- Display Settings group box ---- */
    settingsBox = [self groupBoxWithTitle:@"Display Settings"
                                   frame:NSMakeRect(sideMargin, y - settingsBoxH, boxW, settingsBoxH)
                                  inView:mainView];
    {
        CGFloat by = settingsBoxH - boxTitleInset - METRICS_SPACE_16 - checkboxRowH;
        [self addCheckbox:mirrorDisplaysCheckbox =
                   [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease]
                    toBox:settingsBox y:by width:boxW];
        [mirrorDisplaysCheckbox setButtonType:NSSwitchButton];
        [mirrorDisplaysCheckbox setTitle:@"Mirror Displays"];
        [mirrorDisplaysCheckbox setTarget:self];
        [mirrorDisplaysCheckbox setAction:@selector(mirrorDisplaysChanged:)];
        by -= METRICS_SPACE_8 + rowH;

        [self addPopUpRowWithLabel:@"Resolution:"
                            popup:resolutionPopup =
                            [[[NSPopUpButton alloc] initWithFrame:NSZeroRect] autorelease]
                            toBox:settingsBox y:by width:boxW];
        [resolutionPopup setTarget:self];
        [resolutionPopup setAction:@selector(resolutionChanged:)];

        by -= METRICS_SPACE_8 + rowH;
        [self addSliderRowWithLabel:@"Scale Factor:"
                             slider:scaleSlider =
                             [[[NSSlider alloc] initWithFrame:NSZeroRect] autorelease]
                              value:scaleValueLabel =
                             [[[NSTextField alloc] initWithFrame:NSZeroRect] autorelease]
                              toBox:settingsBox y:by width:boxW];
        [scaleSlider setMinValue:DisplayScaleFactorMinimum];
        [scaleSlider setMaxValue:DisplayScaleFactorMaximum];
        /* A tick every 0.2 (0.8 ... 3.0) stays readable at this width; the
         * action rounds to 0.1, so in-between values remain possible. */
        [scaleSlider setNumberOfTickMarks:
            (NSInteger)lround((DisplayScaleFactorMaximum - DisplayScaleFactorMinimum) / 0.2) + 1];
        [scaleSlider setAllowsTickMarkValuesOnly:NO];
        [scaleSlider setContinuous:YES];
        [scaleSlider setTarget:self];
        [scaleSlider setAction:@selector(scaleFactorChanged:)];
        [scaleValueLabel setStringValue:@"1.0x"];

        double currentScaleFactor = 1.0;
        NSDictionary *domain = [[NSUserDefaults standardUserDefaults] persistentDomainForName:NSGlobalDomain];
        NSNumber *storedFactor = [domain objectForKey:@"GSScaleFactor"];
        if (storedFactor) {
            currentScaleFactor = [storedFactor doubleValue];
        }
        currentScaleFactor = DisplayClampScaleFactor(currentScaleFactor);
        [scaleSlider setDoubleValue:currentScaleFactor];
        [scaleValueLabel setStringValue:[NSString stringWithFormat:@"%.1fx", currentScaleFactor]];
    }
    y -= settingsBoxH + boxGap;

    /* ---- Bottom hint (settings apply automatically) ---- */
    scaleFactorHintLabel = [self labelWithText:@"Changes will take effect for newly started applications"
                                         frame:NSMakeRect(sideMargin, bottomMargin,
                                                         contentW, 20)
                                      alignment:NSTextAlignmentLeft];
    [scaleFactorHintLabel setFont:[NSFont systemFontOfSize:11]];
    [scaleFactorHintLabel setTextColor:[NSColor grayColor]];
    [scaleFactorHintLabel setHidden:YES];
    [scaleFactorHintLabel setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    [mainView addSubview:scaleFactorHintLabel];

    // Do not call refreshDisplays: here - the DisplayPane's didSelect
    // will trigger it once the view is in the window hierarchy.
    // Calling it here races with didSelect and causes double async loads.

    return mainView;
}

/* Re-lay out the pane for the given width. Positions are computed
   bottom-up and explicitly (the arrangement view fills whatever vertical
   space remains), so nothing relies on autoresizing quirks. */
- (void)relayoutWithWidth:(CGFloat)width
{
    const CGFloat sideMargin = METRICS_CONTENT_SIDE_MARGIN;  /* 24 */
    const CGFloat topMargin = METRICS_CONTENT_TOP_MARGIN;    /* 15 */
    const CGFloat bottomMargin = METRICS_SPACE_12;
    const CGFloat boxGap = METRICS_SPACE_8;
    const CGFloat hintH = 20;
    const CGFloat settingsBoxH = 126;
    CGFloat height = [mainView bounds].size.height;
    NSRect f;

    if (scaleFactorHintLabel) {
        f = [scaleFactorHintLabel frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        f.origin.y = bottomMargin;
        f.size.height = hintH;
        [scaleFactorHintLabel setFrame:f];
    }

    if (settingsBox) {
        f = [settingsBox frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        f.origin.y = bottomMargin + hintH + boxGap;
        f.size.height = settingsBoxH;
        [settingsBox setFrame:f];
    }

    if (displayView) {
        CGFloat arrangeY = bottomMargin + hintH + boxGap + settingsBoxH + boxGap;
        CGFloat arrangeH = height - topMargin - arrangeY;
        if (arrangeH < 100) arrangeH = 100;
        f = [displayView frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        f.origin.y = arrangeY;
        f.size.height = arrangeH;
        [displayView setFrame:f];
    }
}

/* Build a titled group box, top-anchored. Width is managed by
   relayoutWithWidth: so margins stay symmetric. */
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

#pragma mark - Model

/* The title of the resolution pop-up item that switches an output off. */
static NSString * const DisplayOffItemTitle = @"Off";

- (DisplayLayout *)readLayoutProbing:(BOOL)probe
{
    DisplayLayout *current = [x11 currentLayoutProbingOutputs:probe];
    double factor = 1.0;
    NSNumber *stored = [[[NSUserDefaults standardUserDefaults]
        persistentDomainForName:NSGlobalDomain] objectForKey:@"GSScaleFactor"];
    if (stored) factor = [stored doubleValue];
    [current setScaleFactor:factor];
    return current;
}

- (void)probeDisplays
{
    [self updateFromLayout:[self readLayoutProbing:YES]];
}

- (void)refreshDisplays:(NSTimer *)timer
{
    [self updateFromLayout:[self readLayoutProbing:NO]];
}

- (void)updateFromLayout:(DisplayLayout *)current
{
    if (current == nil) {
        NSLog(@"DisplayController: the RandR configuration cannot be read");
        return;
    }

    if (selectedOutputName == nil || [current outputNamed:selectedOutputName] == nil) {
        [selectedOutputName release];
        selectedOutputName = [[[current primaryOutput] name] copy];
    }

    /* Rebuild the arrangement only on a real change, so the periodic
     * refresh does not throw away a rectangle the user is dragging. */
    if (![current isEqual:layout]) {
        [layout release];
        layout = [current retain];
        [displayView updateDisplayRects];
    }

    [mirrorDisplaysCheckbox setEnabled:[[layout outputs] count] > 1];
    [mirrorDisplaysCheckbox setState:[layout isMirrored] ? NSOnState : NSOffState];
    [self updateResolutionPopup];
}

- (DisplayLayout *)layout
{
    return layout;
}

- (NSString *)selectedOutputName
{
    return selectedOutputName;
}

- (void)selectOutput:(NSString *)name
{
    if (name == nil) return;
    [selectedOutputName release];
    selectedOutputName = [name copy];
    for (DisplayRectView *rectView in [displayView displayRects]) {
        [rectView setIsSelected:[[[rectView output] name] isEqualToString:name]];
        [rectView setNeedsDisplay:YES];
    }
    [self updateResolutionPopup];
}

- (void)updateResolutionPopup
{
    [resolutionPopup removeAllItems];
    DisplayOutput *o = [layout outputNamed:selectedOutputName];
    if (o == nil) return;

    /* "Off" switches the output off; an output that is off can be switched
     * on by picking a resolution.  The primary cannot go dark. */
    if ([[layout outputs] count] > 1 && ![o primary]) {
        [resolutionPopup addItemWithTitle:DisplayOffItemTitle];
    }
    for (NSString *res in [o resolutionStrings]) {
        [resolutionPopup addItemWithTitle:res];
    }
    if ([o enabled]) {
        [resolutionPopup selectItemWithTitle:
            [NSString stringWithFormat:@"%dx%d", [o modeWidth], [o modeHeight]]];
    } else {
        [resolutionPopup selectItemWithTitle:DisplayOffItemTitle];
    }
}

#pragma mark - Applying

- (void)showError:(NSString *)text
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"The display settings could not be changed"];
    [alert setInformativeText:text];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    [alert release];
}

/* Applies `wanted`.  If the server refuses, the previous layout is restored
 * and the error shown; the confirmation with its automatic revert only
 * appears when the change really took effect. */
- (BOOL)applyLayout:(DisplayLayout *)wanted confirm:(BOOL)confirm
{
    DisplayLayout *previous = [[layout retain] autorelease];
    NSError *error = nil;
    BOOL ok = [x11 applyLayout:wanted error:&error];
    if (!ok) {
        NSError *restoreError = nil;
        if (previous && ![x11 applyLayout:previous error:&restoreError]) {
            NSLog(@"DisplayController: restoring the previous layout failed: %@",
                  [restoreError localizedDescription]);
        }
    }
    [self refreshDisplays:nil];
    if (!ok) {
        [self showError:[error localizedDescription]];
        return NO;
    }
    if (confirm && previous) [self showConfirmationDialogWithPreviousLayout:previous];
    return YES;
}

- (void)resolutionChanged:(id)sender
{
    NSString *title = [resolutionPopup titleOfSelectedItem];
    DisplayOutput *o = [layout outputNamed:selectedOutputName];
    if (o == nil || title == nil) return;

    DisplayLayout *wanted;
    if ([title isEqualToString:DisplayOffItemTitle]) {
        if (![o enabled]) return;
        wanted = [layout layoutByDisablingOutput:[o name]];
    } else {
        NSString *currentRes = [NSString stringWithFormat:@"%dx%d", [o modeWidth], [o modeHeight]];
        if ([o enabled] && [title isEqualToString:currentRes]) return;
        wanted = [layout layoutBySettingResolution:title forOutput:[o name]];
    }
    if (wanted == nil) {
        [self updateResolutionPopup];
        [self showError:[NSString stringWithFormat:
            @"%@ cannot be set to %@.", [o name], title]];
        return;
    }
    [self applyLayout:wanted confirm:YES];
}

- (void)mirrorDisplaysChanged:(id)sender
{
    BOOL mirror = [mirrorDisplaysCheckbox state] == NSOnState;
    DisplayLayout *wanted = mirror ? [layout mirroredLayout] : [layout extendedLayout];
    if (wanted == nil) {
        [mirrorDisplaysCheckbox setState:mirror ? NSOffState : NSOnState];
        return;
    }
    [self applyLayout:wanted confirm:YES];
}

- (void)moveOutput:(NSString *)name toViewRect:(NSRect)viewRect
{
    DisplayViewMapping m = [displayView mapping];
    NSPoint origin = DisplayModelOriginForViewRect(viewRect, m);
    /* Edges that end up within a few points of each other in the view are
     * meant to line up. */
    CGFloat snap = 8.0 / m.scale;
    DisplayLayout *wanted = [layout layoutByMovingOutput:name toOrigin:origin snapDistance:snap];
    if (wanted == nil || [wanted isEqual:layout]) {
        [displayView updateDisplayRects];
        return;
    }
    [self applyLayout:wanted confirm:NO];
}

- (void)setPrimaryOutput:(NSString *)name
{
    DisplayLayout *wanted = [layout layoutBySettingPrimary:name];
    if (wanted == nil) return;
    [self applyLayout:wanted confirm:NO];
}

- (void)scaleFactorChanged:(id)sender
{
    double factor = DisplayClampScaleFactor([sender doubleValue]);
    [sender setDoubleValue:factor];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *domain = [NSMutableDictionary dictionaryWithDictionary:
        [defaults persistentDomainForName:NSGlobalDomain]];
    [domain setObject:[NSNumber numberWithDouble:factor] forKey:@"GSScaleFactor"];
    [defaults setPersistentDomain:domain forName:NSGlobalDomain];
    [defaults synchronize];
    [scaleValueLabel setStringValue:[NSString stringWithFormat:@"%.1fx", factor]];
    [scaleFactorHintLabel setHidden:NO];
}

#pragma mark - Confirmation with automatic revert

static const int DisplayRevertSeconds = 15;

- (void)showConfirmationDialogWithPreviousLayout:(DisplayLayout *)previous
{
    NSWindow *confirmWindow = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(100, 100, 400, 150)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [confirmWindow setTitle:@"Display Settings Changed"];
    [confirmWindow setLevel:NSFloatingWindowLevel];
    [confirmWindow setHidesOnDeactivate:NO];
    [confirmWindow setReleasedWhenClosed:NO];

    NSView *contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 150)];
    [confirmWindow setContentView:contentView];

    NSTextField *messageLabel = [self labelWithText:
        [NSString stringWithFormat:@"Keep these display settings?\n"
                                   @"They are reverted in %d seconds otherwise.",
                                   DisplayRevertSeconds]
                                             frame:NSMakeRect(20, 80, 360, 40)
                                         alignment:NSCenterTextAlignment];
    [messageLabel setFont:[NSFont systemFontOfSize:12]];
    [contentView addSubview:messageLabel];
    [messageLabel release];

    NSTextField *countdownLabel = [self labelWithText:
        [NSString stringWithFormat:@"%d", DisplayRevertSeconds]
                                               frame:NSMakeRect(20, 50, 360, 20)
                                           alignment:NSCenterTextAlignment];
    [countdownLabel setFont:[NSFont boldSystemFontOfSize:16]];
    [contentView addSubview:countdownLabel];

    NSButton *revertButton = [[NSButton alloc] initWithFrame:NSMakeRect(220, 20, 80, 25)];
    [revertButton setTitle:@"Revert"];
    [revertButton setKeyEquivalent:@"\e"];
    [contentView addSubview:revertButton];

    NSButton *keepButton = [[NSButton alloc] initWithFrame:NSMakeRect(310, 20, 70, 25)];
    [keepButton setTitle:@"Keep"];
    [keepButton setKeyEquivalent:@"\r"];
    [contentView addSubview:keepButton];

    if (!activeDialogsByID) activeDialogsByID = [[NSMutableDictionary alloc] init];
    NSInteger dialogID = ++dialogIDCounter;
    NSMutableDictionary *dialogData = [NSMutableDictionary dictionary];
    [dialogData setObject:confirmWindow forKey:@"window"];
    [dialogData setObject:previous forKey:@"previousLayout"];
    [dialogData setObject:countdownLabel forKey:@"countdownLabel"];
    [dialogData setObject:[NSNumber numberWithInt:DisplayRevertSeconds] forKey:@"countdown"];
    [activeDialogsByID setObject:dialogData forKey:[NSNumber numberWithInteger:dialogID]];

    [revertButton setTarget:self];
    [revertButton setAction:@selector(resolutionRevertClicked:)];
    [revertButton setTag:dialogID];
    [keepButton setTarget:self];
    [keepButton setAction:@selector(resolutionKeepClicked:)];
    [keepButton setTag:dialogID];

    /* The timer carries only the id, so it does not keep the dialog alive. */
    NSTimer *countdownTimer = [NSTimer timerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(resolutionCountdownTimer:)
                                                    userInfo:[NSNumber numberWithInteger:dialogID]
                                                     repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:countdownTimer forMode:NSDefaultRunLoopMode];
    [dialogData setObject:countdownTimer forKey:@"timer"];

    [confirmWindow center];
    [confirmWindow makeKeyAndOrderFront:nil];
    [confirmWindow orderFrontRegardless];

    [countdownLabel release];
    [revertButton release];
    [keepButton release];
    [contentView release];
    [confirmWindow release];
}

/* Ends dialog `dialogID`, restoring its previous layout when `revert`. */
- (void)finishDialog:(NSNumber *)dialogID revert:(BOOL)revert
{
    NSMutableDictionary *dialogData = [[[activeDialogsByID objectForKey:dialogID] retain] autorelease];
    if (dialogData == nil) return;
    [activeDialogsByID removeObjectForKey:dialogID];
    [[dialogData objectForKey:@"timer"] invalidate];
    [[dialogData objectForKey:@"window"] close];
    if (revert) {
        [self applyLayout:[dialogData objectForKey:@"previousLayout"] confirm:NO];
    }
}

- (void)resolutionCountdownTimer:(NSTimer *)timer
{
    NSNumber *dialogID = [timer userInfo];
    NSMutableDictionary *dialogData = [activeDialogsByID objectForKey:dialogID];
    if (dialogData == nil) {
        [timer invalidate];
        return;
    }
    int countdown = [[dialogData objectForKey:@"countdown"] intValue] - 1;
    [dialogData setObject:[NSNumber numberWithInt:countdown] forKey:@"countdown"];
    [[dialogData objectForKey:@"countdownLabel"] setStringValue:
        [NSString stringWithFormat:@"%d", countdown]];
    if (countdown <= 0) [self finishDialog:dialogID revert:YES];
}

- (void)resolutionRevertClicked:(id)sender
{
    [self finishDialog:[NSNumber numberWithInteger:[sender tag]] revert:YES];
}

- (void)resolutionKeepClicked:(id)sender
{
    [self finishDialog:[NSNumber numberWithInteger:[sender tag]] revert:NO];
}

@end
