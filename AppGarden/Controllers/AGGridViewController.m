/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGGridViewController.h"
#import "AGAppGridView.h"

@interface AGGridViewController () <AGAppGridViewDelegate>
@end

@implementation AGGridViewController
{
  AGImageCache *_imageCache;
  AGInstaller *_installer;
  AGAppGridView *_gridView;
}

@synthesize delegate = _delegate;
@synthesize pageTitle = _pageTitle;

- (instancetype)initWithImageCache:(AGImageCache *)imageCache
                         installer:(AGInstaller *)installer
{
  self = [super initWithNibName:nil bundle:nil];
  if (self != nil)
    {
      _imageCache = imageCache;
      _installer = installer;
    }
  return self;
}

- (void)loadView
{
  NSRect frame = NSMakeRect(0.0, 0.0, 800.0, 600.0);
  NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:frame];
  [scrollView setHasVerticalScroller:YES];
  [scrollView setHasHorizontalScroller:NO];
  [scrollView setAutohidesScrollers:YES];
  [scrollView setBorderType:NSNoBorder];
  [scrollView setBackgroundColor:[NSColor windowBackgroundColor]];
  [scrollView setDrawsBackground:YES];
  [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

  _gridView = [[AGAppGridView alloc] initWithFrame:[[scrollView contentView] bounds]
                                        imageCache:_imageCache
                                         installer:_installer];
  [_gridView setDelegate:self];
  [scrollView setDocumentView:_gridView];
  [self setView:scrollView];
}

- (AGAppGridView *)gridView
{
  [self view];
  return _gridView;
}

- (NSArray<AGApp *> *)apps
{
  return [[self gridView] apps];
}

- (void)setApps:(NSArray<AGApp *> *)apps
{
  [[self gridView] setApps:apps];
}

- (BOOL)isLoading
{
  return [[self gridView] isLoading];
}

- (void)setLoading:(BOOL)loading
{
  [[self gridView] setLoading:loading];
}

- (NSString *)emptyMessage
{
  return [[self gridView] emptyMessage];
}

- (void)setEmptyMessage:(NSString *)emptyMessage
{
  [[self gridView] setEmptyMessage:emptyMessage];
}

#pragma mark - AGAppGridViewDelegate

- (void)appGridView:(AGAppGridView *)gridView didSelectApp:(AGApp *)app
{
  (void)gridView;
  [_delegate gridViewController:self didSelectApp:app];
}

@end
