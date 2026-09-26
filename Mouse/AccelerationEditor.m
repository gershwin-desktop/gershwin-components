/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "AccelerationEditor.h"
#import "MousePaneControls.h"
#import "AppearanceMetrics.h"
#include <math.h>

/* Indexed like the profile pop-up. */
static NSString *const kProfiles[] = { @"system", @"flat", @"custom" };
static const NSUInteger kProfileCount = 3;

static const CGFloat kProfileLabelWidth = 96;
static const CGFloat kProfilePopUpWidth = 140;
static const CGFloat kColumnLabelWidth = 74;
static const CGFloat kColumnSliderWidth = 100;
static const CGFloat kColumnValueWidth = 60;
/* Start and End never meet, so the S-curve between them stays defined. */
static const double kMinimumRange = 0.02;

static NSUInteger ProfileIndex(NSString *profile)
{
    for (NSUInteger i = 0; i < kProfileCount; i++) {
        if ([kProfiles[i] isEqualToString:profile]) {
            return i;
        }
    }
    return 0;
}

@implementation AccelerationEditor
{
    NSString *_profile;
    AccelerationCurve _savedCurve;
    AccelerationCurve _pendingCurve;
    double _speedSetting;

    CurveView *_curveView;
    NSPopUpButton *_profilePopUp;
    NSButton *_applyButton;
    NSButton *_restoreButton;
    NSSlider *_precisionSlider;
    NSSlider *_startSlider;
    NSSlider *_endSlider;
    NSSlider *_fastSlider;
    NSTextField *_precisionValue;
    NSTextField *_startValue;
    NSTextField *_endValue;
    NSTextField *_fastValue;
}

@synthesize kind = _kind;
@synthesize delegate = _delegate;
@synthesize profile = _profile;

- (instancetype)initWithKind:(PointerDeviceKind)kind
{
    self = [super init];
    if (self) {
        _kind = kind;
        _profile = [@"system" copy];
        _savedCurve = AccelerationCurveDefaults(kind);
        _pendingCurve = _savedCurve;
    }
    return self;
}

- (void)dealloc
{
    [_profile release];
    [_curveView setDelegate:nil];
    [super dealloc];
}

+ (CGFloat)minimumHeight
{
    /* The profile row, then the four slider rows the curve sits beside. */
    return MousePaneRowHeight + METRICS_SPACE_8
        + 4 * MousePaneRowHeight + 3 * METRICS_SPACE_8 + METRICS_SPACE_16;
}

- (NSButton *)addButton:(NSString *)title frame:(NSRect)frame toView:(NSView *)view action:(SEL)action
{
    NSButton *button = [[[NSButton alloc] initWithFrame:frame] autorelease];
    [button setTitle:title];
    [button setBezelStyle:NSRoundedBezelStyle];
    [button setTarget:self];
    [button setAction:action];
    [button setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [view addSubview:button];
    return button;
}

- (NSSlider *)addColumnRow:(NSString *)label inView:(NSView *)view x:(CGFloat)x y:(CGFloat)y
                     value:(NSTextField **)value min:(double)min max:(double)max
{
    MousePaneRow row = { x, y, kColumnLabelWidth + kColumnSliderWidth + kColumnValueWidth
                                   + 2 * METRICS_SPACE_8,
                         kColumnLabelWidth, kColumnValueWidth, MousePaneRowKeepsRight };
    NSSlider *slider = MousePaneAddSliderRow(view, label, row, value, self, @selector(sliderChanged:));
    [slider setMinValue:min];
    [slider setMaxValue:max];
    return slider;
}

- (void)buildInView:(NSView *)view top:(CGFloat)top
{
    const CGFloat pad = METRICS_SPACE_16;
    const CGFloat gap = METRICS_SPACE_8;
    const CGFloat rowH = MousePaneRowHeight;
    const CGFloat btnW = METRICS_BUTTON_MIN_WIDTH;
    const CGFloat btnH = METRICS_BUTTON_HEIGHT;
    const CGFloat width = NSWidth([view frame]);
    const CGFloat columnW = kColumnLabelWidth + kColumnSliderWidth + kColumnValueWidth + 2 * gap;
    const CGFloat columnX = width - pad - columnW;

    CGFloat y = top - rowH;
    MousePaneRow profileRow = { pad, y, kProfileLabelWidth + gap + kProfilePopUpWidth,
                                kProfileLabelWidth, 0, MousePaneRowKeepsLeft };
    _profilePopUp = MousePaneAddPopUpRow(view, @"Acceleration:", profileRow,
                                         self, @selector(profileChanged:));
    [_profilePopUp addItemsWithTitles:@[@"System", @"Flat", @"Custom"]];

    _applyButton = [self addButton:@"Apply"
                             frame:NSMakeRect(width - pad - btnW, y + 1, btnW, btnH)
                            toView:view action:@selector(applyCurve:)];
    _restoreButton = [self addButton:@"Restore"
                               frame:NSMakeRect(width - pad - 2 * btnW - METRICS_BUTTON_HORIZ_INTERSPACE,
                                                y + 1, btnW, btnH)
                              toView:view action:@selector(restoreCurve:)];

    CGFloat areaTop = y - gap;
    _curveView = [[[CurveView alloc] initWithFrame:
        NSMakeRect(pad, pad, columnX - 2 * pad, areaTop - pad)] autorelease];
    [_curveView setDelegate:self];
    [_curveView setMaxSpeed:AccelerationCurveMaxSpeed(_kind)];
    [_curveView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [view addSubview:_curveView];

    double maxGain = AccelerationCurveMaxGain(_kind);
    y = areaTop - rowH;
    _precisionSlider = [self addColumnRow:@"Precision:" inView:view x:columnX y:y
                                    value:&_precisionValue min:0.01 max:maxGain];
    y -= rowH + gap;
    _startSlider = [self addColumnRow:@"Start:" inView:view x:columnX y:y
                                value:&_startValue min:0.0 max:1.0];
    y -= rowH + gap;
    _endSlider = [self addColumnRow:@"End:" inView:view x:columnX y:y
                              value:&_endValue min:0.0 max:1.0];
    y -= rowH + gap;
    _fastSlider = [self addColumnRow:@"Fast:" inView:view x:columnX y:y
                               value:&_fastValue min:0.01 max:maxGain];
    [self updateControls];
}

- (void)showDevice:(PointerDevice *)device storedCurve:(AccelerationCurve)curve
{
    _savedCurve = curve;
    _pendingCurve = curve;
    for (NSUInteger i = 0; i < kProfileCount; i++) {
        [[_profilePopUp itemAtIndex:i] setEnabled:[device offersAccelProfile:kProfiles[i]]];
    }
    NSString *active = [device activeAccelProfile];
    [_profile release];
    _profile = [(active ? active : @"system") copy];
    [self updateControls];
}

- (void)setSpeedSetting:(double)speed
{
    _speedSetting = speed;
    [self updateControls];
}

- (void)syncSliders:(AccelerationCurve)curve showsRange:(BOOL)showsRange
{
    double maxSpeed = AccelerationCurveMaxSpeed(_kind);
    [_precisionSlider setDoubleValue:curve.precision];
    [_precisionValue setStringValue:[NSString stringWithFormat:@"%.2fx", curve.precision]];
    [_startSlider setDoubleValue:curve.start];
    [_endSlider setDoubleValue:curve.end];
    if (showsRange) {
        [_startValue setStringValue:[NSString stringWithFormat:@"%.0f mm/s", curve.start * maxSpeed]];
        [_endValue setStringValue:[NSString stringWithFormat:@"%.0f mm/s", curve.end * maxSpeed]];
    } else {
        /* Flat accelerates nowhere, so there is no range to report. */
        [_startValue setStringValue:@"-"];
        [_endValue setStringValue:@"-"];
    }
    [_fastSlider setDoubleValue:curve.fast];
    [_fastValue setStringValue:[NSString stringWithFormat:@"%.2fx", curve.fast]];
}

- (void)updateControls
{
    BOOL isCustom = [_profile isEqualToString:@"custom"];
    BOOL edited = !AccelerationCurveEqualToCurve(_pendingCurve, _savedCurve);
    AccelerationCurve shown = _pendingCurve;
    NSArray *gains = nil;
    BOOL showsRange = YES;

    if ([_profile isEqualToString:@"system"]) {
        shown = AccelerationAdaptiveCurve(_kind, _speedSetting);
        gains = AccelerationAdaptiveGains(_kind, _speedSetting, 101);
    } else if ([_profile isEqualToString:@"flat"]) {
        double gain = AccelerationFlatGain(_kind, _speedSetting);
        shown.precision = gain;
        shown.start = 0.0;
        shown.end = 1.0;
        shown.fast = gain;
        showsRange = NO;
    }

    [_profilePopUp selectItemAtIndex:ProfileIndex(_profile)];
    /* Fast speed settings push the built-in curves above the editing range;
       the axis grows in half steps rather than clipping them. */
    [_curveView setMaximum:MAX(AccelerationCurveMaxGain(_kind),
                               ceil(MAX(shown.precision, shown.fast) * 2.0) / 2.0)];
    [_curveView setDisplayedGains:gains];
    [_curveView setShowsRange:showsRange];
    [_curveView setCurve:shown];
    [_curveView setCurveEnabled:isCustom];
    [self syncSliders:shown showsRange:showsRange];
    [_precisionSlider setEnabled:isCustom];
    [_startSlider setEnabled:isCustom];
    [_endSlider setEnabled:isCustom];
    [_fastSlider setEnabled:isCustom];
    [_applyButton setEnabled:(isCustom && edited)];
    [_restoreButton setEnabled:(isCustom && edited)];
}

- (BOOL)applyProfile:(NSString *)profile curve:(AccelerationCurve)curve
{
    if (![_delegate accelerationEditor:self applyProfile:profile curve:curve]) {
        return NO;
    }
    [_profile release];
    _profile = [profile copy];
    _savedCurve = curve;
    _pendingCurve = curve;
    [_delegate accelerationEditorDidChangeProfile:self];
    return YES;
}

- (void)profileChanged:(id)sender
{
    (void)sender;
    NSString *profile = kProfiles[[_profilePopUp indexOfSelectedItem]];
    /* Custom takes the curve on screen; a built-in profile drops unapplied
       edits so the editor never shows a curve the device does not have. */
    AccelerationCurve curve = [profile isEqualToString:@"custom"] ? _pendingCurve : _savedCurve;
    [self applyProfile:profile curve:curve];
    [self updateControls];
}

- (void)sliderChanged:(id)sender
{
    if (sender == _precisionSlider) {
        _pendingCurve.precision = [_precisionSlider doubleValue];
        _pendingCurve.fast = MAX(_pendingCurve.fast, _pendingCurve.precision);
    } else if (sender == _startSlider) {
        _pendingCurve.start = MIN([_startSlider doubleValue], _pendingCurve.end - kMinimumRange);
    } else if (sender == _endSlider) {
        _pendingCurve.end = MAX([_endSlider doubleValue], _pendingCurve.start + kMinimumRange);
    } else if (sender == _fastSlider) {
        _pendingCurve.fast = MAX([_fastSlider doubleValue], _pendingCurve.precision);
    }
    [self updateControls];
}

- (void)applyCurve:(id)sender
{
    (void)sender;
    [self applyProfile:@"custom" curve:_pendingCurve];
    [self updateControls];
}

- (void)restoreCurve:(id)sender
{
    (void)sender;
    _pendingCurve = _savedCurve;
    [self updateControls];
}

- (void)curveViewDidChange:(CurveView *)curveView
{
    _pendingCurve = [curveView curve];
    [self updateControls];
}

@end
