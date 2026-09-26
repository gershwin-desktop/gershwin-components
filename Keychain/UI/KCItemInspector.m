/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "KCItemInspector.h"
#import "KCKeychainWindowController.h"
#import "KCUI.h"
#import "KCCollection.h"
#import "KCItem.h"

@implementation KCItemInspector
{
  __weak KCKeychainWindowController *_controller;
  KCItem *_item;
  KCCollection *_collection;
  NSTextField *_nameField;
  NSTextField *_serviceField;
  NSTextField *_accountField;
  NSTextField *_createdField;
  NSTextField *_modifiedField;
  NSTextField *_passwordField;
  NSButton *_showPassword;
  NSButton *_copyButton;
  NSButton *_saveButton;
  NSDateFormatter *_dateFormatter;
  /* The secret is only ever put into the field after a confirmation, and
   * taken out again when the item or the checkbox changes. */
  BOOL _revealed;
}

static NSTextField *KCReadOnlyField(void)
{
  NSTextField *field = KCMakeLabel(@"");
  [field setSelectable: YES];
  return field;
}

- (instancetype) initWithController: (KCKeychainWindowController *)controller
{
  CGFloat width = METRICS_WIN_MIN_WIDTH;
  NSUInteger rowCount = 6;
  CGFloat height = METRICS_CONTENT_TOP_MARGIN + KCFormHeight(rowCount)
    + METRICS_SPACE_8 + METRICS_RADIO_BUTTON_SIZE
    + METRICS_SPACE_20 + METRICS_BUTTON_HEIGHT + METRICS_CONTENT_BOTTOM_MARGIN;
  /* A window, not a panel: GNUstep makes every panel a utility window the
   * window manager keeps above dialogs, which hid the password
   * confirmation this window asks for behind itself. */
  NSWindow *window = [[NSWindow alloc]
    initWithContentRect: NSMakeRect(0, 0, width, height)
              styleMask: NSTitledWindowMask | NSClosableWindowMask
                backing: NSBackingStoreBuffered defer: NO];
  NSView *content = [window contentView];
  CGFloat y;
  CGFloat fieldX = METRICS_CONTENT_SIDE_MARGIN + KCFormLabelWidth + METRICS_SPACE_8;

  if ((self = [super initWithWindow: window]) == nil)
    return nil;
  _controller = controller;
  _dateFormatter = [NSDateFormatter new];
  [_dateFormatter setDateStyle: NSDateFormatterLongStyle];
  [_dateFormatter setTimeStyle: NSDateFormatterShortStyle];

  [window setTitle: @"Item Info"];
  [window setReleasedWhenClosed: NO];

  _nameField = KCMakeField(NO);
  _serviceField = KCReadOnlyField();
  _accountField = KCReadOnlyField();
  _createdField = KCReadOnlyField();
  _modifiedField = KCReadOnlyField();
  _passwordField = KCMakeField(YES);

  y = KCLayoutFormRows(content, [NSArray arrayWithObjects:
    @"Name:", _nameField, @"Service:", _serviceField, @"Account:", _accountField,
    @"Created:", _createdField, @"Modified:", _modifiedField,
    @"Password:", _passwordField, nil],
    height - METRICS_CONTENT_TOP_MARGIN, width);

  _showPassword = KCMakeCheckbox(@"Show password", self, @selector(toggleShowPassword:));
  y -= METRICS_SPACE_8 + METRICS_RADIO_BUTTON_SIZE;
  [_showPassword setFrame: NSMakeRect(fieldX, y, width - fieldX - METRICS_CONTENT_SIDE_MARGIN,
                                      METRICS_RADIO_BUTTON_SIZE)];
  [content addSubview: _showPassword];

  _saveButton = KCMakeButton(@"Save Changes", self, @selector(save:));
  _copyButton = KCMakeButton(@"Copy Password", self, @selector(copyPassword:));
  KCLayoutButtonRow([NSArray arrayWithObjects: _saveButton, _copyButton, nil],
    width - METRICS_CONTENT_SIDE_MARGIN, METRICS_CONTENT_BOTTOM_MARGIN);
  [content addSubview: _saveButton];
  [content addSubview: _copyButton];
  [window setFrameAutosaveName: @"KeychainItemInspector"];
  return self;
}

- (void) conceal
{
  NSView *content = [[self window] contentView];
  NSTextField *secure;

  _revealed = NO;
  [_showPassword setState: NSOffState];
  if ([_passwordField isKindOfClass: [NSSecureTextField class]])
    {
      [_passwordField setStringValue: @""];
      return;
    }
  secure = KCMakeField(YES);
  [secure setFrame: [_passwordField frame]];
  [content replaceSubview: _passwordField with: secure];
  _passwordField = secure;
}

- (void) reveal
{
  NSView *content = [[self window] contentView];
  NSTextField *plain = KCMakeField(NO);
  NSString *secret = [[NSString alloc] initWithData: [_item secret]
                                           encoding: NSUTF8StringEncoding];

  [plain setFrame: [_passwordField frame]];
  [plain setStringValue: secret != nil ? secret : @""];
  /* Binary secrets (keys, tokens stored as bytes) cannot be edited as
   * text without corrupting them. */
  [plain setEditable: secret != nil];
  [content replaceSubview: _passwordField with: plain];
  _passwordField = plain;
  _revealed = YES;
  [_showPassword setState: NSOnState];
}

- (void) setItem: (KCItem *)item collection: (KCCollection *)collection
{
  BOOL usable = item != nil && ![collection isLocked];

  if (item != _item)
    [self conceal];
  _item = item;
  _collection = collection;

  [_nameField setStringValue: usable ? [item label] : @""];
  [_serviceField setStringValue: usable ? [item displayService] : @""];
  [_accountField setStringValue: usable ? [item displayAccount] : @""];
  [_createdField setStringValue: usable ? [_dateFormatter stringFromDate: [item created]] : @""];
  [_modifiedField setStringValue: usable ? [_dateFormatter stringFromDate: [item modified]] : @""];
  [_nameField setEditable: usable];
  [_passwordField setEditable: usable && _revealed];
  [_showPassword setEnabled: usable];
  [_copyButton setEnabled: usable];
  [_saveButton setEnabled: usable];
  if (!usable)
    [self conceal];
}

- (void) toggleShowPassword: (id)sender
{
  KCItem *item = _item;

  if (_revealed || item == nil)
    {
      [self conceal];
      return;
    }
  /* Unchecked until confirmed: a cancelled confirmation must not leave the
   * box looking as if the password were shown. */
  [_showPassword setState: NSOffState];
  __weak KCItemInspector *weakSelf = self;
  [_controller confirmPasswordForCollection: _collection
    reason: [NSString stringWithFormat:
              @"To show the password of \"%@\", enter the password of the "
              @"keychain \"%@\".", [item label], [_collection label]]
      then: ^{
        KCItemInspector *me = weakSelf;
        if (me != nil && me->_item == item)
          [me reveal];
      }];
}

- (void) copyPassword: (id)sender
{
  [_controller copyPassword: sender];
}

- (void) save: (id)sender
{
  if (_item == nil || [_collection isLocked])
    return;
  [_item setLabel: [_nameField stringValue]];
  if (_revealed && [_passwordField isEditable])
    [_item setSecret: [[_passwordField stringValue]
                        dataUsingEncoding: NSUTF8StringEncoding]];
  [_collection itemDidChange: _item];
  [_controller saveCollection: _collection];
}

@end
