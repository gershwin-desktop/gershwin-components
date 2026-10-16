/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "TDTaskTitleCell.h"
#import "TDTexture.h"
#import "TDTask.h"

@implementation TDTaskTitleCell

- (void)drawWithFrame: (NSRect)cellFrame inView: (NSView *)controlView
{
  TDTask *task = [self objectValue];
  NSFont *font = [NSFont systemFontOfSize: 13.0];
  NSColor *textColor;
  NSRect titleRect = cellFrame;
  NSRect dateRect = NSZeroRect;

  if (![task isKindOfClass: [TDTask class]])
    {
      return;
    }

  textColor = [task isDone]
    ? [NSColor colorWithCalibratedWhite: 0.35 alpha: 1.0]
    : [NSColor colorWithCalibratedRed: 0.20 green: 0.10 blue: 0.02 alpha: 1.0];

  if ([task dueDate] != nil)
    {
      NSDictionary *dateAttrs = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSFont systemFontOfSize: 11.0], NSFontAttributeName, nil];
      NSSize dateSize = [[task dueDate] sizeWithAttributes: dateAttrs];

      dateRect = NSMakeRect(NSMaxX(cellFrame) - dateSize.width - 4.0,
                             cellFrame.origin.y, dateSize.width + 4.0, cellFrame.size.height);
      titleRect.size.width -= (dateSize.width + 12.0);
    }

  [TDTexture drawEmbossedString: [task title]
                          inRect: NSInsetRect(titleRect, 2.0, 0.0)
                            font: font
                           color: textColor
                       alignment: NSLeftTextAlignment];

  if ([task isDone])
    {
      NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys: font, NSFontAttributeName, nil];
      NSSize titleSize = [[task title] sizeWithAttributes: attrs];
      CGFloat midY = cellFrame.origin.y + cellFrame.size.height / 2.0;

      [[NSColor colorWithCalibratedWhite: 0.35 alpha: 0.8] set];
      [NSBezierPath strokeLineFromPoint: NSMakePoint(titleRect.origin.x + 2.0, midY)
                                 toPoint: NSMakePoint(titleRect.origin.x + 2.0 + titleSize.width, midY)];
    }

  if ([task dueDate] != nil)
    {
      NSDictionary *dateAttrs = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSFont systemFontOfSize: 11.0], NSFontAttributeName,
        [NSColor colorWithCalibratedRed: 0.45 green: 0.30 blue: 0.15 alpha: 1.0], NSForegroundColorAttributeName,
        nil];
      NSPoint p = NSMakePoint(dateRect.origin.x, cellFrame.origin.y + (cellFrame.size.height - 13.0) / 2.0);

      [[task dueDate] drawAtPoint: p withAttributes: dateAttrs];
    }

  if ([task notes] != nil && [[task notes] length] > 0)
    {
      NSRect dot = NSMakeRect(NSMaxX(titleRect) - 6.0, cellFrame.origin.y + cellFrame.size.height / 2.0 - 2.0, 4.0, 4.0);

      [[NSColor colorWithCalibratedRed: 0.45 green: 0.30 blue: 0.15 alpha: 0.7] set];
      [[NSBezierPath bezierPathWithOvalInRect: dot] fill];
    }
}

@end
