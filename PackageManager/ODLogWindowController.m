/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ODLogWindowController.h"

@implementation ODLogWindowController

@synthesize logFont = _logFont;
@synthesize logFilePath = _logFilePath;

- (instancetype)init
{
  return [self initWithTitle:@"Installer Log"];
}

- (instancetype)initWithTitle:(NSString *)title
{
  NSRect screenFrame = [[NSScreen mainScreen] frame];
  CGFloat logHeight = screenFrame.size.height / 4.0;
  NSRect logFrame = NSMakeRect(screenFrame.origin.x,
                                screenFrame.origin.y,
                                screenFrame.size.width,
                                logHeight);
  NSWindow *logWindow = [[NSWindow alloc]
    initWithContentRect:logFrame
              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                       | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                backing:NSBackingStoreBuffered
                  defer:YES];
  [logWindow setTitle:title];
  [logWindow setMinSize:NSMakeSize(400, 100)];

  self = [super initWithWindow:logWindow];
  if (self)
    {
      _logFont = [NSFont userFixedPitchFontOfSize:10];

      NSView *contentView = [logWindow contentView];
      NSRect frame = [contentView bounds];

      _scrollView = [[NSScrollView alloc] initWithFrame:frame];
      [_scrollView setHasVerticalScroller:YES];
      [_scrollView setHasHorizontalScroller:NO];
      [_scrollView setBorderType:NSNoBorder];
      [_scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

      NSSize contentSize = [_scrollView contentSize];
      _logView = [[NSTextView alloc]
        initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)];
      [_logView setMinSize:NSMakeSize(0.0, contentSize.height)];
      [_logView setMaxSize:NSMakeSize(FLT_MAX, FLT_MAX)];
      [_logView setVerticallyResizable:YES];
      [_logView setHorizontallyResizable:NO];
      [_logView setEditable:NO];
      [_logView setSelectable:YES];
      [_logView setFont:_logFont];
      [_logView setTextColor:[NSColor darkGrayColor]];
      [_logView setBackgroundColor:[NSColor whiteColor]];
      [[_logView textContainer] setContainerSize:NSMakeSize(contentSize.width, FLT_MAX)];
      [[_logView textContainer] setWidthTracksTextView:YES];

      [_scrollView setDocumentView:_logView];
      [contentView addSubview:_scrollView];
    }
  return self;
}

- (void)appendLog:(NSString *)text
{
  if (!text || !_logView) return;

  // Auto-scroll only if the view was already scrolled to the bottom, so a
  // user who scrolled up to read earlier output is not yanked back down.
  NSScrollView *enclosing = [_logView enclosingScrollView];
  NSRect visible = [enclosing documentVisibleRect];
  NSRect docBounds = [[enclosing documentView] bounds];
  BOOL wasAtBottom = (NSMaxY(visible) >= NSMaxY(docBounds) - 1.0);

  NSDictionary *attrs = @{
    NSFontAttributeName: _logFont,
    NSForegroundColorAttributeName: [NSColor darkGrayColor]
  };
  NSAttributedString *astr = [[NSAttributedString alloc] initWithString:text
                                                             attributes:attrs];
  [[_logView textStorage] appendAttributedString:astr];

  if (wasAtBottom)
    [_logView scrollRangeToVisible:NSMakeRange([[_logView string] length], 0)];

  if (_logFileHandle) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (data) [_logFileHandle writeData:data];
  }
}

- (void)setLogFilePath:(NSString *)logFilePath
{
  if ([_logFilePath isEqualToString:logFilePath]) return;

  [_logFileHandle closeFile];
  _logFileHandle = nil;
  _logFilePath = [logFilePath copy];
  if (![_logFilePath length]) return;

  // Append, never truncate: a caller sets this once per launch (so a run
  // that fails, or hits something the user needs to ask about, is still
  // there after the app is closed and reopened - truncating here erased
  // exactly the run someone would come back to look at).
  if (![[NSFileManager defaultManager] fileExistsAtPath:_logFilePath]) {
    [[NSFileManager defaultManager] createFileAtPath:_logFilePath contents:nil attributes:nil];
  }
  _logFileHandle = [NSFileHandle fileHandleForWritingAtPath:_logFilePath];
  [_logFileHandle seekToEndOfFile];
  NSData *marker = [[NSString stringWithFormat:@"\n----- %@ -----\n", [NSDate date]]
    dataUsingEncoding:NSUTF8StringEncoding];
  if (marker) [_logFileHandle writeData:marker];
}

- (void)clearLog
{
  if (!_logView) return;
  [[_logView textStorage] replaceCharactersInRange:
    NSMakeRange(0, [[_logView string] length]) withString:@""];
}

- (void)setLogFont:(NSFont *)logFont
{
  _logFont = logFont ?: [NSFont userFixedPitchFontOfSize:10];
  [_logView setFont:_logFont];
}

@end
