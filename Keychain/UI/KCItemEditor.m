/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "KCItemEditor.h"
#import "KCKeychainWindowController.h"
#import "KCUI.h"
#import "KCCollection.h"

static NSString * const kGenericSchema = @"org.freedesktop.Secret.Generic";

@implementation KCItemEditor
{
  __weak KCKeychainWindowController *_controller;
  KCCollection *_collection;
  NSTextField *_nameField;
  NSTextField *_serviceField;
  NSTextField *_accountField;
  NSTextField *_passwordField;
  NSTextField *_errorLabel;
}

- (instancetype) initWithController: (KCKeychainWindowController *)controller
{
  CGFloat width = METRICS_WIN_MIN_WIDTH;
  CGFloat height = METRICS_CONTENT_TOP_MARGIN + KCFormHeight(4)
    + METRICS_SPACE_8 + METRICS_SPACE_16
    + METRICS_SPACE_12 + METRICS_BUTTON_HEIGHT + METRICS_CONTENT_BOTTOM_MARGIN;
  NSPanel *panel = [[NSPanel alloc]
    initWithContentRect: NSMakeRect(0, 0, width, height)
              styleMask: NSTitledWindowMask | NSClosableWindowMask
                backing: NSBackingStoreBuffered defer: NO];
  NSView *content = [panel contentView];
  CGFloat fieldX = METRICS_CONTENT_SIDE_MARGIN + KCFormLabelWidth + METRICS_SPACE_8;
  NSButton *add;
  NSButton *cancel;
  CGFloat y;

  if ((self = [super initWithWindow: panel]) == nil)
    return nil;
  _controller = controller;
  [panel setTitle: @"New Password Item"];

  _nameField = KCMakeField(NO);
  _serviceField = KCMakeField(NO);
  _accountField = KCMakeField(NO);
  _passwordField = KCMakeField(YES);
  y = KCLayoutFormRows(content, [NSArray arrayWithObjects:
    @"Name:", _nameField, @"Service:", _serviceField,
    @"Account:", _accountField, @"Password:", _passwordField, nil],
    height - METRICS_CONTENT_TOP_MARGIN, width);

  _errorLabel = KCMakeLabel(@"");
  [_errorLabel setTextColor: [NSColor redColor]];
  [_errorLabel setFont: METRICS_FONT_SYSTEM_REGULAR_11];
  [_errorLabel setFrame: NSMakeRect(fieldX, y - METRICS_SPACE_8 - METRICS_SPACE_16,
    width - fieldX - METRICS_CONTENT_SIDE_MARGIN, METRICS_SPACE_16)];
  [content addSubview: _errorLabel];

  add = KCMakeButton(@"Add", self, @selector(add:));
  cancel = KCMakeButton(@"Cancel", self, @selector(cancel:));
  [add setKeyEquivalent: @"\r"];
  [cancel setKeyEquivalent: @"\e"];
  KCLayoutButtonRow([NSArray arrayWithObjects: add, cancel, nil],
    width - METRICS_CONTENT_SIDE_MARGIN, METRICS_CONTENT_BOTTOM_MARGIN);
  [content addSubview: add];
  [content addSubview: cancel];

  [panel setInitialFirstResponder: _nameField];
  [_nameField setNextKeyView: _serviceField];
  [_serviceField setNextKeyView: _accountField];
  [_accountField setNextKeyView: _passwordField];
  return self;
}

- (void) beginForCollection: (KCCollection *)collection
{
  _collection = collection;
  [_nameField setStringValue: @""];
  [_serviceField setStringValue: @""];
  [_accountField setStringValue: @""];
  [_passwordField setStringValue: @""];
  [_errorLabel setStringValue: @""];
  [[self window] center];
  [self showWindow: self];
  [[self window] makeFirstResponder: _nameField];
}

- (void) add: (id)sender
{
  NSString *service = [_serviceField stringValue];
  NSString *account = [_accountField stringValue];
  NSString *name = [_nameField stringValue];
  NSMutableDictionary *attributes = [NSMutableDictionary dictionary];

  if ([_collection isLocked])
    {
      [_errorLabel setStringValue: @"The keychain was locked meanwhile."];
      return;
    }
  if ([service length] == 0 || [[_passwordField stringValue] length] == 0)
    {
      [_errorLabel setStringValue: @"Enter at least a service and a password."];
      return;
    }
  [attributes setObject: kGenericSchema forKey: @"xdg:schema"];
  [attributes setObject: service forKey: @"service"];
  if ([account length] > 0)
    [attributes setObject: account forKey: @"account"];

  [_collection createItemWithLabel: [name length] > 0 ? name : service
                        attributes: attributes
                            secret: [[_passwordField stringValue]
                                      dataUsingEncoding: NSUTF8StringEncoding]
                       contentType: @"text/plain"
                           replace: NO];
  [_passwordField setStringValue: @""];
  if ([_controller saveCollection: _collection])
    [[self window] orderOut: self];
}

- (void) cancel: (id)sender
{
  [_passwordField setStringValue: @""];
  [[self window] orderOut: self];
}

@end
