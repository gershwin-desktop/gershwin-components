/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCOptionControl.h"
#import "SCOption.h"
#import "SCScanner.h"
#import "SCFormView.h"
#import "SCImageAnalysis.h"
#import "SCMetrics.h"
#include <math.h>

static const CGFloat SCValueFieldWidth = 64;

/* Fixed-point values with a fine step need decimals, integers never do */
static NSString *
SCFormatNumber(SCOption *option, double v)
{
  if ([option type] == SCOptionTypeInt || fabs(v - round(v)) < 1e-9)
    {
      return [NSString stringWithFormat: @"%.0f", v];
    }
  if ([option step] > 0 && [option step] >= 0.1)
    {
      return [NSString stringWithFormat: @"%.1f", v];
    }
  return [NSString stringWithFormat: @"%.2f", v];
}

/*
 * Drivers name sources with abbreviations ("ADF", "ADF Duplex"); the menu
 * spells them out. Only the title changes, the driver still gets its value.
 */
static NSString *
SCReadableTitle(NSString *value)
{
  NSRegularExpression *adf = [NSRegularExpression
    regularExpressionWithPattern: @"\\bADF\\b" options: 0 error: NULL];
  NSString *rest;

  if ([adf numberOfMatchesInString: value options: 0
                             range: NSMakeRange(0, [value length])] == 0)
    {
      return value;
    }
  rest = [[adf stringByReplacingMatchesInString: value options: 0
                                          range: NSMakeRange(0, [value length])
                                   withTemplate: @""]
           stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
  return [rest length] > 0
    ? [NSString stringWithFormat: @"Document Feeder (%@)", rest]
    : @"Document Feeder";
}

static NSString *
SCFormatWithUnit(SCOption *option, id value)
{
  NSString *text;

  if (![value isKindOfClass: [NSNumber class]])
    {
      return SCReadableTitle([value description]);
    }
  text = SCFormatNumber(option, [value doubleValue]);
  if ([option unitString] != nil)
    {
      text = [NSString stringWithFormat: @"%@ %@", text, [option unitString]];
    }
  return text;
}

static NSTextField *
SCSmallLabel(NSString *text, NSRect frame)
{
  NSTextField *label = [[NSTextField alloc] initWithFrame: frame];

  [label setStringValue: text];
  [label setEditable: NO];
  [label setSelectable: NO];
  [label setBezeled: NO];
  [label setDrawsBackground: NO];
  return label;
}

/* Slider, value field and unit in one stretchable row */
@interface SCRangeView : NSView
@property (nonatomic, strong) NSSlider *slider;
@property (nonatomic, strong) NSTextField *field;
@property (nonatomic, strong) NSTextField *unit;
@end

@implementation SCRangeView

- (void) resizeSubviewsWithOldSize: (NSSize)oldSize
{
  CGFloat w = NSWidth([self bounds]);
  CGFloat unitW = _unit ? 32 : 0;
  CGFloat fieldX = w - unitW - SCValueFieldWidth;

  [_slider setFrame: NSMakeRect(0, 1, MAX(20, fieldX - METRICS_SPACE_8), 20)];
  [_field setFrame: NSMakeRect(fieldX, 0, SCValueFieldWidth,
                               METRICS_TEXT_INPUT_FIELD_HEIGHT)];
  [_unit setFrame: NSMakeRect(w - unitW + 4, 2, unitW - 4, 18)];
}

@end

/* Brightness, contrast and gamma sliders that produce a gamma table */
@interface SCGammaView : NSView
@property (nonatomic, strong) NSArray *sliders;
@property (nonatomic, strong) NSArray *labels;
@end

@implementation SCGammaView

- (void) resizeSubviewsWithOldSize: (NSSize)oldSize
{
  CGFloat w = NSWidth([self bounds]);
  NSUInteger i;

  for (i = 0; i < [_sliders count]; i++)
    {
      CGFloat y = NSHeight([self bounds]) - (i + 1) * 24;

      [[_labels objectAtIndex: i] setFrame: NSMakeRect(0, y + 2, 72, 18)];
      [[_sliders objectAtIndex: i] setFrame: NSMakeRect(76, y + 1, MAX(20, w - 76), 20)];
    }
}

@end

@interface SCOptionControl () <NSTextFieldDelegate>
@end

@implementation SCOptionControl
{
  SCScanner *_scanner;
  NSString *_name;
  NSString *_label;
  NSView *_view;
  NSMutableDictionary *_gammaSettings;
}

+ (instancetype) controlForOption: (SCOption *)option
                          scanner: (SCScanner *)scanner
                    gammaSettings: (NSMutableDictionary *)gammaSettings
{
  SCOptionControl *c;

  if (![option isActive] || [[option title] length] == 0)
    {
      return nil;
    }
  c = [self new];
  c->_scanner = scanner;
  c->_name = [option name];
  c->_label = [[option title] stringByAppendingString: @":"];
  c->_gammaSettings = gammaSettings;
  if (![c buildForOption: option])
    {
      return nil;
    }
  [c->_view setToolTip: [option help]];
  for (NSView *sub in [c->_view subviews])
    {
      [sub setToolTip: [option help]];
    }
  if (![option isSettable])
    {
      [c setEnabled: NO inView: c->_view];
    }
  return c;
}

- (void) setEnabled: (BOOL)enabled inView: (NSView *)view
{
  if ([view respondsToSelector: @selector(setEnabled:)])
    {
      [(NSControl *)view setEnabled: enabled];
    }
  for (NSView *sub in [view subviews])
    {
      [self setEnabled: enabled inView: sub];
    }
}

- (SCOption *) option
{
  return [_scanner optionNamed: _name];
}

- (void) setLabel: (NSString *)label
{
  _label = [label copy];
}

- (SCFormRow *) row
{
  return [SCFormRow rowWithLabel: _label control: _view];
}

- (BOOL) buildForOption: (SCOption *)option
{
  switch ([option type])
    {
      case SCOptionTypeBool:
        return [self buildCheckbox: option];
      case SCOptionTypeButton:
        return [self buildButton: option];
      case SCOptionTypeString:
        return ([option constraint] == SCOptionConstraintList)
          ? [self buildPopUp: option] : [self buildTextField: option];
      case SCOptionTypeInt:
      case SCOptionTypeFixed:
        if ([option count] > 1)
          {
            return [self buildGamma: option];
          }
        if ([option constraint] == SCOptionConstraintList)
          {
            return [self buildPopUp: option];
          }
        if ([option constraint] == SCOptionConstraintRange)
          {
            return [self buildRange: option];
          }
        return [self buildTextField: option];
      default:
        return NO;
    }
}

- (BOOL) buildCheckbox: (SCOption *)option
{
  NSButton *box = [[NSButton alloc] initWithFrame: NSMakeRect(0, 0, 100, 20)];

  [box setButtonType: NSSwitchButton];
  [box setTitle: [option title]];
  [box setState: [[option value] boolValue] ? NSOnState : NSOffState];
  [box setTarget: self];
  [box setAction: @selector(checkboxChanged:)];
  _label = @"";
  _view = box;
  return YES;
}

- (BOOL) buildButton: (SCOption *)option
{
  NSButton *button = [[NSButton alloc]
                       initWithFrame: NSMakeRect(0, 0, METRICS_BUTTON_MIN_WIDTH,
                                                 METRICS_BUTTON_HEIGHT)];

  [button setTitle: [option title]];
  [button setBezelStyle: NSRoundedBezelStyle];
  [button setTarget: self];
  [button setAction: @selector(buttonPressed:)];
  _label = @"";
  _view = button;
  return YES;
}

- (BOOL) buildPopUp: (SCOption *)option
{
  NSPopUpButton *popup = [[NSPopUpButton alloc]
                           initWithFrame: NSMakeRect(0, 0, 100, METRICS_TEXT_INPUT_FIELD_HEIGHT)
                               pullsDown: NO];

  for (id v in [option listValues])
    {
      /*
       * airscan's "*unset*" means "send nothing"; it is no choice to offer,
       * only shown while it is what the driver currently has
       */
      if ([v isEqual: @"*unset*"] && ![[option value] isEqual: v])
        {
          continue;
        }
      [popup addItemWithTitle: SCFormatWithUnit(option, v)];
      [[popup lastItem] setRepresentedObject: v];
    }
  [self showValue: option inPopUp: popup];
  [popup setTarget: self];
  [popup setAction: @selector(popupChanged:)];
  _view = popup;
  return [[option listValues] count] > 0;
}

- (void) showValue: (SCOption *)option inPopUp: (NSPopUpButton *)popup
{
  NSInteger i;

  for (i = 0; i < [popup numberOfItems]; i++)
    {
      id v = [[popup itemAtIndex: i] representedObject];

      if ([v isEqual: [option value]]
          || ([v isKindOfClass: [NSNumber class]]
              && fabs([v doubleValue] - [[option value] doubleValue]) < 1e-6))
        {
          [popup selectItemAtIndex: i];
          return;
        }
    }
}

- (BOOL) buildTextField: (SCOption *)option
{
  NSTextField *field = [[NSTextField alloc]
                         initWithFrame: NSMakeRect(0, 0, 100, METRICS_TEXT_INPUT_FIELD_HEIGHT)];

  [field setStringValue: [option value]
           ? ([[option value] isKindOfClass: [NSNumber class]]
                ? SCFormatNumber(option, [[option value] doubleValue])
                : [option value])
           : @""];
  [field setTarget: self];
  [field setAction: @selector(fieldChanged:)];
  [field setDelegate: self];
  _view = field;
  return YES;
}

- (BOOL) buildRange: (SCOption *)option
{
  SCRangeView *range = [[SCRangeView alloc]
                         initWithFrame: NSMakeRect(0, 0, 200, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
  NSSlider *slider = [[NSSlider alloc] initWithFrame: NSMakeRect(0, 0, 100, 20)];
  NSTextField *field = [[NSTextField alloc] initWithFrame: NSZeroRect];

  [slider setMinValue: [option minimum]];
  [slider setMaxValue: [option maximum]];
  /* The driver is only told on release; every intermediate value would reach the device */
  [slider setContinuous: NO];
  [slider setTarget: self];
  [slider setAction: @selector(sliderChanged:)];
  [field setAlignment: NSRightTextAlignment];
  [field setTarget: self];
  [field setAction: @selector(fieldChanged:)];
  [field setDelegate: self];
  [range setSlider: slider];
  [range setField: field];
  [range addSubview: slider];
  [range addSubview: field];
  if ([option unitString] != nil)
    {
      [range setUnit: SCSmallLabel([option unitString], NSZeroRect)];
      [range addSubview: [range unit]];
    }
  [range resizeSubviewsWithOldSize: NSZeroSize];
  _view = range;
  [self showRangeValue: option];
  return YES;
}

- (void) showRangeValue: (SCOption *)option
{
  SCRangeView *range = (SCRangeView *)_view;
  double v = [[option value] doubleValue];

  [[range slider] setDoubleValue: v];
  [[range field] setStringValue: SCFormatNumber(option, v)];
}

- (BOOL) buildGamma: (SCOption *)option
{
  SCGammaView *gamma;
  NSArray *titles = @[@"Brightness", @"Contrast", @"Gamma"];
  NSArray *settings = [_gammaSettings objectForKey: _name];
  NSMutableArray *sliders = [NSMutableArray array];
  NSMutableArray *labels = [NSMutableArray array];
  NSUInteger i;

  /* Only tables with a value range can be generated from a curve */
  if ([option constraint] != SCOptionConstraintRange)
    {
      return NO;
    }
  if (settings == nil)
    {
      settings = @[@0.0, @0.0, @1.0];
    }
  gamma = [[SCGammaView alloc] initWithFrame: NSMakeRect(0, 0, 200, 3 * 24)];
  for (i = 0; i < 3; i++)
    {
      NSSlider *s = [[NSSlider alloc] initWithFrame: NSZeroRect];
      NSTextField *l = SCSmallLabel([titles objectAtIndex: i], NSZeroRect);

      [s setMinValue: (i == 2) ? 0.3 : -50];
      [s setMaxValue: (i == 2) ? 3.0 : 50];
      [s setDoubleValue: [[settings objectAtIndex: i] doubleValue]];
      [s setContinuous: NO];
      [s setTarget: self];
      [s setAction: @selector(gammaChanged:)];
      [sliders addObject: s];
      [labels addObject: l];
      [gamma addSubview: l];
      [gamma addSubview: s];
    }
  [gamma setSliders: sliders];
  [gamma setLabels: labels];
  [gamma resizeSubviewsWithOldSize: NSZeroSize];
  _view = gamma;
  return YES;
}

- (void) apply: (id)value
{
  SCOption *option = [self option];
  NSError *error = nil;

  /*
   * A field still being edited is committed when the controls are disabled
   * for a scan; the driver must not get it in the middle of the scan
   */
  if (option == nil || [_scanner isScanning])
    {
      [self refresh];
      return;
    }
  if (![_scanner setValue: value forOption: option error: &error])
    {
      [_delegate optionControlDidFail: error];
    }
  [self refresh];
  [_delegate optionControlDidChangeValue];
}

/* After a change without reload the old views stay; show what the driver took */
- (void) refresh
{
  SCOption *option = [self option];

  if (option == nil || [_view superview] == nil)
    {
      return;
    }
  if ([_view isKindOfClass: [SCRangeView class]])
    {
      [self showRangeValue: option];
    }
  else if ([_view isKindOfClass: [NSPopUpButton class]])
    {
      [self showValue: option inPopUp: (NSPopUpButton *)_view];
    }
  else if ([_view isKindOfClass: [NSButton class]] && [option type] == SCOptionTypeBool)
    {
      [(NSButton *)_view setState: [[option value] boolValue] ? NSOnState : NSOffState];
    }
}

- (void) checkboxChanged: (NSButton *)sender
{
  [self apply: [NSNumber numberWithBool: [sender state] == NSOnState]];
}

- (void) buttonPressed: (id)sender
{
  NSError *error = nil;
  SCOption *option = [self option];

  if (option != nil && ![_scanner pressButton: option error: &error])
    {
      [_delegate optionControlDidFail: error];
    }
}

- (void) popupChanged: (NSPopUpButton *)sender
{
  [self apply: [[sender selectedItem] representedObject]];
}

- (void) sliderChanged: (NSSlider *)sender
{
  SCOption *option = [self option];

  [self apply: [NSNumber numberWithDouble:
                  [option constrainedNumber: [sender doubleValue]]]];
}

- (void) fieldChanged: (NSTextField *)sender
{
  SCOption *option = [self option];

  if ([option type] == SCOptionTypeString)
    {
      [self apply: [sender stringValue]];
      return;
    }
  [self apply: [NSNumber numberWithDouble:
                  [option constrainedNumber: [sender doubleValue]]]];
}

/* Leaving a field with Tab or a click must apply it too, not only Return */
- (void) controlTextDidEndEditing: (NSNotification *)n
{
  NSTextField *field = [n object];
  SCOption *option = [self option];
  id current = [option value];

  if ([current isKindOfClass: [NSNumber class]]
      && fabs([current doubleValue] - [field doubleValue]) < 1e-9)
    {
      return;
    }
  if ([current isKindOfClass: [NSString class]]
      && [current isEqualToString: [field stringValue]])
    {
      return;
    }
  [self fieldChanged: field];
}

- (void) gammaChanged: (id)sender
{
  SCGammaView *gamma = (SCGammaView *)_view;
  SCOption *option = [self option];
  NSArray *s = [gamma sliders];
  double b = [[s objectAtIndex: 0] doubleValue];
  double c = [[s objectAtIndex: 1] doubleValue];
  double g = [[s objectAtIndex: 2] doubleValue];

  [_gammaSettings setObject: @[@(b), @(c), @(g)] forKey: _name];
  [self apply: SCGammaTable([option count], [option maximum], b, c, g)];
}

@end
