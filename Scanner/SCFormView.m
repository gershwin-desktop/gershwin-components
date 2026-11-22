/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCFormView.h"
#import "SCMetrics.h"

@implementation SCFormRow

+ (instancetype) rowWithLabel: (NSString *)label control: (NSView *)control
{
  SCFormRow *row = [self new];

  [row setLabel: label];
  [row setControl: control];
  return row;
}

+ (instancetype) headingWithTitle: (NSString *)title
{
  SCFormRow *row = [self new];

  [row setLabel: title];
  [row setHeading: YES];
  return row;
}

@end

@implementation SCFormView
{
  NSMutableArray *_labels;
  BOOL _inLayout;
}

- (instancetype) initWithFrame: (NSRect)frame
{
  self = [super initWithFrame: frame];
  if (self)
    {
      _labelWidth = 110;
      _labels = [NSMutableArray array];
      [self setAutoresizingMask: NSViewWidthSizable];
    }
  return self;
}

- (BOOL) isFlipped
{
  return YES;
}

static NSTextField *
SCLabel(NSString *text, BOOL heading)
{
  NSTextField *label = [[NSTextField alloc] initWithFrame: NSZeroRect];

  [label setStringValue: text ? text : @""];
  [label setEditable: NO];
  [label setSelectable: NO];
  [label setBezeled: NO];
  [label setDrawsBackground: NO];
  [label setAlignment: heading ? NSLeftTextAlignment : NSRightTextAlignment];
  [label setFont: heading ? [NSFont boldSystemFontOfSize: 13]
                          : [NSFont systemFontOfSize: 13]];
  [[label cell] setLineBreakMode: NSLineBreakByTruncatingTail];
  return label;
}

- (void) setRows: (NSArray *)rows
{
  for (NSView *v in [[self subviews] copy])
    {
      [v removeFromSuperview];
    }
  [_labels removeAllObjects];
  _rows = [rows copy];
  for (SCFormRow *row in _rows)
    {
      NSTextField *label = SCLabel([row label], [row heading]);

      [_labels addObject: label];
      [self addSubview: label];
      if ([row control] != nil)
        {
          [self addSubview: [row control]];
        }
    }
  [self layoutRows];
}

- (void) layoutRows
{
  CGFloat width = NSWidth([self frame]) - 2 * _margin;
  CGFloat controlX = _margin + _labelWidth + METRICS_SPACE_8;
  CGFloat controlWidth = MAX(40, width + _margin - controlX);
  CGFloat y = _margin;
  NSUInteger i;

  _inLayout = YES;
  for (i = 0; i < [_rows count]; i++)
    {
      SCFormRow *row = [_rows objectAtIndex: i];
      NSTextField *label = [_labels objectAtIndex: i];
      NSView *control = [row control];
      CGFloat h = control ? NSHeight([control frame]) : 18;

      if ([row heading])
        {
          /* Extra air above a heading separates the groups */
          y += (i > 0) ? METRICS_SPACE_12 : 0;
          [label setFrame: NSMakeRect(_margin, y, width, 18)];
          y += 18 + METRICS_SPACE_8;
          continue;
        }
      /* Driver titles can be long; above the control they stay readable */
      if ([[label cell] cellSize].width > _labelWidth)
        {
          [label setAlignment: NSLeftTextAlignment];
          [label setFrame: NSMakeRect(_margin, y, width, 18)];
          y += 18 + 2;
        }
      else
        {
          [label setAlignment: NSRightTextAlignment];
          /* Labels line up with the first line of taller controls */
          [label setFrame: NSMakeRect(_margin, y + 2, _labelWidth, 18)];
        }
      h = MAX(h, METRICS_TEXT_INPUT_FIELD_HEIGHT);
      if (control != nil)
        {
          NSRect f = [control frame];

          f.origin = NSMakePoint(controlX, y + (h - NSHeight(f)) / 2);
          if (NSHeight(f) > METRICS_TEXT_INPUT_FIELD_HEIGHT)
            {
              f.origin.y = y;
            }
          f.size.width = controlWidth;
          [control setFrame: f];
        }
      y += h + METRICS_SPACE_8;
    }
  if ([_rows count] > 0)
    {
      y -= METRICS_SPACE_8;
    }
  [self setFrameSize: NSMakeSize(width + 2 * _margin, y + _margin)];
  _inLayout = NO;
}

- (void) resizeWithOldSuperviewSize: (NSSize)oldSize
{
  [super resizeWithOldSuperviewSize: oldSize];
  if (!_inLayout)
    {
      [self layoutRows];
    }
}

@end
