/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWCheckingWindowController.h"
#import "AppearanceMetrics.h"

static const float kWinWidth = METRICS_WIN_MIN_WIDTH;
static const float kWinHeight = 155.0;
static const float kBarHeight = 20.0;
static const float kLineHeight = 20.0;

@interface SWCheckingWindowController ()
{
  NSTextField *_headlineField;
  NSProgressIndicator *_progressBar;
  NSTextField *_statusField;
  NSButton *_stopButton;
  BOOL _stopping;
}
@end

@implementation SWCheckingWindowController

@synthesize delegate = _delegate;

- (instancetype)init
{
  NSRect frame = NSMakeRect(0, 0, kWinWidth, kWinHeight);
  NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
  self = [super initWithWindow:window];
  if (self) {
    [window setTitle:@"Software Update"];
    [window center];
    [window setReleasedWhenClosed:NO];
    [self buildContent];
  }
  return self;
}

- (void)buildContent
{
  NSView *content = [[self window] contentView];
  float contentRight = kWinWidth - METRICS_CONTENT_SIDE_MARGIN;

  // Every other screen in this app has the icon beside its headline (per the
  // handoff mockup); this one was missing it entirely, with text starting at
  // the plain content margin instead of METRICS_TEXT_LEFT.
  _headlineField = [[NSTextField alloc] initWithFrame:
    NSMakeRect(METRICS_TEXT_LEFT, kWinHeight - METRICS_CONTENT_TOP_MARGIN - kLineHeight,
               contentRight - METRICS_TEXT_LEFT, kLineHeight)];
  [_headlineField setStringValue:@"Checking for new commits…"];
  [_headlineField setFont:METRICS_FONT_SYSTEM_BOLD_13];
  [_headlineField setBezeled:NO];
  [_headlineField setDrawsBackground:NO];
  [_headlineField setEditable:NO];
  [_headlineField setSelectable:NO];
  [content addSubview:_headlineField];

  float progressY = NSMinY([_headlineField frame]) - METRICS_SPACE_16 - kBarHeight;
  _progressBar = [[NSProgressIndicator alloc] initWithFrame:
    NSMakeRect(METRICS_TEXT_LEFT, progressY,
               contentRight - METRICS_TEXT_LEFT, kBarHeight)];
  [_progressBar setStyle:NSProgressIndicatorStyleBar];
  [_progressBar setIndeterminate:YES];
  [_progressBar setControlSize:NSControlSizeRegular];
  [content addSubview:_progressBar];
  [_progressBar startAnimation:nil];

  float statusY = progressY - METRICS_SPACE_8 - kLineHeight;
  _statusField = [[NSTextField alloc] initWithFrame:
    NSMakeRect(METRICS_TEXT_LEFT, statusY,
               contentRight - METRICS_TEXT_LEFT, kLineHeight)];
  [_statusField setStringValue:@"Contacting gershwin-desktop…"];
  [_statusField setFont:METRICS_FONT_SYSTEM_REGULAR_11];
  [_statusField setTextColor:[NSColor disabledControlTextColor]];
  [_statusField setBezeled:NO];
  [_statusField setDrawsBackground:NO];
  [_statusField setEditable:NO];
  [_statusField setSelectable:NO];
  [content addSubview:_statusField];

  // Centered against the headline-to-status text block's span, matching the
  // same fix (and rationale) applied to every other icon+text screen in this
  // app - see -buildHeaderIn:contentRight: in SWMainWindowController.m.
  float textBlockTop = NSMaxY([_headlineField frame]);
  float textBlockBottom = NSMinY([_statusField frame]);
  float iconY = (textBlockTop + textBlockBottom) / 2.0 - METRICS_ICON_SIDE / 2.0;
  NSImageView *icon = [[NSImageView alloc] initWithFrame:
    NSMakeRect(METRICS_ICON_LEFT, iconY, METRICS_ICON_SIDE, METRICS_ICON_SIDE)];
  [icon setImage:[NSImage imageNamed:@"SoftwareUpdate"]];
  [content addSubview:icon];

  _stopButton = [[NSButton alloc] initWithFrame:
    NSMakeRect(contentRight - METRICS_BUTTON_MIN_WIDTH, METRICS_CONTENT_BOTTOM_MARGIN,
               METRICS_BUTTON_MIN_WIDTH, METRICS_BUTTON_HEIGHT)];
  [_stopButton setTitle:@"Stop"];
  [_stopButton setTarget:self];
  [_stopButton setAction:@selector(stopClicked:)];
  [_stopButton setKeyEquivalent:@"\033"];
  [content addSubview:_stopButton];
}

- (void)setStatusRepositoryName:(NSString *)name index:(NSUInteger)index total:(NSUInteger)total
{
  // Repositories already in flight when Stop was clicked keep reporting
  // progress for the few seconds it takes them to finish - without this
  // guard, one of those callbacks overwrites "Stopping..." with a fresh
  // "Fetching ..." line, and the button looks like it did nothing.
  if (_stopping) return;
  [_statusField setStringValue:[NSString stringWithFormat:
    @"Fetching %@ from origin (%lu of %lu)", name,
    (unsigned long)index, (unsigned long)total]];
}

- (void)stopClicked:(id)sender
{
  // Nothing here can cancel a git fetch already in flight, so give
  // immediate feedback instead of leaving the button looking unresponsive
  // for however long the last handful of already-started fetches take to
  // finish - clicking Stop was silently doing nothing but taking effect
  // late, exactly as if the app had hung.
  _stopping = YES;
  [_stopButton setEnabled:NO];
  [_statusField setStringValue:@"Stopping…"];
  [[self delegate] checkingWindowControllerDidClickStop:self];
}

@end
