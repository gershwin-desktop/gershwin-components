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

  _headlineField = [[NSTextField alloc] initWithFrame:
    NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, kWinHeight - METRICS_CONTENT_TOP_MARGIN - kLineHeight,
               contentRight - METRICS_CONTENT_SIDE_MARGIN, kLineHeight)];
  [_headlineField setStringValue:@"Checking for updates…"];
  [_headlineField setFont:METRICS_FONT_SYSTEM_BOLD_13];
  [_headlineField setBezeled:NO];
  [_headlineField setDrawsBackground:NO];
  [_headlineField setEditable:NO];
  [_headlineField setSelectable:NO];
  [content addSubview:_headlineField];

  float progressY = NSMinY([_headlineField frame]) - METRICS_SPACE_16 - kBarHeight;
  _progressBar = [[NSProgressIndicator alloc] initWithFrame:
    NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, progressY,
               contentRight - METRICS_CONTENT_SIDE_MARGIN, kBarHeight)];
  [_progressBar setStyle:NSProgressIndicatorStyleBar];
  [_progressBar setIndeterminate:YES];
  [_progressBar setControlSize:NSControlSizeRegular];
  [content addSubview:_progressBar];
  [_progressBar startAnimation:nil];

  float statusY = progressY - METRICS_SPACE_8 - kLineHeight;
  _statusField = [[NSTextField alloc] initWithFrame:
    NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, statusY,
               contentRight - METRICS_CONTENT_SIDE_MARGIN, kLineHeight)];
  [_statusField setStringValue:@"Contacting gershwin-desktop…"];
  [_statusField setFont:METRICS_FONT_SYSTEM_REGULAR_11];
  [_statusField setTextColor:[NSColor disabledControlTextColor]];
  [_statusField setBezeled:NO];
  [_statusField setDrawsBackground:NO];
  [_statusField setEditable:NO];
  [_statusField setSelectable:NO];
  [content addSubview:_statusField];

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
  [_statusField setStringValue:[NSString stringWithFormat:
    @"Fetching %@ from origin (%lu of %lu)", name,
    (unsigned long)index, (unsigned long)total]];
}

- (void)stopClicked:(id)sender
{
  [[self delegate] checkingWindowControllerDidClickStop:self];
}

@end
