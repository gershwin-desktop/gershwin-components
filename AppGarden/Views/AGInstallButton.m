/* Copyright (c) 2026 Simon Peter / SPDX-License-Identifier: BSD-2-Clause */

#import "AGInstallButton.h"
#import "AppearanceMetrics.h"
#import "AGApp.h"
#import "AGInstaller.h"
#import "AGInstallTask.h"
#import "AGDownloadResolver.h"

/*
 * The rendered state. It is kept in an ivar rather than derived in drawRect:
 * deriving asks the installer to stat the launcher file, and drawRect runs on
 * every hover and scroll frame.
 */
typedef NS_ENUM(NSInteger, AGInstallButtonState) {
    AGInstallButtonStateGet = 0,
    AGInstallButtonStateWaiting,
    AGInstallButtonStateDownloading,
    AGInstallButtonStateOpen,
    AGInstallButtonStateFailed,
    AGInstallButtonStateOpenPage,
    AGInstallButtonStateUnavailable
};


@implementation AGInstallButton
{
  AGInstallButtonStyle _style;
  AGInstaller *_installer;
  AGApp *_app;
  AGInstallButtonState _state;
  NSButton *_button;
  NSProgressIndicator *_progress;
}

#pragma mark - Setup

- (instancetype)initWithFrame:(NSRect)frame
                        style:(AGInstallButtonStyle)style
                    installer:(AGInstaller *)installer
{
  self = [super initWithFrame:frame];
  if (self != nil)
    {
      _style = style;
      _installer = installer;
      _state = AGInstallButtonStateUnavailable;
      [self buildControls];

      NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
      /* The task notification carries the task as its object, so it cannot be
       * filtered by object here; the handler compares app names instead. The
       * installed-set notification carries the installer, so it can. */
      [center addObserver:self
                 selector:@selector(taskDidChange:)
                     name:AGInstallerTaskDidChangeNotification
                   object:nil];
      [center addObserver:self
                 selector:@selector(installedSetDidChange:)
                     name:AGInstallerInstalledSetDidChangeNotification
                   object:installer];
      [self reloadState];
    }
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)isFlipped
{
  /* Same convention as the card and the grid around it, so a child placed by
   * y-down arithmetic lands where it looks. */
  return YES;
}

/* Defined only so the interface's NS_UNAVAILABLE entries have a body. The
 * attributes stop any caller from reaching them; they route to the
 * designated initializer so the compiler sees a well-formed chain. */
- (instancetype)initWithFrame:(NSRect)frame
{
  return [self initWithFrame:frame style:AGInstallButtonStyleCard installer:nil];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
  (void)coder;
  return [self initWithFrame:NSZeroRect style:AGInstallButtonStyleCard installer:nil];
}

+ (NSSize)sizeForStyle:(AGInstallButtonStyle)style
{
  /* One size everywhere: the standard push button of the appearance
   * metrics, so the card, the detail page and Remove next to it line up. */
  (void)style;
  return NSMakeSize(METRICS_BUTTON_MIN_WIDTH, METRICS_BUTTON_HEIGHT);
}

- (AGApp *)app
{
  return _app;
}

- (void)setApp:(AGApp *)app
{
  if (_app == app)
    return;
  _app = app;
  [self reloadState];
}

#pragma mark - State

- (void)reloadState
{
  _state = [self computeState];
  [self updateToolTip];
  [self updateControls];
}

- (AGInstallButtonState)computeState
{
  AGApp *app = _app;
  if (app == nil || _installer == nil)
    return AGInstallButtonStateUnavailable;

  /* The resolver runs first because it decides whether there is anything to
   * do at all: an item with no links stays Unavailable even if a stale
   * registry entry claims it was installed once. */
  AGDownloadKind kind = [AGDownloadResolver kindForApp:app payload:NULL];
  if (kind == AGDownloadKindNone)
    return AGInstallButtonStateUnavailable;

  AGInstallState installed = [_installer stateForApp:app];
  if (installed == AGInstallStateInstalled)
    return AGInstallButtonStateOpen;

  AGInstallTask *task = [_installer taskForApp:app];
  if (task != nil)
    {
      switch ([task state])
        {
          case AGInstallTaskStateWaiting:
            return AGInstallButtonStateWaiting;
          case AGInstallTaskStateDownloading:
            return AGInstallButtonStateDownloading;
          case AGInstallTaskStateFailed:
            return AGInstallButtonStateFailed;
          case AGInstallTaskStateDone:
            return AGInstallButtonStateOpen;
          case AGInstallTaskStateCancelled:
            break;   /* a cancelled task leaves the app Get-able again */
        }
    }
  if (installed == AGInstallStateFailed)
    return AGInstallButtonStateFailed;

  if (kind == AGDownloadKindWebPageOnly)
    return ([app downloadPageURL] != nil) ? AGInstallButtonStateOpenPage
                                          : AGInstallButtonStateUnavailable;
  return AGInstallButtonStateGet;
}

- (void)updateToolTip
{
  if (_state == AGInstallButtonStateDownloading)
    {
      [self setToolTip:NSLocalizedString(@"Downloading. Click to cancel.", @"")];
      return;
    }
  if (_state != AGInstallButtonStateFailed)
    {
      [self setToolTip:nil];
      [_button setToolTip:nil];
      return;
    }
  NSString *text = [[[_installer taskForApp:_app] error] localizedDescription];
  if ([text length] == 0)
    text = NSLocalizedString(@"The download failed.", @"");
  [self setToolTip:text];
  [_button setToolTip:text];
}

- (void)taskDidChange:(NSNotification *)note
{
  AGApp *app = _app;
  AGInstallTask *task = [[note object] isKindOfClass:[AGInstallTask class]]
      ? [note object] : nil;
  if (app == nil || task == nil)
    return;
  /* Every card observes every task; only the one carrying this button's app
   * may redraw, or a single install would repaint the whole grid. */
  if (![[[task app] name] isEqualToString:[app name]])
    return;
  [self reloadState];
}

- (void)installedSetDidChange:(NSNotification *)note
{
  /* No filter: the installed set moved somewhere, and Open versus Get is
   * exactly what that changes for this app. */
  (void)note;
  [self reloadState];
}

#pragma mark - Controls

/* The button is a real NSButton so the theme draws it like every other push
 * button on this desktop, at the standard 100 x 20; only the download state
 * is not a button and shows the theme's progress bar instead. */
- (void)buildControls
{
  NSRect bounds = [self bounds];
  _button = [[NSButton alloc] initWithFrame:bounds];
  [_button setBezelStyle:NSRoundedBezelStyle];
  [_button setFont:METRICS_FONT_SYSTEM_REGULAR_13];
  [_button setTarget:self];
  [_button setAction:@selector(buttonClicked:)];
  [_button setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  [self addSubview:_button];

  _progress = [[NSProgressIndicator alloc] initWithFrame:bounds];
  [_progress setStyle:NSProgressIndicatorBarStyle];
  [_progress setControlSize:NSSmallControlSize];
  [_progress setMinValue:0.0];
  [_progress setMaxValue:1.0];
  [_progress setHidden:YES];
  [_progress setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  [self addSubview:_progress];
}

- (void)updateControls
{
  BOOL downloading = (_state == AGInstallButtonStateDownloading);
  [_button setHidden:downloading];
  [_progress setHidden:!downloading];

  if (downloading)
    {
      /* The downloader reports coarse phases: between "downloading" and
       * "saving" no byte count exists, so the bar runs indeterminate there
       * and determinate outside that band. */
      float progress = [[_installer taskForApp:_app] progress];
      BOOL indeterminate = (progress < 0.0f || (progress > 0.1f && progress < 0.6f));
      [_progress setIndeterminate:indeterminate];
      if (!indeterminate)
        [_progress setDoubleValue:progress];
      [self updateAnimation];
      return;
    }
  [self updateAnimation];
  [_button setTitle:[self titleForState:_state]];
  [_button setEnabled:(_state != AGInstallButtonStateUnavailable)];
}

/* The indeterminate bar animates only while it can be seen, so a card
 * recycled off screen costs nothing. */
- (void)updateAnimation
{
  BOOL wanted = (_state == AGInstallButtonStateDownloading && [self window] != nil
                 && [_progress isIndeterminate]);
  if (wanted)
    [_progress startAnimation:nil];
  else
    [_progress stopAnimation:nil];
}

- (void)viewDidMoveToWindow
{
  [super viewDidMoveToWindow];
  [self updateAnimation];
}

- (NSString *)titleForState:(AGInstallButtonState)state
{
  switch (state)
    {
      case AGInstallButtonStateGet:
        return NSLocalizedString(@"Get", @"Start the download and install");
      case AGInstallButtonStateWaiting:
        return NSLocalizedString(@"Waiting...", @"Queued behind another install");
      case AGInstallButtonStateDownloading:
        return @"";   /* the progress bar stands in for the button */
      case AGInstallButtonStateOpen:
        return NSLocalizedString(@"Open", @"Launch the installed application");
      case AGInstallButtonStateFailed:
        return NSLocalizedString(@"Failed", @"The install did not finish");
      case AGInstallButtonStateOpenPage:
        return NSLocalizedString(@"Open Page", @"No AppImage here, open the download page");
      case AGInstallButtonStateUnavailable:
        return NSLocalizedString(@"Unavailable", @"Nothing can be installed for this machine");
    }
  return @"";
}

#pragma mark - Interaction

- (void)buttonClicked:(id)sender
{
  (void)sender;
  [self performClick];
}

/* A click on the running progress bar cancels the download; the bar has no
 * room for a second control at the standard button size. */
- (void)mouseDown:(NSEvent *)event
{
  (void)event;
  if (_state == AGInstallButtonStateDownloading)
    [self performClick];
}

- (void)performClick
{
  AGApp *app = _app;
  if (app == nil || _installer == nil)
    return;

  switch (_state)
    {
      case AGInstallButtonStateGet:
        [_installer installApp:app];
        [self reloadState];
        break;

      case AGInstallButtonStateWaiting:
      case AGInstallButtonStateDownloading:
        {
          AGInstallTask *task = [_installer taskForApp:app];
          if (task != nil)
            [_installer cancelTask:task];
          [self reloadState];
        }
        break;

      case AGInstallButtonStateOpen:
        {
          NSError *error = nil;
          if (![_installer launchApp:app error:&error])
            [self showMessage:NSLocalizedString(@"Could Not Open the Application", @"")
                       details:[error localizedDescription]];
        }
        break;

      case AGInstallButtonStateFailed:
        [self showFailureAlert];
        break;

      case AGInstallButtonStateOpenPage:
        if ([app downloadPageURL] != nil)
          [[NSWorkspace sharedWorkspace] openURL:[app downloadPageURL]];
        break;

      case AGInstallButtonStateUnavailable:
        break;
    }
}

- (void)showFailureAlert
{
  NSString *details = [[[_installer taskForApp:_app] error] localizedDescription];
  if ([details length] == 0)
    details = NSLocalizedString(@"The download failed.", @"");

  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:NSLocalizedString(@"Download Failed", @"")];
  [alert setInformativeText:details];
  [alert addButtonWithTitle:NSLocalizedString(@"Try Again", @"")];
  [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"")];
  if ([alert runModal] == NSAlertFirstButtonReturn)
    {
      [_installer installApp:_app];
      [self reloadState];
    }
}

- (void)showMessage:(NSString *)message details:(NSString *)details
{
  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:message];
  if ([details length] > 0)
    [alert setInformativeText:details];
  [alert addButtonWithTitle:NSLocalizedString(@"OK", @"")];
  [alert runModal];
}

@end
