/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "TDPreferencesWindowController.h"
#import "TDPreferences.h"

static const CGFloat TDPMargin = 24.0;
static const CGFloat TDPTop = 15.0;
static const CGFloat TDPLabelW = 110.0;
static const CGFloat TDPFieldH = 22.0;
static const CGFloat TDPSpace8 = 8.0;
static const CGFloat TDPSpace16 = 16.0;
static const CGFloat TDPButtonH = 20.0;

@implementation TDPreferencesWindowController

+ (instancetype)sharedController
{
  static TDPreferencesWindowController *instance = nil;

  if (instance == nil)
    {
      instance = [[self alloc] init];
    }
  return instance;
}

- (instancetype)init
{
  self = [super init];
  if (self)
    {
      [self buildWindow];
    }
  return self;
}

- (void)dealloc
{
  [_window release];
  [super dealloc];
}

- (void)buildWindow
{
  NSRect frame = NSMakeRect(200.0, 200.0, 460.0, 150.0);
  NSView *content;
  NSTextField *gistLabel, *tokenLabel, *noteLabel;
  NSButton *saveButton;
  CGFloat w = frame.size.width;
  CGFloat h = frame.size.height;
  CGFloat y;

  _window = [[NSWindow alloc] initWithContentRect: frame
                                         styleMask: (NSTitledWindowMask | NSClosableWindowMask)
                                           backing: NSBackingStoreBuffered
                                             defer: NO];
  [_window setTitle: @"Todo Preferences"];
  content = [_window contentView];

  y = h - TDPTop - TDPFieldH;
  gistLabel = [[[NSTextField alloc] initWithFrame: NSMakeRect(TDPMargin, y, TDPLabelW, TDPFieldH)] autorelease];
  [gistLabel setStringValue: @"Gist ID:"];
  [gistLabel setEditable: NO];
  [gistLabel setBordered: NO];
  [gistLabel setDrawsBackground: NO];
  [content addSubview: gistLabel];

  _gistIdField = [[NSTextField alloc] initWithFrame:
    NSMakeRect(TDPMargin + TDPLabelW + TDPSpace8, y, w - TDPMargin * 2 - TDPLabelW - TDPSpace8, TDPFieldH)];
  [_gistIdField setStringValue: ([TDPreferences gistId] != nil) ? [TDPreferences gistId] : @""];
  [content addSubview: _gistIdField];
  [_gistIdField release];

  y -= TDPSpace16 + TDPFieldH;
  tokenLabel = [[[NSTextField alloc] initWithFrame: NSMakeRect(TDPMargin, y, TDPLabelW, TDPFieldH)] autorelease];
  [tokenLabel setStringValue: @"Access token:"];
  [tokenLabel setEditable: NO];
  [tokenLabel setBordered: NO];
  [tokenLabel setDrawsBackground: NO];
  [content addSubview: tokenLabel];

  _tokenField = [[NSSecureTextField alloc] initWithFrame:
    NSMakeRect(TDPMargin + TDPLabelW + TDPSpace8, y, w - TDPMargin * 2 - TDPLabelW - TDPSpace8, TDPFieldH)];
  [_tokenField setStringValue: ([TDPreferences token] != nil) ? [TDPreferences token] : @""];
  [content addSubview: _tokenField];
  [_tokenField release];

  y -= TDPSpace16 + 14.0;
  noteLabel = [[[NSTextField alloc] initWithFrame: NSMakeRect(TDPMargin, y, w - TDPMargin * 2, 28.0)] autorelease];
  [noteLabel setStringValue: @"Stored in this account's defaults for now; Keychain.app will hold it once available."];
  [noteLabel setFont: [NSFont systemFontOfSize: 11.0]];
  [noteLabel setTextColor: [NSColor darkGrayColor]];
  [noteLabel setEditable: NO];
  [noteLabel setBordered: NO];
  [noteLabel setDrawsBackground: NO];
  [content addSubview: noteLabel];

  saveButton = [[[NSButton alloc] initWithFrame:
    NSMakeRect(w - TDPMargin - 100.0, TDPTop, 100.0, TDPButtonH)] autorelease];
  [saveButton setTitle: @"Save"];
  [saveButton setBezelStyle: NSRoundedBezelStyle];
  [saveButton setTarget: self];
  [saveButton setAction: @selector(save:)];
  [content addSubview: saveButton];
}

- (void)showWindow
{
  [_window makeKeyAndOrderFront: nil];
}

- (void)save: (id)sender
{
  [TDPreferences setGistId: [_gistIdField stringValue]];
  [TDPreferences setToken: [_tokenField stringValue]];
  [_window orderOut: nil];
}

@end
