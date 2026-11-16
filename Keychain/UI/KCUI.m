/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "KCUI.h"

const CGFloat KCFormLabelWidth = 90.0;

NSTextField *KCMakeLabel(NSString *text)
{
  NSTextField *label = [[NSTextField alloc] initWithFrame: NSZeroRect];

  [label setStringValue: text];
  [label setEditable: NO];
  [label setSelectable: NO];
  [label setBezeled: NO];
  [label setDrawsBackground: NO];
  [label setFont: METRICS_FONT_SYSTEM_REGULAR_13];
  return label;
}

NSTextField *KCMakeWrappingLabel(NSString *text)
{
  NSTextField *label = KCMakeLabel(text);
  [[label cell] setWraps: YES];
  [[label cell] setLineBreakMode: NSLineBreakByWordWrapping];
  return label;
}

NSTextField *KCMakeField(BOOL secure)
{
  NSTextField *field = secure
    ? [[NSSecureTextField alloc] initWithFrame: NSZeroRect]
    : [[NSTextField alloc] initWithFrame: NSZeroRect];
  [field setFont: METRICS_FONT_SYSTEM_REGULAR_13];
  return field;
}

NSButton *KCMakeButton(NSString *title, id target, SEL action)
{
  NSButton *button = [[NSButton alloc] initWithFrame: NSZeroRect];

  [button setTitle: title];
  [button setBezelStyle: NSRoundedBezelStyle];
  [button setFont: METRICS_FONT_SYSTEM_REGULAR_13];
  [button setTarget: target];
  [button setAction: action];
  return button;
}

NSButton *KCMakeCheckbox(NSString *title, id target, SEL action)
{
  NSButton *box = [[NSButton alloc] initWithFrame: NSZeroRect];

  [box setButtonType: NSSwitchButton];
  [box setTitle: title];
  [box setFont: METRICS_FONT_SYSTEM_REGULAR_13];
  [box setTarget: target];
  [box setAction: action];
  return box;
}

CGFloat KCButtonWidth(NSButton *button)
{
  NSDictionary *attrs = [NSDictionary dictionaryWithObject: [button font]
                                                    forKey: NSFontAttributeName];
  CGFloat w = ceil([[button title] sizeWithAttributes: attrs].width) + 2 * METRICS_SPACE_24;
  return MAX(w, METRICS_BUTTON_MIN_WIDTH);
}

CGFloat KCLayoutButtonRow(NSArray *buttons, CGFloat right, CGFloat y)
{
  NSEnumerator *e = [buttons objectEnumerator];
  NSButton *b;
  CGFloat x = right;

  while ((b = [e nextObject]) != nil)
    {
      CGFloat w = KCButtonWidth(b);
      x -= w;
      [b setFrame: NSMakeRect(x, y, w, METRICS_BUTTON_HEIGHT)];
      x -= METRICS_BUTTON_HORIZ_INTERSPACE;
    }
  return x + METRICS_BUTTON_HORIZ_INTERSPACE;
}

CGFloat KCWrappedHeight(NSTextField *label, CGFloat width)
{
  NSSize size = [[label cell] cellSizeForBounds:
    NSMakeRect(0, 0, width, 10000)];
  return ceil(size.height);
}

CGFloat KCFormHeight(NSUInteger rows)
{
  if (rows == 0)
    return 0;
  return rows * METRICS_TEXT_INPUT_FIELD_HEIGHT + (rows - 1) * METRICS_SPACE_8;
}

CGFloat KCLayoutFormRows(NSView *content, NSArray *rows, CGFloat top, CGFloat width)
{
  CGFloat fieldX = METRICS_CONTENT_SIDE_MARGIN + KCFormLabelWidth + METRICS_SPACE_8;
  CGFloat fieldW = width - fieldX - METRICS_CONTENT_SIDE_MARGIN;
  CGFloat y = top;
  NSUInteger i;

  for (i = 0; i + 1 < [rows count]; i += 2)
    {
      NSTextField *label = KCMakeLabel([rows objectAtIndex: i]);
      NSView *control = [rows objectAtIndex: i + 1];

      if (i > 0)
        y -= METRICS_SPACE_8;
      y -= METRICS_TEXT_INPUT_FIELD_HEIGHT;
      [label setAlignment: NSRightTextAlignment];
      /* Label text sits on the field's baseline, not its top edge. */
      [label setFrame: NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, y + 2, KCFormLabelWidth,
                                  METRICS_TEXT_INPUT_FIELD_HEIGHT - 4)];
      [control setFrame: NSMakeRect(fieldX, y, fieldW, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
      [content addSubview: label];
      [content addSubview: control];
    }
  return y;
}
