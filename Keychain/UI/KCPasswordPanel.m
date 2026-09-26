/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "KCPasswordPanel.h"
#import "KCUI.h"

/* Open panels own themselves until they close; nothing else holds them
 * while the user types. */
static NSMutableSet *KCOpenPanels(void)
{
  static NSMutableSet *panels = nil;
  if (panels == nil)
    panels = [NSMutableSet new];
  return panels;
}

@implementation KCPasswordPanel
{
  NSPanel *_panel;
  NSTextField *_nameField;
  NSTextField *_passwordField;
  NSTextField *_verifyField;
  NSTextField *_errorLabel;
  BOOL _newPassword;
  KCPasswordValidator _validator;
  void (^_completion)(BOOL);
}

- (instancetype) initWithTitle: (NSString *)title
                       message: (NSString *)message
                   newPassword: (BOOL)newPassword
                       askName: (BOOL)askName
                     validator: (KCPasswordValidator)validator
                    completion: (void (^)(BOOL accepted))completion
{
  if ((self = [super init]) != nil)
    {
      CGFloat width = METRICS_WIN_MIN_WIDTH;
      CGFloat inner = width - 2 * METRICS_CONTENT_SIDE_MARGIN;
      CGFloat fieldX = METRICS_CONTENT_SIDE_MARGIN + KCFormLabelWidth + METRICS_SPACE_8;
      CGFloat fieldW = width - fieldX - METRICS_CONTENT_SIDE_MARGIN;
      NSTextField *messageLabel = KCMakeWrappingLabel(message);
      CGFloat messageH = KCWrappedHeight(messageLabel, inner);
      NSMutableArray *rows = [NSMutableArray array];
      NSButton *ok = KCMakeButton(newPassword ? @"Create" : @"OK", self, @selector(ok:));
      NSButton *cancel = KCMakeButton(@"Cancel", self, @selector(cancel:));
      CGFloat height;
      CGFloat y;
      NSView *content;

      _newPassword = newPassword;
      _validator = [validator copy];
      _completion = [completion copy];

      if (askName)
        {
          _nameField = KCMakeField(NO);
          [rows addObjectsFromArray: [NSArray arrayWithObjects: @"Name:", _nameField, nil]];
        }
      _passwordField = KCMakeField(YES);
      [rows addObjectsFromArray: [NSArray arrayWithObjects: @"Password:", _passwordField, nil]];
      if (newPassword)
        {
          _verifyField = KCMakeField(YES);
          [rows addObjectsFromArray: [NSArray arrayWithObjects: @"Verify:", _verifyField, nil]];
        }

      height = METRICS_CONTENT_TOP_MARGIN + messageH + METRICS_SPACE_16
        + KCFormHeight([rows count] / 2)
        + METRICS_SPACE_8 + METRICS_SPACE_16
        + METRICS_SPACE_12 + METRICS_BUTTON_HEIGHT + METRICS_CONTENT_BOTTOM_MARGIN;

      _panel = [[NSPanel alloc] initWithContentRect: NSMakeRect(0, 0, width, height)
        styleMask: NSTitledWindowMask | NSClosableWindowMask
        backing: NSBackingStoreBuffered defer: NO];
      [_panel setTitle: title];
      [_panel setDelegate: self];
      [_panel setReleasedWhenClosed: NO];
      /* A password request answers another window (the inspector) or
       * another application waiting on D-Bus; it must never open hidden
       * behind either. */
      [_panel setLevel: NSModalPanelWindowLevel];
      content = [_panel contentView];

      y = height - METRICS_CONTENT_TOP_MARGIN - messageH;
      [messageLabel setFrame: NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, y, inner, messageH)];
      [content addSubview: messageLabel];
      y -= METRICS_SPACE_16;

      y = KCLayoutFormRows(content, rows, y, width) - METRICS_SPACE_8;

      _errorLabel = KCMakeLabel(@"");
      [_errorLabel setTextColor: [NSColor redColor]];
      [_errorLabel setFont: METRICS_FONT_SYSTEM_REGULAR_11];
      [_errorLabel setFrame: NSMakeRect(fieldX, y - METRICS_SPACE_16, fieldW, METRICS_SPACE_16)];
      [content addSubview: _errorLabel];

      [ok setKeyEquivalent: @"\r"];
      [cancel setKeyEquivalent: @"\e"];
      KCLayoutButtonRow([NSArray arrayWithObjects: ok, cancel, nil],
        width - METRICS_CONTENT_SIDE_MARGIN, METRICS_CONTENT_BOTTOM_MARGIN);
      [content addSubview: ok];
      [content addSubview: cancel];

      [_panel setInitialFirstResponder: askName ? _nameField : _passwordField];
      if (askName)
        [_nameField setNextKeyView: _passwordField];
      if (newPassword)
        [_passwordField setNextKeyView: _verifyField];
    }
  return self;
}

- (NSPanel *) panel
{
  return _panel;
}

- (NSString *) password
{
  return [_passwordField stringValue];
}

- (NSString *) name
{
  return _nameField != nil ? [_nameField stringValue] : nil;
}

- (void) show
{
  [KCOpenPanels() addObject: self];
  [_panel center];
  [NSApp activateIgnoringOtherApps: YES];
  [_panel makeKeyAndOrderFront: nil];
  [_panel makeFirstResponder: [_panel initialFirstResponder]];
}

- (void) finish: (BOOL)accepted notify: (BOOL)notify
{
  void (^completion)(BOOL) = _completion;

  _completion = nil;
  [_panel setDelegate: nil];
  [_panel orderOut: nil];
  [_passwordField setStringValue: @""];
  [_verifyField setStringValue: @""];
  if (notify && completion != nil)
    completion(accepted);
  [KCOpenPanels() removeObject: self];
}

- (void) ok: (id)sender
{
  NSString *problem = nil;

  if (_nameField != nil && [[_nameField stringValue] length] == 0)
    problem = @"Enter a name.";
  else if (_newPassword && [[_passwordField stringValue] length] == 0)
    problem = @"Enter a password.";
  else if (_newPassword
    && ![[_passwordField stringValue] isEqualToString: [_verifyField stringValue]])
    problem = @"The passwords do not match.";
  else
    problem = _validator(self);

  if (problem != nil)
    {
      [_errorLabel setStringValue: problem];
      [_passwordField setStringValue: @""];
      [_verifyField setStringValue: @""];
      [_panel makeFirstResponder: _passwordField];
      return;
    }
  [self finish: YES notify: YES];
}

- (void) cancel: (id)sender
{
  [self finish: NO notify: YES];
}

- (void) close
{
  [self finish: NO notify: NO];
}

- (void) windowWillClose: (NSNotification *)n
{
  if (_completion != nil)
    [self finish: NO notify: YES];
}

@end
