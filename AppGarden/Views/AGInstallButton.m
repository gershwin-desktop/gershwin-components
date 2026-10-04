/* Copyright (c) 2026 Simon Peter / SPDX-License-Identifier: BSD-2-Clause */

#import "AGInstallButton.h"
#import "AppearanceMetrics.h"
#import "AGApp.h"
#import "AGInstaller.h"
#import "AGInstallTask.h"
#import "AGDownloadResolver.h"
#import "AGRiskAdviser.h"
#import "AGRiskCategory.h"
#import "AGRiskMatch.h"
#import "AGGitHubInfo.h"

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
  BOOL _checking;   /* waiting for GitHub to say how old the publisher is */
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
      /* The task's progress is a fraction of the whole install, or -1 while
       * nothing is measurable yet (the release lookup, or a server that
       * declares no size). The value alone decides which of the two the bar
       * draws, so it is never guessed from a band of values: the transfer
       * reports real fractions all the way from 0.05 to 0.95. */
      float progress = [[_installer taskForApp:_app] progress];
      BOOL indeterminate = (progress < 0.0f);
      [_progress setIndeterminate:indeterminate];
      if (!indeterminate)
        [_progress setDoubleValue:progress];
      [self updateAnimation];
      return;
    }
  [self updateAnimation];
  [_button setTitle:_checking ? NSLocalizedString(@"Checking...", @"Looking up the publisher before a download")
                              : [self titleForState:_state]];
  [_button setEnabled:(_state != AGInstallButtonStateUnavailable && !_checking)];
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
        return NSLocalizedString(@"Open", @"Show the installed file in the file manager");
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
        /* The one place a Get is started, from a card or from the detail
         * page alike, so this is also the one place the risk alert has to
         * stand in front of a download. */
        [self beginGet:app];
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
          /* Open shows where the file is; it does not start the application.
           * A file manager that will not show it is reported, not retried. */
          NSError *error = nil;
          if (![_installer revealApp:app error:&error])
            [self showMessage:NSLocalizedString(@"Could Not Show the File", @"")
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
      /* No second risk alert here: reaching this alert means a Get was
       * already confirmed once, so asking again would only repeat itself. */
      [_installer installApp:_app];
      [self reloadState];
    }
}

/*
 * Nothing in the catalog has been vetted, so a Get first collects what is
 * worth a warning: the risk categories the item's metadata falls into and,
 * for a download from GitHub, a publisher account younger than a month or
 * one that cannot be looked up. With nothing to say the download starts at
 * once; otherwise a sheet asks, and the download starts from its answer.
 */
- (void)beginGet:(AGApp *)app
{
  NSMutableArray<NSString *> *sentences = [NSMutableArray array];
  AGRiskAdviser *adviser = [AGRiskAdviser sharedAdviser];
  AGRiskMatch *match;
  for (match in [adviser matchesForApp:app])
    [sentences addObject:[[match category] shortRisk]];

  id payload = nil;
  NSString *owner = nil;
  if ([AGDownloadResolver kindForApp:app payload:&payload] == AGDownloadKindGitHubLatestRelease)
    owner = [AGGitHubInfo ownerOfRepo:[app githubRepo]];

  if (owner == nil)
    {
      [self finishGet:app warnings:sentences];
      return;
    }

  _checking = YES;
  [self updateControls];
  __weak AGInstallButton *weakSelf = self;
  [[_installer gitHubInfo] accountCreationDateForOwner:owner
      completion:^(NSDate *date, NSError *error)
        {
          AGInstallButton *strongSelf = weakSelf;
          if (strongSelf == nil)
            return;
          strongSelf->_checking = NO;
          [strongSelf updateControls];
          NSString *sentence = [AGGitHubInfo warningForAccountCreatedOn:date now:[NSDate date]];
          if (sentence != nil)
            [sentences addObject:sentence];
          [strongSelf finishGet:app warnings:sentences];
        }];
}

- (void)finishGet:(AGApp *)app warnings:(NSArray<NSString *> *)sentences
{
  if ([sentences count] == 0)
    {
      [_installer installApp:app];
      [self reloadState];
      return;
    }

  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:[NSString stringWithFormat:
                            NSLocalizedString(@"Do you want to download \"%@\"?", @""),
                            [app displayName]]];
  /* One paragraph: the theme gives the informative text a box a few lines
   * high and scrolls anything longer, and a blank line costs one of them. */
  NSMutableArray<NSString *> *lines = [sentences mutableCopy];
  [lines addObject:[[AGRiskAdviser sharedAdviser] disclaimerShort]];
  [alert setInformativeText:[lines componentsJoinedByString:@" "]];
  /* Cancel is added first, which makes it the default button, so Return and
   * Escape both mean "do not download". */
  [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"")];
  [alert addButtonWithTitle:NSLocalizedString(@"Download", @"")];

  /* A sheet on this button's window, so the warning looks like every other
   * alert on the desktop. The sheet does not block: its answer arrives in the
   * completion handler, which is why the download is started from there. */
  AGInstaller *installer = _installer;
  __weak AGInstallButton *weakSelf = self;
  void (^answer)(NSModalResponse) = ^(NSModalResponse code)
    {
      if (code != NSAlertSecondButtonReturn)
        return;
      [installer installApp:app];
      [weakSelf reloadState];
    };

  NSWindow *parent = [self window];
  if (parent == nil)
    answer([alert runModal]);
  else
    [alert beginSheetModalForWindow:parent completionHandler:answer];
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
