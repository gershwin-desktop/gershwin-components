/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "PointerSection.h"
#import "MouseBackend.h"
#import "MousePreferences.h"
#import "MousePaneControls.h"
#import "AppearanceMetrics.h"

static const CGFloat kRowLabelWidth = 96;
static const CGFloat kRowValueWidth = 40;

@implementation PointerSection
{
    MouseBackend *_backend;
    NSView *_view;
    AccelerationEditor *_editor;
    NSArray *_devices;
    PointerDevice *_device;

    NSPopUpButton *_devicePopUp;
    NSSlider *_speedSlider;
    NSTextField *_speedValue;
    NSSlider *_scrollSlider;
    NSTextField *_scrollValue;
    NSButton *_leftHandedCheckbox;
    NSButton *_naturalScrollingCheckbox;
    NSButton *_tapCheckbox;
    NSButton *_tapMapCheckbox;
    NSButton *_disableWhileTypingCheckbox;
}

@synthesize kind = _kind;
@synthesize delegate = _delegate;

- (instancetype)initWithKind:(PointerDeviceKind)kind backend:(MouseBackend *)backend
{
    self = [super init];
    if (self) {
        _kind = kind;
        _backend = [backend retain];
        _devices = [[NSArray alloc] init];
        /* libinput takes a trackpoint's curve in units it has already
           scaled by the trackpoint's own multiplier, so a curve in mm/s
           would not mean what the graph says. */
        if (kind != PointerDeviceKindTrackpoint) {
            _editor = [[AccelerationEditor alloc] initWithKind:kind];
            [_editor setDelegate:self];
        }
    }
    return self;
}

- (void)dealloc
{
    [_editor setDelegate:nil];
    [_editor release];
    [_view release];
    [_devices release];
    [_device release];
    [_backend release];
    [super dealloc];
}

- (NSString *)title
{
    switch (_kind) {
    case PointerDeviceKindTouchpad:
        return @"Trackpad";
    case PointerDeviceKindTrackpoint:
        return @"TrackPoint";
    default:
        return @"Mouse";
    }
}

- (NSString *)key:(NSString *)setting
{
    return [MousePreferences key:setting forKind:_kind];
}

/* libinput scales two-finger, edge and button scrolling by a distance; a
   mouse wheel scrolls in detents it does not scale. */
- (BOOL)hasScrollSpeed
{
    return _kind != PointerDeviceKindMouse;
}

#pragma mark - Building

- (NSView *)viewWithSize:(NSSize)size
{
    if (_view != nil) {
        return _view;
    }
    const CGFloat pad = METRICS_SPACE_16;
    const CGFloat gap = METRICS_SPACE_8;
    const CGFloat rowH = MousePaneRowHeight;
    const CGFloat columnGap = METRICS_SPACE_16;
    const CGFloat columnW = floor((size.width - 2 * pad - columnGap) / 2);
    const CGFloat rightX = pad + columnW + columnGap;
    const CGFloat top = size.height - pad;

    _view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    [_view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    /* Left column: the device and the sliders. */
    CGFloat y = top - rowH;
    MousePaneRow row = { pad, y, columnW, kRowLabelWidth, 0, MousePaneRowKeepsLeft };
    _devicePopUp = MousePaneAddPopUpRow(_view, @"Device:", row, self, @selector(deviceChanged:));

    row.y = y -= rowH + gap;
    row.valueWidth = kRowValueWidth;
    _speedSlider = MousePaneAddSliderRow(_view, @"Tracking speed:", row, &_speedValue,
                                         self, @selector(speedChanged:));
    [_speedSlider setMinValue:-1.0];
    [_speedSlider setMaxValue:1.0];
    [_speedSlider setNumberOfTickMarks:11];

    if ([self hasScrollSpeed]) {
        row.y = y -= rowH + gap;
        _scrollSlider = MousePaneAddSliderRow(_view, @"Scrolling speed:", row, &_scrollValue,
                                              self, @selector(scrollSpeedChanged:));
        [_scrollSlider setMinValue:[MouseBackend minimumScrollSpeed]];
        [_scrollSlider setMaxValue:[MouseBackend maximumScrollSpeed]];
    }
    CGFloat leftBottom = y;

    /* Right column: switches. */
    const CGFloat boxH = MousePaneCheckboxHeight;
    y = top - boxH;
    NSRect f = NSMakeRect(rightX, y, columnW, boxH);
    _leftHandedCheckbox = MousePaneAddCheckbox(_view, @"Swap left and right buttons", f,
                                               self, @selector(leftHandedChanged:));
    f.origin.y = y -= MousePaneCheckboxStep;
    _naturalScrollingCheckbox = MousePaneAddCheckbox(_view, @"Reverse scrolling direction", f,
                                                     self, @selector(naturalScrollingChanged:));
    if (_kind == PointerDeviceKindTouchpad) {
        f.origin.y = y -= MousePaneCheckboxStep;
        _tapCheckbox = MousePaneAddCheckbox(_view, @"Tap to click", f,
                                            self, @selector(tapChanged:));
        /* libinput maps two-finger taps to the right button exactly when it
           maps three-finger taps to the middle one; there is no switch for
           either alone. */
        f.origin.y = y -= MousePaneCheckboxStep;
        _tapMapCheckbox = MousePaneAddCheckbox(_view, @"Two-finger tap = right, three = middle", f,
                                               self, @selector(tapMapChanged:));
        f.origin.y = y -= MousePaneCheckboxStep;
        _disableWhileTypingCheckbox = MousePaneAddCheckbox(_view, @"Disable while typing", f,
                                                           self, @selector(disableWhileTypingChanged:));
    }

    [_editor buildInView:_view top:MIN(leftBottom, y) - METRICS_SPACE_12];
    [self showDevice:nil preferences:@{}];
    return _view;
}

#pragma mark - Showing values

static BOOL IsOn(NSString *value)
{
    return [value intValue] != 0;
}

- (void)showDevices:(NSArray *)devices preferences:(NSDictionary *)domain
{
    NSString *previous = [[[_device name] retain] autorelease];
    [_devices release];
    _devices = [devices copy];

    [_devicePopUp removeAllItems];
    PointerDevice *shown = [_devices firstObject];
    for (PointerDevice *d in _devices) {
        /* Two devices of one class can share a name (a receiver with two
           pointers); the pop-up still needs distinct titles. */
        NSString *title = [d name];
        if ([_devicePopUp itemWithTitle:title] != nil) {
            title = [NSString stringWithFormat:@"%@ (%@)", [d name], [d deviceID]];
        }
        [_devicePopUp addItemWithTitle:title];
        if ([[d name] isEqualToString:previous]) {
            shown = d;
        }
    }
    [_devicePopUp setEnabled:([_devices count] > 1)];
    if (shown != nil) {
        [_devicePopUp selectItemAtIndex:[_devices indexOfObject:shown]];
    }
    [self showDevice:shown preferences:domain];
}

- (void)showDevice:(PointerDevice *)device preferences:(NSDictionary *)domain
{
    [_device release];
    _device = [device retain];

    float speed = [[device libinputValue:@"Accel Speed"] floatValue];
    [_speedSlider setFloatValue:speed];
    [_speedValue setStringValue:[NSString stringWithFormat:@"%.2f", speed]];

    NSString *distance = [device libinputValue:@"Scrolling Pixel Distance"];
    [_scrollSlider setEnabled:(distance != nil)];
    double scroll = distance ? [MouseBackend scrollSpeedForPixelDistance:[distance intValue]] : 1.0;
    [_scrollSlider setDoubleValue:scroll];
    [_scrollValue setStringValue:(distance ? [NSString stringWithFormat:@"%.2fx", scroll] : @"-")];

    [_leftHandedCheckbox setState:IsOn([device libinputValue:@"Left Handed Enabled"])];
    [_naturalScrollingCheckbox setState:IsOn([device libinputValue:@"Natural Scrolling Enabled"])];
    [_tapCheckbox setState:IsOn([device libinputValue:@"Tapping Enabled"])];
    [_tapMapCheckbox setState:IsOn([device libinputValue:@"Tapping Button Mapping Enabled"])];
    [_disableWhileTypingCheckbox setState:IsOn([device libinputValue:@"Disable While Typing Enabled"])];

    AccelerationCurve curve;
    if (![MousePreferences curve:&curve forKind:_kind inDomain:domain]) {
        curve = AccelerationCurveDefaults(_kind);
    }
    [_editor showDevice:device storedCurve:curve];
    [_editor setSpeedSetting:speed];
    [self updateSpeedEnabled];
}

/* libinput ignores the speed setting while the custom profile is on. */
- (void)updateSpeedEnabled
{
    [_speedSlider setEnabled:(_device != nil && ![[_editor profile] isEqualToString:@"custom"])];
}

#pragma mark - Actions

/* Stores the value only when the devices took it, so what is stored and
   re-applied at login is what the user saw working. */
- (void)applied:(BOOL)ok value:(id)value setting:(NSString *)setting what:(NSString *)what
{
    if (ok) {
        [MousePreferences storeValues:@{[self key:setting] : value}];
    } else {
        [_delegate pointerSection:self reportFailure:
            [NSString stringWithFormat:@"Could not change the %@ of the %@", what,
                                       [[self title] lowercaseString]]];
    }
}

- (void)deviceChanged:(id)sender
{
    NSInteger index = [sender indexOfSelectedItem];
    if (index >= 0 && (NSUInteger)index < [_devices count]) {
        [self showDevice:[_devices objectAtIndex:index] preferences:[MousePreferences currentDomain]];
    }
}

- (void)speedChanged:(id)sender
{
    float speed = [sender floatValue];
    [_speedValue setStringValue:[NSString stringWithFormat:@"%.2f", speed]];
    [_editor setSpeedSetting:speed];
    [self applied:[_backend applySpeed:speed toKind:_kind]
            value:[NSNumber numberWithFloat:speed] setting:MousePreferencesSpeed what:@"speed"];
}

- (void)scrollSpeedChanged:(id)sender
{
    double speed = [sender doubleValue];
    [_scrollValue setStringValue:[NSString stringWithFormat:@"%.2fx", speed]];
    [self applied:[_backend applyScrollSpeed:speed toKind:_kind]
            value:[NSNumber numberWithDouble:speed] setting:MousePreferencesScrollSpeed
             what:@"scrolling speed"];
}

- (void)leftHandedChanged:(id)sender
{
    BOOL on = [sender state] == NSOnState;
    [self applied:[_backend applyLeftHanded:on toKind:_kind]
            value:[NSNumber numberWithBool:on] setting:MousePreferencesLeftHanded what:@"buttons"];
}

- (void)naturalScrollingChanged:(id)sender
{
    BOOL on = [sender state] == NSOnState;
    [self applied:[_backend applyNaturalScrolling:on toKind:_kind]
            value:[NSNumber numberWithBool:on] setting:MousePreferencesNaturalScrolling
             what:@"scrolling direction"];
}

/* The touchpad-only switches keep the keys they always had. */
- (void)storeTouchpad:(BOOL)ok values:(NSDictionary *)values what:(NSString *)what
{
    if (!ok) {
        [_delegate pointerSection:self reportFailure:
            [NSString stringWithFormat:@"Could not change %@", what]];
        return;
    }
    [MousePreferences storeValues:values];
}

- (void)tapChanged:(id)sender
{
    BOOL on = [sender state] == NSOnState;
    [self storeTouchpad:[_backend applyTapToClick:on]
                 values:@{@"tapToClick" : [NSNumber numberWithBool:on]} what:@"tap to click"];
}

- (void)tapMapChanged:(id)sender
{
    BOOL on = [sender state] == NSOnState;
    NSNumber *value = [NSNumber numberWithBool:on];
    [self storeTouchpad:[_backend applyTwoFingerRightClick:on threeFingerMiddleClick:on]
                 values:@{@"twoFingerRightClick" : value, @"threeFingerMiddleClick" : value}
                   what:@"the tap buttons"];
}

- (void)disableWhileTypingChanged:(id)sender
{
    BOOL on = [sender state] == NSOnState;
    [self storeTouchpad:[_backend applyDisableWhileTyping:on]
                 values:@{@"disableWhileTyping" : [NSNumber numberWithBool:on]}
                   what:@"disable while typing"];
}

#pragma mark - AccelerationEditorDelegate

- (BOOL)accelerationEditor:(AccelerationEditor *)editor
              applyProfile:(NSString *)profile
                     curve:(AccelerationCurve)curve
{
    (void)editor;
    BOOL ok = [_backend applyAccelProfile:profile curve:curve toKind:_kind];
    if (ok) {
        NSArray *values = @[profile,
                            [NSNumber numberWithDouble:curve.precision],
                            [NSNumber numberWithDouble:curve.start],
                            [NSNumber numberWithDouble:curve.end],
                            [NSNumber numberWithDouble:curve.fast]];
        [MousePreferences storeValues:[NSDictionary dictionaryWithObjects:values
            forKeys:[MousePreferences curveKeysForKind:_kind]]];
    } else {
        [_delegate pointerSection:self reportFailure:
            [NSString stringWithFormat:@"Could not change the %@ acceleration",
                                       [[self title] lowercaseString]]];
    }
    return ok;
}

- (void)accelerationEditorDidChangeProfile:(AccelerationEditor *)editor
{
    (void)editor;
    [self updateSpeedEnabled];
}

@end
