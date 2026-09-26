/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWCompletionWindowController.h"
#import "AppearanceMetrics.h"

@implementation SWCompletionResultRow
@end

static const float kWinWidth = METRICS_WIN_MIN_WIDTH;
static const float kWinHeight = 380.0;
// Must clear the icon's own footprint (METRICS_ICON_TOP + METRICS_ICON_SIDE
// = 88) or the table view below it draws over the icon's bottom edge - this
// was 70, 18px short, and visibly cut into the icon. Matches
// SWMainWindowController's header, which uses the same icon at the same
// offset from the top and already gets this right.
static const float kHeaderHeight = 96.0;
static const float kBottomBarHeight = 60.0;

@interface SWCompletionWindowController ()
{
  NSArray<SWCompletionResultRow *> *_results;
  NSTableView *_tableView;
  NSButton *_primaryButton;   // Restart, or Quit when nothing needs a restart
  NSButton *_secondaryButton; // Later, hidden when nothing needs a restart
  NSTextField *_headlineField;
  BOOL _needsRestart;
}
@end

@implementation SWCompletionWindowController

@synthesize delegate = _delegate;

- (instancetype)init
{
  NSRect frame = NSMakeRect(0, 0, kWinWidth, kWinHeight);
  NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                             | NSWindowStyleMaskResizable)
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
  self = [super initWithWindow:window];
  if (self) {
    [window setTitle:@"Software Update"];
    [window setMinSize:NSMakeSize(kWinWidth, 260.0)];
    [window center];
    [window setReleasedWhenClosed:NO];
    _results = @[];
    [self buildContent];
  }
  return self;
}

- (void)buildContent
{
  NSView *content = [[self window] contentView];
  float contentRight = kWinWidth - METRICS_CONTENT_SIDE_MARGIN;

  _headlineField = [[NSTextField alloc] initWithFrame:
    NSMakeRect(METRICS_TEXT_LEFT, kWinHeight - METRICS_CONTENT_TOP_MARGIN - 40.0,
               contentRight - METRICS_TEXT_LEFT, 40.0)];
  [_headlineField setStringValue:@"Installation complete."];
  [_headlineField setFont:METRICS_FONT_SYSTEM_BOLD_13];
  [[_headlineField cell] setWraps:YES];
  [_headlineField setBezeled:NO];
  [_headlineField setDrawsBackground:NO];
  [_headlineField setEditable:NO];
  [_headlineField setSelectable:NO];
  [_headlineField setAutoresizingMask:NSViewMinYMargin];
  [content addSubview:_headlineField];

  // Centered against the headline field's own span (up to two lines: the
  // plain "Installation complete." case and the "...you must restart..."
  // case), not a fixed top offset - see the identical fix and rationale in
  // SWMainWindowController's -buildHeaderIn:contentRight:.
  NSImageView *icon = [[NSImageView alloc] initWithFrame:
    NSMakeRect(METRICS_ICON_LEFT, NSMidY([_headlineField frame]) - METRICS_ICON_SIDE / 2.0,
               METRICS_ICON_SIDE, METRICS_ICON_SIDE)];
  [icon setImage:[NSImage imageNamed:@"SoftwareUpdate"]];
  [icon setAutoresizingMask:NSViewMinYMargin];
  [content addSubview:icon];

  NSRect tableFrame = NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, kBottomBarHeight,
                                  contentRight - METRICS_CONTENT_SIDE_MARGIN,
                                  kWinHeight - kHeaderHeight - kBottomBarHeight);
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:tableFrame];
  [scroll setHasVerticalScroller:YES];
  [scroll setBorderType:NSBezelBorder];
  [scroll setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

  _tableView = [[NSTableView alloc] initWithFrame:[[scroll contentView] bounds]];
  [_tableView setDataSource:self];
  [_tableView setDelegate:self];
  [_tableView setUsesAlternatingRowBackgroundColors:YES];
  [_tableView setHeaderView:nil];
  [_tableView setAllowsMultipleSelection:NO];

  NSTableColumn *iconColumn = [[NSTableColumn alloc] initWithIdentifier:@"icon"];
  [iconColumn setWidth:24.0];
  [iconColumn setEditable:NO];
  NSImageCell *imageCell = [[NSImageCell alloc] init];
  [iconColumn setDataCell:imageCell];
  [_tableView addTableColumn:iconColumn];

  NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
  [nameColumn setWidth:200.0];
  [_tableView addTableColumn:nameColumn];

  NSTableColumn *noteColumn = [[NSTableColumn alloc] initWithIdentifier:@"note"];
  [noteColumn setWidth:200.0];
  [_tableView addTableColumn:noteColumn];

  [scroll setDocumentView:_tableView];
  [content addSubview:scroll];

  _primaryButton = [[NSButton alloc] initWithFrame:
    NSMakeRect(contentRight - METRICS_BUTTON_MIN_WIDTH, METRICS_CONTENT_BOTTOM_MARGIN,
               METRICS_BUTTON_MIN_WIDTH, METRICS_BUTTON_HEIGHT)];
  [_primaryButton setTitle:@"Quit"];
  [_primaryButton setTarget:self];
  [_primaryButton setAction:@selector(primaryClicked:)];
  [_primaryButton setKeyEquivalent:@"\r"];
  [_primaryButton setAutoresizingMask:NSViewMinXMargin];
  [content addSubview:_primaryButton];
  [[self window] setDefaultButtonCell:[_primaryButton cell]];

  _secondaryButton = [[NSButton alloc] initWithFrame:
    NSMakeRect(NSMinX([_primaryButton frame]) - METRICS_BUTTON_HORIZ_INTERSPACE - METRICS_BUTTON_MIN_WIDTH,
               METRICS_CONTENT_BOTTOM_MARGIN, METRICS_BUTTON_MIN_WIDTH, METRICS_BUTTON_HEIGHT)];
  [_secondaryButton setTitle:@"Later"];
  [_secondaryButton setTarget:self];
  [_secondaryButton setAction:@selector(secondaryClicked:)];
  [_secondaryButton setHidden:YES];
  [_secondaryButton setAutoresizingMask:NSViewMinXMargin];
  [content addSubview:_secondaryButton];
}

- (void)setResults:(NSArray<SWCompletionResultRow *> *)results
{
  _results = [results copy];
  _needsRestart = NO;
  for (SWCompletionResultRow *row in _results) {
    if ([row restartRequired] && [row outcome] == SWRepositoryUpdateOutcomeUpdated) {
      _needsRestart = YES;
    }
  }

  if (_needsRestart) {
    [_headlineField setStringValue:@"Installation complete. You must restart your computer to finish updating."];
    [_primaryButton setTitle:@"Restart"];
    [_secondaryButton setHidden:NO];
  } else {
    [_headlineField setStringValue:@"Installation complete."];
    [_primaryButton setTitle:@"Quit"];
    [_secondaryButton setHidden:YES];
  }

  [_tableView reloadData];
}

#pragma mark - Row display helpers

- (NSString *)noteForOutcome:(SWRepositoryUpdateOutcome)outcome
{
  switch (outcome) {
    case SWRepositoryUpdateOutcomeUpdated: return @"";
    case SWRepositoryUpdateOutcomeStashKept: return @"local changes kept in stash";
    case SWRepositoryUpdateOutcomeDiverged: return @"diverged, not updated";
    case SWRepositoryUpdateOutcomeBuildFailed: return @"build failed";
    case SWRepositoryUpdateOutcomeInstallFailed: return @"install failed";
    default: return @"";
  }
}

- (NSImage *)iconForOutcome:(SWRepositoryUpdateOutcome)outcome
{
  switch (outcome) {
    case SWRepositoryUpdateOutcomeUpdated: return [NSImage imageNamed:@"StatusDone"];
    case SWRepositoryUpdateOutcomeStashKept: return [NSImage imageNamed:@"StatusWarning"];
    case SWRepositoryUpdateOutcomeDiverged: return [NSImage imageNamed:@"StatusSkipped"];
    case SWRepositoryUpdateOutcomeBuildFailed:
    case SWRepositoryUpdateOutcomeInstallFailed:
    default: return [NSImage imageNamed:@"Caution"];
  }
}

#pragma mark - Actions

- (void)primaryClicked:(id)sender
{
  if (_needsRestart) {
    [[self delegate] completionWindowControllerDidClickRestart:self];
  } else {
    [[self delegate] completionWindowControllerDidClickLaterOrQuit:self];
  }
}

- (void)secondaryClicked:(id)sender
{
  [[self delegate] completionWindowControllerDidClickLaterOrQuit:self];
}

#pragma mark - NSTableViewDataSource / Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
  return (NSInteger)[_results count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  SWCompletionResultRow *result = _results[(NSUInteger)row];
  NSString *identifier = [column identifier];
  if ([identifier isEqualToString:@"icon"]) return [self iconForOutcome:[result outcome]];
  if ([identifier isEqualToString:@"name"]) return [result repositoryName];
  if ([identifier isEqualToString:@"note"]) return [self noteForOutcome:[result outcome]];
  return nil;
}

@end
