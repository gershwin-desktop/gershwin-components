/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCPasswordPanel.h"
#import "SCMetrics.h"

@implementation SCPasswordPanel
{
  NSPanel *_panel;
  NSTextField *_user;
  NSSecureTextField *_password;
}

static NSTextField *
SCPanelLabel(NSString *text, NSRect frame, NSTextAlignment alignment)
{
  NSTextField *label = [[NSTextField alloc] initWithFrame: frame];

  [label setStringValue: text];
  [label setEditable: NO];
  [label setSelectable: NO];
  [label setBezeled: NO];
  [label setDrawsBackground: NO];
  [label setAlignment: alignment];
  return label;
}

- (NSButton *) buttonWithTitle: (NSString *)title x: (CGFloat)x tag: (NSInteger)tag
{
  NSButton *b = [[NSButton alloc]
                  initWithFrame: NSMakeRect(x, METRICS_CONTENT_BOTTOM_MARGIN,
                                            METRICS_BUTTON_MIN_WIDTH,
                                            METRICS_BUTTON_HEIGHT)];

  [b setTitle: title];
  [b setBezelStyle: NSRoundedBezelStyle];
  [b setTag: tag];
  [b setTarget: self];
  [b setAction: @selector(finish:)];
  [[_panel contentView] addSubview: b];
  return b;
}

- (instancetype) initWithResource: (NSString *)resource
{
  self = [super init];
  if (self)
    {
      CGFloat w = 420, side = METRICS_CONTENT_SIDE_MARGIN;
      CGFloat labelW = 90, fieldX = side + labelW + METRICS_SPACE_8;
      CGFloat fieldW = w - fieldX - side;
      CGFloat y = METRICS_CONTENT_BOTTOM_MARGIN + METRICS_BUTTON_HEIGHT
        + METRICS_SPACE_20;
      CGFloat h = y + 2 * (METRICS_TEXT_INPUT_FIELD_HEIGHT + METRICS_SPACE_8)
        + 40 + METRICS_CONTENT_TOP_MARGIN;
      NSView *content;
      NSButton *ok;

      _panel = [[NSPanel alloc] initWithContentRect: NSMakeRect(0, 0, w, h)
                                          styleMask: NSTitledWindowMask
                                            backing: NSBackingStoreBuffered
                                              defer: YES];
      [_panel setTitle: @"Authentication Required"];
      content = [_panel contentView];

      [content addSubview: SCPanelLabel([NSString stringWithFormat:
        @"Enter your name and password for \"%@\".", resource],
        NSMakeRect(side, h - METRICS_CONTENT_TOP_MARGIN - 36, w - 2 * side, 36),
        NSLeftTextAlignment)];

      _password = [[NSSecureTextField alloc]
                    initWithFrame: NSMakeRect(fieldX, y, fieldW,
                                              METRICS_TEXT_INPUT_FIELD_HEIGHT)];
      [content addSubview: _password];
      [content addSubview: SCPanelLabel(@"Password:",
                                        NSMakeRect(side, y + 2, labelW, 18),
                                        NSRightTextAlignment)];
      y += METRICS_TEXT_INPUT_FIELD_HEIGHT + METRICS_SPACE_8;
      _user = [[NSTextField alloc]
                initWithFrame: NSMakeRect(fieldX, y, fieldW,
                                          METRICS_TEXT_INPUT_FIELD_HEIGHT)];
      [_user setStringValue: NSUserName()];
      [content addSubview: _user];
      [content addSubview: SCPanelLabel(@"Name:",
                                        NSMakeRect(side, y + 2, labelW, 18),
                                        NSRightTextAlignment)];
      [_user setNextKeyView: _password];
      [_password setNextKeyView: _user];

      ok = [self buttonWithTitle: @"OK" x: w - side - METRICS_BUTTON_MIN_WIDTH
                             tag: NSModalResponseOK];
      [ok setKeyEquivalent: @"\r"];
      [self buttonWithTitle: @"Cancel"
                          x: NSMinX([ok frame]) - METRICS_BUTTON_HORIZ_INTERSPACE
                             - METRICS_BUTTON_MIN_WIDTH
                        tag: NSModalResponseCancel];
      [_panel setInitialFirstResponder: _password];
      [_panel center];
    }
  return self;
}

- (void) finish: (NSButton *)sender
{
  [NSApp stopModalWithCode: [sender tag]];
}

- (NSDictionary *) run
{
  NSInteger result = [NSApp runModalForWindow: _panel];

  [_panel orderOut: nil];
  if (result != NSModalResponseOK)
    {
      return nil;
    }
  return @{@"user": [_user stringValue], @"password": [_password stringValue]};
}

+ (void) askOnMainThread: (NSMutableDictionary *)box
{
  SCPasswordPanel *panel = [[self alloc]
                             initWithResource: [box objectForKey: @"resource"]];
  NSDictionary *answer = [panel run];

  if (answer != nil)
    {
      [box addEntriesFromDictionary: answer];
    }
}

+ (BOOL) askForResource: (NSString *)resource
                   user: (NSString **)user
               password: (NSString **)password
{
  NSMutableDictionary *box = [NSMutableDictionary
                               dictionaryWithObject: resource forKey: @"resource"];

  /* SANE asks from inside sane_open, which runs on a worker thread */
  if ([NSThread isMainThread])
    {
      [self askOnMainThread: box];
    }
  else
    {
      [self performSelectorOnMainThread: @selector(askOnMainThread:)
                             withObject: box waitUntilDone: YES];
    }
  if ([box objectForKey: @"user"] == nil)
    {
      return NO;
    }
  *user = [box objectForKey: @"user"];
  *password = [box objectForKey: @"password"];
  return YES;
}

@end
