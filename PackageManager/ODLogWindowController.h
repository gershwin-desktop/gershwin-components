/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Shared log window used by OnDemand.app and Software Update: a read-only,
 * auto-scrolling text view for showing command lines and their output.
 */

#import <AppKit/AppKit.h>

@interface ODLogWindowController : NSWindowController
{
  NSScrollView *_scrollView;
  NSTextView *_logView;
  NSFont *_logFont;
  NSFileHandle *_logFileHandle;
}

/// Font used for appended text. Defaults to a fixed-pitch font, matching
/// OnDemand's original log window; callers that must not show a monospaced
/// font (Software Update) set this before the first -appendLog:.
@property (nonatomic, strong) NSFont *logFont;

/// Optional. When set, every -appendLog: line is also written to this file
/// (truncated when the path is set, then appended to as the run proceeds) -
/// so the run's output survives the user closing the app before reading the
/// on-screen log window, or asking for help after the fact. nil (default)
/// disables file logging entirely.
@property (nonatomic, copy) NSString *logFilePath;

- (instancetype)initWithTitle:(NSString *)title;

- (void)appendLog:(NSString *)text;
- (void)clearLog;

@end
