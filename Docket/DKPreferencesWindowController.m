/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DKPreferencesWindowController.h"
#import "DKPreferences.h"

static const CGFloat DKPMargin = 24.0;
static const CGFloat DKPTop = 15.0;
static const CGFloat DKPLabelW = 110.0;
static const CGFloat DKPFieldH = 22.0;
static const CGFloat DKPSpace8 = 8.0;
static const CGFloat DKPSpace16 = 16.0;
static const CGFloat DKPButtonH = 20.0;

@implementation DKPreferencesWindowController

+ (instancetype)sharedController
{
  static DKPreferencesWindowController *instance = nil;

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
  [_window setTitle: @"Docket Preferences"];
  content = [_window contentView];

  y = h - DKPTop - DKPFieldH;
  gistLabel = [[[NSTextField alloc] initWithFrame: NSMakeRect(DKPMargin, y, DKPLabelW, DKPFieldH)] autorelease];
  [gistLabel setStringValue: @"Gist ID:"];
  [gistLabel setEditable: NO];
  [gistLabel setBordered: NO];
  [gistLabel setDrawsBackground: NO];
  [content addSubview: gistLabel];

  _gistIdField = [[NSTextField alloc] initWithFrame:
    NSMakeRect(DKPMargin + DKPLabelW + DKPSpace8, y, w - DKPMargin * 2 - DKPLabelW - DKPSpace8, DKPFieldH)];
  [_gistIdField setStringValue: ([DKPreferences gistId] != nil) ? [DKPreferences gistId] : @""];
  [content addSubview: _gistIdField];
  [_gistIdField release];

  y -= DKPSpace16 + DKPFieldH;
  tokenLabel = [[[NSTextField alloc] initWithFrame: NSMakeRect(DKPMargin, y, DKPLabelW, DKPFieldH)] autorelease];
  [tokenLabel setStringValue: @"Access token:"];
  [tokenLabel setEditable: NO];
  [tokenLabel setBordered: NO];
  [tokenLabel setDrawsBackground: NO];
  [content addSubview: tokenLabel];

  _tokenField = [[NSSecureTextField alloc] initWithFrame:
    NSMakeRect(DKPMargin + DKPLabelW + DKPSpace8, y, w - DKPMargin * 2 - DKPLabelW - DKPSpace8, DKPFieldH)];
  [_tokenField setStringValue: ([DKPreferences token] != nil) ? [DKPreferences token] : @""];
  [content addSubview: _tokenField];
  [_tokenField release];

  y -= DKPSpace16 + 14.0;
  noteLabel = [[[NSTextField alloc] initWithFrame: NSMakeRect(DKPMargin, y, w - DKPMargin * 2, 28.0)] autorelease];
  [noteLabel setStringValue: @"Stored in this account's defaults for now; Keychain.app will hold it once available."];
  [noteLabel setFont: [NSFont systemFontOfSize: 11.0]];
  [noteLabel setTextColor: [NSColor darkGrayColor]];
  [noteLabel setEditable: NO];
  [noteLabel setBordered: NO];
  [noteLabel setDrawsBackground: NO];
  [content addSubview: noteLabel];

  saveButton = [[[NSButton alloc] initWithFrame:
    NSMakeRect(w - DKPMargin - 100.0, DKPTop, 100.0, DKPButtonH)] autorelease];
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
  [DKPreferences setGistId: [_gistIdField stringValue]];
  [DKPreferences setToken: [_tokenField stringValue]];
  [_window orderOut: nil];
}

@end
