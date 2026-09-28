/* Copyright (c) 2026 Simon Peter / SPDX-License-Identifier: BSD-2-Clause */

#import "AGInstallButton.h"
#import "AGColors.h"
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

/* Stripe period and band width of the barber pole, in points: wide enough to
 * read at 22 points of button height, narrow enough that three stripes are
 * visible at once in an 80-point pill. */
static const CGFloat kAGBarberPeriod = 12.0;
static const CGFloat kAGBarberStripe = 6.0;
/* Right-hand gutter that keeps the cancel glyph clear of the stripes. */
static const CGFloat kAGCancelGutter = 16.0;

@implementation AGInstallButton
{
  AGInstallButtonStyle _style;
  AGInstaller *_installer;
  AGApp *_app;
  AGInstallButtonState _state;
  NSTimer *_barberTimer;
  CGFloat _barberPhase;
  BOOL _pressed;
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
  [_barberTimer invalidate];
  _barberTimer = nil;
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
  if (style == AGInstallButtonStyleDetail)
    return NSMakeSize(120.0, 28.0);
  return NSMakeSize(80.0, 22.0);
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
  [self updateBarberTimer];
  [self setNeedsDisplay:YES];
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
  if (_state != AGInstallButtonStateFailed)
    {
      [self setToolTip:nil];
      return;
    }
  NSString *text = [[[_installer taskForApp:_app] error] localizedDescription];
  if ([text length] == 0)
    text = NSLocalizedString(@"The installation failed.", @"");
  [self setToolTip:text];
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

#pragma mark - Barber pole

- (void)updateBarberTimer
{
  BOOL wanted = (_state == AGInstallButtonStateDownloading && [self window] != nil);
  if (wanted && _barberTimer == nil)
    {
      /* Common modes so the pole keeps moving while the grid is scrolled,
       * which is the one moment a Downloading card is looked at. The timer
       * retains the button; dropping it when the view leaves a window is what
       * breaks that retain when a card is recycled. */
      _barberTimer = [NSTimer timerWithTimeInterval:1.0 / 20.0
                                             target:self
                                           selector:@selector(barberTick:)
                                           userInfo:nil
                                            repeats:YES];
      [[NSRunLoop mainRunLoop] addTimer:_barberTimer forMode:NSRunLoopCommonModes];
    }
  else if (!wanted && _barberTimer != nil)
    {
      [_barberTimer invalidate];
      _barberTimer = nil;
    }
}

- (void)viewDidMoveToWindow
{
  [super viewDidMoveToWindow];
  [self updateBarberTimer];
}

- (void)barberTick:(NSTimer *)timer
{
  (void)timer;
  _barberPhase += 2.0;
  if (_barberPhase >= kAGBarberPeriod)
    _barberPhase -= kAGBarberPeriod;
  [self setNeedsDisplay:YES];
}

#pragma mark - Drawing

- (NSString *)titleForState:(AGInstallButtonState)state
{
  switch (state)
    {
      case AGInstallButtonStateGet:
        return NSLocalizedString(@"Get", @"Start the download and install");
      case AGInstallButtonStateWaiting:
        return NSLocalizedString(@"Waiting...", @"Queued behind another install");
      case AGInstallButtonStateDownloading:
        return nil;   /* the progress bar is the label in this state */
      case AGInstallButtonStateOpen:
        return NSLocalizedString(@"Open", @"Launch the installed application");
      case AGInstallButtonStateFailed:
        return NSLocalizedString(@"Failed", @"The install did not finish");
      case AGInstallButtonStateOpenPage:
        return NSLocalizedString(@"Open Page", @"No AppImage here, open the download page");
      case AGInstallButtonStateUnavailable:
        return NSLocalizedString(@"Unavailable", @"Nothing can be installed for this machine");
    }
  return nil;
}

- (NSRect)pillRect
{
  /* Pressed draws the pill 1.5 points tighter: the only press feedback that
   * needs no extra colour and therefore no new literal. */
  CGFloat inset = _pressed ? 2.0 : 0.5;
  NSRect rect = NSInsetRect([self bounds], inset, inset);
  if (NSWidth(rect) < 4.0 || NSHeight(rect) < 4.0)
    return NSZeroRect;
  return rect;
}

- (NSBezierPath *)pillPath
{
  NSRect rect = [self pillRect];
  if (NSIsEmptyRect(rect))
    return [NSBezierPath bezierPath];
  CGFloat radius = NSHeight(rect) / 2.0;
  return [NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius];
}

- (void)drawRect:(NSRect)dirtyRect
{
  (void)dirtyRect;

  NSRect bounds = [self bounds];
  if (NSIsEmptyRect(bounds))
    return;

  NSColor *fill = nil;
  NSColor *stroke = nil;
  NSColor *foreground = nil;

  switch (_state)
    {
      case AGInstallButtonStateGet:
        fill = AGAccentColor();
        foreground = [NSColor whiteColor];
        break;
      case AGInstallButtonStateWaiting:
        fill = [NSColor disabledControlTextColor];
        foreground = [NSColor whiteColor];
        break;
      case AGInstallButtonStateDownloading:
        stroke = [NSColor gridColor];
        break;
      case AGInstallButtonStateOpen:
        stroke = AGAccentColor();
        foreground = AGAccentColor();
        break;
      case AGInstallButtonStateFailed:
        stroke = [NSColor systemRedColor];
        foreground = [NSColor systemRedColor];
        break;
      case AGInstallButtonStateOpenPage:
        stroke = [NSColor gridColor];
        foreground = [NSColor textColor];
        break;
      case AGInstallButtonStateUnavailable:
        foreground = [NSColor disabledControlTextColor];
        break;
    }

  NSBezierPath *pill = [self pillPath];
  if (fill != nil && ![pill isEmpty])
    {
      [fill setFill];
      [pill fill];
    }

  if (_state == AGInstallButtonStateDownloading)
    [self drawProgressInRect:[self pillRect]];

  if (stroke != nil && ![pill isEmpty])
    {
      [stroke setStroke];
      [pill setLineWidth:1.0];
      [pill stroke];
    }

  NSString *title = [self titleForState:_state];
  if (title != nil && foreground != nil)
    {
      NSFont *font = (_style == AGInstallButtonStyleDetail)
          ? METRICS_FONT_SYSTEM_BOLD_13 : METRICS_FONT_SYSTEM_BOLD_11;
      NSDictionary *attributes = @{
        NSFontAttributeName : font,
        NSForegroundColorAttributeName : foreground
      };
      NSSize measured = [title sizeWithAttributes:attributes];
      /* Centre by measurement rather than by a text rect: the maths is the
       * same distance from both edges whether this view reports flipped. */
      NSPoint origin = NSMakePoint(floor((NSWidth(bounds) - measured.width) / 2.0),
                                   floor((NSHeight(bounds) - measured.height) / 2.0));
      [title drawAtPoint:origin withAttributes:attributes];
    }

  if (_state == AGInstallButtonStateDownloading)
    [self drawCancelGlyphInRect:bounds];
}

- (void)drawProgressInRect:(NSRect)rect
{
  NSBezierPath *pill = [self pillPath];
  if ([pill isEmpty] || NSIsEmptyRect(rect))
    return;

  NSGraphicsContext *context = [NSGraphicsContext currentContext];
  [context saveGraphicsState];
  [pill addClip];

  /* The pole's gaps show this colour, so the bar reads as "working" over the
   * button's own interior instead of over whatever is behind it. */
  [[NSColor controlBackgroundColor] setFill];
  NSRectFill(rect);

  float progress = -1.0f;
  AGInstallTask *task = [_installer taskForApp:_app];
  if (task != nil)
    progress = [task progress];

  /* -1 means the phase has no measurable size. The downloader also moves in
   * two coarse steps (0.1 and 0.6), so everything from "not started" through
   * "downloading" through "saving" is animated; only the gaps between those
   * steps are a real percentage. */
  BOOL indeterminate = (progress <= 0.0f) ||
      (progress >= 0.1f && progress <= 0.6f);

  if (indeterminate)
    [self drawBarberPoleInRect:rect];
  else
    {
      double fraction = progress;
      if (fraction > 1.0)
        fraction = 1.0;
      NSRect done = NSMakeRect(NSMinX(rect), NSMinY(rect),
                               NSWidth(rect) * fraction, NSHeight(rect));
      if (!NSIsEmptyRect(done))
        {
          [AGAccentColor() setFill];
          NSRectFill(done);
        }
    }

  [context restoreGraphicsState];
}

- (void)drawBarberPoleInRect:(NSRect)rect
{
  CGFloat height = NSHeight(rect);
  CGFloat top = NSMinY(rect);
  CGFloat bottom = NSMaxY(rect);
  CGFloat limit = NSMaxX(rect) + height;

  NSBezierPath *stripes = [NSBezierPath bezierPath];
  for (CGFloat x = -height - kAGBarberPeriod; x < limit; x += kAGBarberPeriod)
    {
      CGFloat sx = x + _barberPhase;
      [stripes moveToPoint:NSMakePoint(sx, top)];
      [stripes lineToPoint:NSMakePoint(sx + kAGBarberStripe, top)];
      [stripes lineToPoint:NSMakePoint(sx + kAGBarberStripe - height, bottom)];
      [stripes lineToPoint:NSMakePoint(sx - height, bottom)];
      [stripes closePath];
    }
  [AGAccentColor() setFill];
  [stripes fill];
}

- (void)drawCancelGlyphInRect:(NSRect)bounds
{
  NSRect disc = NSMakeRect(NSWidth(bounds) - kAGCancelGutter,
                           (NSHeight(bounds) - 12.0) / 2.0, 12.0, 12.0);
  /* A disc in the button's own interior colour keeps the glyph readable both
   * where the pole has already run and where it has not. */
  [[NSColor controlBackgroundColor] setFill];
  NSRectFill(disc);

  CGFloat cx = NSMidX(disc);
  CGFloat cy = NSMidY(disc);
  CGFloat r = 3.0;
  NSBezierPath *cross = [NSBezierPath bezierPath];
  [cross setLineWidth:1.5];
  [cross setLineCapStyle:NSRoundLineCapStyle];
  [cross moveToPoint:NSMakePoint(cx - r, cy - r)];
  [cross lineToPoint:NSMakePoint(cx + r, cy + r)];
  [cross moveToPoint:NSMakePoint(cx - r, cy + r)];
  [cross lineToPoint:NSMakePoint(cx + r, cy - r)];
  [[NSColor textColor] setStroke];
  [cross stroke];
}

#pragma mark - Interaction

- (BOOL)isClickable
{
  return _state != AGInstallButtonStateUnavailable;
}

- (void)mouseDown:(NSEvent *)event
{
  if (![self isClickable])
    return;

  /* Tracked by hand instead of firing on mouseDown: a drag that starts on the
   * button is a gesture the user meant for the scroller, and only a press
   * held to a release inside the pill is a click. */
  _pressed = YES;
  [self setNeedsDisplay:YES];

  NSEvent *last = event;
  while (last != nil)
    {
      last = [[self window] nextEventMatchingMask:(NSLeftMouseUpMask |
                                                   NSLeftMouseDraggedMask)];
      if (last == nil || [last type] == NSLeftMouseUp)
        break;
      NSPoint point = [self convertPoint:[last locationInWindow] fromView:nil];
      BOOL inside = NSPointInRect(point, [self bounds]);
      if (inside != _pressed)
        {
          _pressed = inside;
          [self setNeedsDisplay:YES];
        }
    }

  BOOL activate = (last != nil) &&
      NSPointInRect([self convertPoint:[last locationInWindow] fromView:nil],
                    [self bounds]);
  _pressed = NO;
  [self setNeedsDisplay:YES];
  if (activate)
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
    details = NSLocalizedString(@"The installation failed.", @"");

  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:NSLocalizedString(@"Installation Failed", @"")];
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
