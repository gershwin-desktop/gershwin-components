/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWMainWindowController.h"
#import "SWSelectionRules.h"
#import "SWGitTool.h"
#import "AppearanceMetrics.h"

static const float kWinWidth = 680.0;
static const float kWinHeight = 520.0;
static const float kHeaderHeight = 96.0;
// Must clear the dev-branch checkbox row's own top edge (bottom margin +
// button height + one group gap + the checkbox's own line height), or the
// split view above it draws over the checkbox - see -buildBottomBarIn:.
static const float kBottomBarHeight =
  METRICS_CONTENT_BOTTOM_MARGIN + METRICS_BUTTON_HEIGHT + METRICS_SPACE_16 + METRICS_RADIO_BUTTON_LINE_SPACING;

@interface SWMainWindowController ()
{
  NSArray<SWRepository *> *_repositories; // with updates only, list order
  NSUInteger _upToDateCount;
  BOOL _useDevBranch;

  NSSplitView *_splitView;
  NSTableView *_tableView;
  NSTextView *_detailsCommitsView;
  NSTextField *_detailsNameField;
  NSTextField *_detailsSummaryField;
  NSTextField *_detailsWarningField;

  NSButton *_devBranchCheckbox;
  NSTextField *_summaryField;
  NSButton *_quitButton;
  NSButton *_updateButton;
}
- (void)forceToggleInstallForRow:(NSInteger)row;
@end

// Table view that lets Control-click force the Install checkbox of a row the
// selection rules normally refuse. A disabled checkbox cell - which is what a
// blocked row gets from -tableView:willDisplayCell:... - never tracks and
// never sends its action, so the forced path below would be unreachable from
// the UI for exactly the rows it exists for. Control-click therefore never
// reaches NSTableView's own -mouseDown:, cell tracking and row selection
// included; the controller re-selects the row itself when it toggles.
@interface SWForceToggleTableView : NSTableView
@property (nonatomic, weak) SWMainWindowController *toggleController;
@end

@implementation SWForceToggleTableView

- (void)mouseDown:(NSEvent *)event
{
  if ([event modifierFlags] & NSControlKeyMask) {
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    NSInteger column = [self columnAtPoint:point];
    if (column >= 0 && column < (NSInteger)[[self tableColumns] count]
        && [[[[self tableColumns] objectAtIndex:column] identifier] isEqualToString:@"install"]) {
      NSInteger row = [self rowAtPoint:point];
      if (row >= 0) {
        [_toggleController forceToggleInstallForRow:row];
        return;
      }
    }
  }
  [super mouseDown:event];
}

@end

@implementation SWMainWindowController

@synthesize delegate = _delegate;

- (instancetype)init
{
  NSRect frame = NSMakeRect(0, 0, kWinWidth, kWinHeight);
  NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                             | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
  self = [super initWithWindow:window];
  if (self) {
    [window setTitle:@"Software Update"];
    [window setMinSize:NSMakeSize(kWinWidth, 360.0)];
    [window center];
    [window setReleasedWhenClosed:NO];
    _repositories = @[];
    [self buildContent];
  }
  return self;
}

#pragma mark - Layout

- (void)buildContent
{
  NSView *content = [[self window] contentView];
  [content setAutoresizesSubviews:YES];
  float contentRight = kWinWidth - METRICS_CONTENT_SIDE_MARGIN;

  [self buildHeaderIn:content contentRight:contentRight];
  [self buildBottomBarIn:content contentRight:contentRight];
  [self buildSplitViewIn:content contentRight:contentRight];
}

- (void)buildHeaderIn:(NSView *)content contentRight:(float)contentRight
{
  float top = kWinHeight;

  NSTextField *headline = [[NSTextField alloc] initWithFrame:
    NSMakeRect(METRICS_TEXT_LEFT, top - METRICS_CONTENT_TOP_MARGIN - 20.0,
               contentRight - METRICS_TEXT_LEFT, 20.0)];
  [headline setStringValue:@"Updates are available for your Gershwin system"];
  [headline setFont:METRICS_FONT_SYSTEM_BOLD_13];
  [headline setBezeled:NO];
  [headline setDrawsBackground:NO];
  [headline setEditable:NO];
  [headline setSelectable:NO];
  [headline setAutoresizingMask:NSViewMinYMargin];
  [content addSubview:headline];

  NSTextField *subtitle = [[NSTextField alloc] initWithFrame:
    NSMakeRect(METRICS_TEXT_LEFT, NSMinY([headline frame]) - METRICS_TITLE_MESSAGE_GAP - 16.0,
               contentRight - METRICS_TEXT_LEFT, 16.0)];
  [subtitle setStringValue:@"Review the repositories below, then update the ones you want."];
  [subtitle setFont:METRICS_FONT_SYSTEM_REGULAR_11];
  [subtitle setTextColor:[NSColor disabledControlTextColor]];
  [subtitle setBezeled:NO];
  [subtitle setDrawsBackground:NO];
  [subtitle setEditable:NO];
  [subtitle setSelectable:NO];
  [subtitle setAutoresizingMask:NSViewMinYMargin];
  [content addSubview:subtitle];

  // Centered against the headline+subtitle block's actual vertical span,
  // not a fixed top offset: with two lines of text, METRICS_ICON_TOP alone
  // left the icon sitting visibly lower than the text block's center (the
  // 24pt top-anchor was 9pt short of the text block's own 15pt top-anchor,
  // and the text block is 44pt tall against the icon's 64pt - anchoring both
  // from the same top offset does not center them against each other).
  float textBlockTop = NSMaxY([headline frame]);
  float textBlockBottom = NSMinY([subtitle frame]);
  float iconY = (textBlockTop + textBlockBottom) / 2.0 - METRICS_ICON_SIDE / 2.0;
  NSImageView *icon = [[NSImageView alloc] initWithFrame:
    NSMakeRect(METRICS_ICON_LEFT, iconY, METRICS_ICON_SIDE, METRICS_ICON_SIDE)];
  [icon setImage:[NSImage imageNamed:@"SoftwareUpdate"]];
  [icon setAutoresizingMask:NSViewMinYMargin];
  [content addSubview:icon];
}

- (void)buildBottomBarIn:(NSView *)content contentRight:(float)contentRight
{
  // Checkbox row sits above the button row (button height, then a standard
  // group gap) rather than an arbitrary +24 - the old value left only 4px
  // between the two rows, not one of the standard spacing values.
  float checkboxY = METRICS_CONTENT_BOTTOM_MARGIN + METRICS_BUTTON_HEIGHT + METRICS_SPACE_16;
  _devBranchCheckbox = [[NSButton alloc] initWithFrame:
    NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, checkboxY, 260.0, METRICS_RADIO_BUTTON_LINE_SPACING)];
  [_devBranchCheckbox setButtonType:NSSwitchButton];
  [_devBranchCheckbox setTitle:@"Use Development branch (dev)"];
  [_devBranchCheckbox setTarget:self];
  [_devBranchCheckbox setAction:@selector(devBranchToggled:)];
  [_devBranchCheckbox setAutoresizingMask:NSViewMaxXMargin];
  [content addSubview:_devBranchCheckbox];

  _summaryField = [[NSTextField alloc] initWithFrame:
    NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, METRICS_CONTENT_BOTTOM_MARGIN + 2.0,
               contentRight - METRICS_CONTENT_SIDE_MARGIN, 16.0)];
  [_summaryField setFont:METRICS_FONT_SYSTEM_REGULAR_11];
  [_summaryField setTextColor:[NSColor disabledControlTextColor]];
  [_summaryField setBezeled:NO];
  [_summaryField setDrawsBackground:NO];
  [_summaryField setEditable:NO];
  [_summaryField setSelectable:NO];
  [_summaryField setAutoresizingMask:NSViewWidthSizable];
  [content addSubview:_summaryField];

  _updateButton = [[NSButton alloc] initWithFrame:
    NSMakeRect(contentRight - METRICS_BUTTON_MIN_WIDTH, METRICS_CONTENT_BOTTOM_MARGIN,
               METRICS_BUTTON_MIN_WIDTH, METRICS_BUTTON_HEIGHT)];
  [_updateButton setTitle:@"Update"];
  [_updateButton setTarget:self];
  [_updateButton setAction:@selector(updateClicked:)];
  [_updateButton setKeyEquivalent:@"\r"];
  [_updateButton setAutoresizingMask:(NSViewMinXMargin)];
  [content addSubview:_updateButton];
  [[self window] setDefaultButtonCell:[_updateButton cell]];

  _quitButton = [[NSButton alloc] initWithFrame:
    NSMakeRect(NSMinX([_updateButton frame]) - METRICS_BUTTON_HORIZ_INTERSPACE - METRICS_BUTTON_MIN_WIDTH,
               METRICS_CONTENT_BOTTOM_MARGIN, METRICS_BUTTON_MIN_WIDTH, METRICS_BUTTON_HEIGHT)];
  [_quitButton setTitle:@"Quit"];
  [_quitButton setTarget:self];
  [_quitButton setAction:@selector(quitClicked:)];
  [_quitButton setAutoresizingMask:(NSViewMinXMargin)];
  [content addSubview:_quitButton];

  // The Update button's title grows at runtime ("Update 9 Repositories"), so
  // its initial fixed width above is provisional - -repositionBottomButtons
  // (called once here, and again whenever the title changes) is what
  // actually sizes it, per the sizeToFit + enforced-minimum pattern instead
  // of padding the frame by a guessed, title-independent amount.
  [self repositionBottomButtons];
}

// Resizes _updateButton to fit its current title (never below the standard
// 100pt minimum, always exactly METRICS_BUTTON_HEIGHT tall - sizeToFit can
// return a taller frame), keeping its right edge pinned to the window's
// content edge, then re-anchors _quitButton the standard button gap to its
// left. Called after any title change, since sizeToFit only fits what the
// button already says.
- (void)repositionBottomButtons
{
  float contentRight = NSWidth([[[self window] contentView] bounds]) - METRICS_CONTENT_SIDE_MARGIN;

  [_updateButton sizeToFit];
  NSRect updateFrame = [_updateButton frame];
  updateFrame.size.width = MAX(NSWidth(updateFrame), METRICS_BUTTON_MIN_WIDTH);
  updateFrame.size.height = METRICS_BUTTON_HEIGHT;
  updateFrame.origin = NSMakePoint(contentRight - NSWidth(updateFrame), METRICS_CONTENT_BOTTOM_MARGIN);
  [_updateButton setFrame:updateFrame];

  NSRect quitFrame = [_quitButton frame];
  quitFrame.origin.x = NSMinX(updateFrame) - METRICS_BUTTON_HORIZ_INTERSPACE - METRICS_BUTTON_MIN_WIDTH;
  quitFrame.origin.y = METRICS_CONTENT_BOTTOM_MARGIN;
  quitFrame.size.width = METRICS_BUTTON_MIN_WIDTH;
  quitFrame.size.height = METRICS_BUTTON_HEIGHT;
  [_quitButton setFrame:quitFrame];
}

- (void)buildSplitViewIn:(NSView *)content contentRight:(float)contentRight
{
  float top = kWinHeight - kHeaderHeight;
  float bottom = kBottomBarHeight;
  NSRect splitFrame = NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, bottom,
                                  contentRight - METRICS_CONTENT_SIDE_MARGIN, top - bottom);

  _splitView = [[NSSplitView alloc] initWithFrame:splitFrame];
  [_splitView setVertical:NO]; // stacked top/bottom, horizontal divider
  [_splitView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

  NSScrollView *tableScroll = [[NSScrollView alloc] initWithFrame:
    NSMakeRect(0, 0, NSWidth(splitFrame), NSHeight(splitFrame) * 0.55)];
  [tableScroll setHasVerticalScroller:YES];
  [tableScroll setBorderType:NSBezelBorder];
  [tableScroll setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

  _tableView = [[SWForceToggleTableView alloc] initWithFrame:[[tableScroll contentView] bounds]];
  [(SWForceToggleTableView *)_tableView setToggleController:self];
  [_tableView setDataSource:self];
  [_tableView setDelegate:self];
  [_tableView setUsesAlternatingRowBackgroundColors:YES];
  [_tableView setAllowsMultipleSelection:NO];

  NSTableColumn *installColumn = [[NSTableColumn alloc] initWithIdentifier:@"install"];
  [[installColumn headerCell] setStringValue:@"Install"];
  [installColumn setWidth:50.0];
  NSButtonCell *checkboxCell = [[NSButtonCell alloc] init];
  [checkboxCell setButtonType:NSSwitchButton];
  [checkboxCell setTitle:@""];
  [checkboxCell setTarget:self];
  [checkboxCell setAction:@selector(installCheckboxClicked:)];
  [installColumn setDataCell:checkboxCell];
  [_tableView addTableColumn:installColumn];

  NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
  [[nameColumn headerCell] setStringValue:@"Repository"];
  [nameColumn setWidth:280.0];
  [_tableView addTableColumn:nameColumn];

  NSTableColumn *branchColumn = [[NSTableColumn alloc] initWithIdentifier:@"branch"];
  [[branchColumn headerCell] setStringValue:@"Branch"];
  [branchColumn setWidth:140.0];
  [_tableView addTableColumn:branchColumn];

  NSTableColumn *commitsColumn = [[NSTableColumn alloc] initWithIdentifier:@"commits"];
  [[commitsColumn headerCell] setStringValue:@"Commits"];
  [commitsColumn setWidth:90.0];
  [_tableView addTableColumn:commitsColumn];

  [tableScroll setDocumentView:_tableView];
  [_splitView addSubview:tableScroll];

  NSScrollView *detailsScroll = [[NSScrollView alloc] initWithFrame:
    NSMakeRect(0, 0, NSWidth(splitFrame), NSHeight(splitFrame) * 0.45)];
  [detailsScroll setHasVerticalScroller:YES];
  [detailsScroll setBorderType:NSBezelBorder];
  [detailsScroll setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

  NSView *detailsContainer = [[NSView alloc] initWithFrame:[[detailsScroll contentView] bounds]];
  [self buildDetailsPaneIn:detailsContainer];
  [detailsScroll setDocumentView:detailsContainer];
  [_splitView addSubview:detailsScroll];

  [content addSubview:_splitView];
}

- (void)buildDetailsPaneIn:(NSView *)container
{
  NSRect bounds = [container bounds];
  float width = NSWidth(bounds) - 2 * METRICS_CONTENT_SIDE_MARGIN;

  _detailsNameField = [[NSTextField alloc] initWithFrame:
    NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, NSHeight(bounds) - METRICS_CONTENT_TOP_MARGIN - 18.0, width, 18.0)];
  [_detailsNameField setFont:METRICS_FONT_SYSTEM_BOLD_13];
  [_detailsNameField setBezeled:NO];
  [_detailsNameField setDrawsBackground:NO];
  [_detailsNameField setEditable:NO];
  [_detailsNameField setSelectable:NO];
  [_detailsNameField setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
  [container addSubview:_detailsNameField];

  _detailsSummaryField = [[NSTextField alloc] initWithFrame:
    NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, NSMinY([_detailsNameField frame]) - METRICS_SPACE_8 - 16.0, width, 16.0)];
  [_detailsSummaryField setFont:METRICS_FONT_SYSTEM_REGULAR_11];
  [_detailsSummaryField setTextColor:[NSColor disabledControlTextColor]];
  [_detailsSummaryField setBezeled:NO];
  [_detailsSummaryField setDrawsBackground:NO];
  [_detailsSummaryField setEditable:NO];
  [_detailsSummaryField setSelectable:NO];
  [_detailsSummaryField setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
  [container addSubview:_detailsSummaryField];

  _detailsWarningField = [[NSTextField alloc] initWithFrame:
    NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, NSMinY([_detailsSummaryField frame]) - METRICS_SPACE_8 - 16.0, width, 16.0)];
  [_detailsWarningField setFont:METRICS_FONT_SYSTEM_REGULAR_11];
  [_detailsWarningField setBezeled:NO];
  [_detailsWarningField setDrawsBackground:NO];
  [_detailsWarningField setEditable:NO];
  [_detailsWarningField setSelectable:NO];
  [_detailsWarningField setHidden:YES];
  [_detailsWarningField setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
  [container addSubview:_detailsWarningField];

  // The whole details pane already scrolls as one unit (detailsScroll, in
  // -buildSplitViewIn:), matching the handoff mockup's single plain text box
  // with one scrollbar - nesting a second NSScrollView just for this text
  // view gave the pane two scrollbars fighting each other. NSTextView
  // defaults to vertically resizable with no max height, though, so left
  // alone it grows to fit however many commits are listed and overlaps the
  // name/summary fields above it instead of clipping - confirmed live with
  // 8 commits, which grew the view from its allotted ~74pt up to 125pt.
  // Turning that off keeps it confined to the space computed below; a repo
  // with more commits than fit is something the user sees by dragging the
  // split view's own divider, not a second, nested scrollbar.
  float commitsTop = NSMinY([_detailsWarningField frame]) - METRICS_SPACE_8;
  _detailsCommitsView = [[NSTextView alloc] initWithFrame:
    NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, 0, width, commitsTop)];
  [_detailsCommitsView setVerticallyResizable:NO];
  [_detailsCommitsView setEditable:NO];
  [_detailsCommitsView setSelectable:YES];
  [_detailsCommitsView setDrawsBackground:NO];
  [_detailsCommitsView setFont:METRICS_FONT_SYSTEM_REGULAR_11];
  [_detailsCommitsView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
  [container addSubview:_detailsCommitsView];
}

#pragma mark - Public API

- (void)setRepositories:(NSArray<SWRepository *> *)repositories
           upToDateCount:(NSUInteger)upToDateCount
        useDevelopmentBranch:(BOOL)useDevBranch
{
  _repositories = [repositories copy];
  _upToDateCount = upToDateCount;
  _useDevBranch = useDevBranch;
  [_devBranchCheckbox setState:(useDevBranch ? NSControlStateValueOn : NSControlStateValueOff)];
  [_tableView reloadData];
  [self updateSummaryAndButtonState];
  if ([_repositories count] > 0) {
    [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
  } else {
    [self showDetailsForRepository:nil];
  }
}

#pragma mark - Actions

- (void)devBranchToggled:(id)sender
{
  _useDevBranch = ([_devBranchCheckbox state] == NSControlStateValueOn);
  [[self delegate] mainWindowController:self useDevelopmentBranchDidChange:_useDevBranch];
}

- (void)installCheckboxClicked:(id)sender
{
  [self toggleInstallForRow:[_tableView clickedRow] force:NO];
}

// Entry point from -[SWForceToggleTableView mouseDown:], the Control-click
// override for rows the selection rules refuse.
- (void)forceToggleInstallForRow:(NSInteger)row
{
  if (row < 0 || (NSUInteger)row >= [_repositories count]) return;
  // Mirror a plain click's own row selection, so the details pane shows the
  // warning the user is about to override.
  if ([_tableView selectedRow] != row) {
    [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
            byExtendingSelection:NO];
  }
  [self toggleInstallForRow:row force:YES];
}

- (void)toggleInstallForRow:(NSInteger)row force:(BOOL)force
{
  if (row < 0 || (NSUInteger)row >= [_repositories count]) return;
  SWRepository *repo = [_repositories objectAtIndex:(NSUInteger)row];

  if (![SWSelectionRules canToggleRepository:repo force:force]) {
    // Refused: a plain click on a blocked (build running/failed, unchecked)
    // or pinned row. Put the cell back the way the rules say it must be.
    [_tableView reloadData];
    return;
  }

  [repo setSelected:![repo selected]];

  if ([[repo name] isEqualToString:@"gershwin-developer"]) {
    for (SWRepository *other in _repositories) {
      if ([other isPinned] && [SWSelectionRules blockedReasonForRepository:other] == nil) {
        [other setSelected:[repo selected]];
      }
    }
  }

  [_tableView reloadData];
  [self updateSummaryAndButtonState];
}

- (void)updateClicked:(id)sender
{
  NSMutableArray *selected = [NSMutableArray array];
  for (SWRepository *repo in _repositories) {
    if ([repo selected]) [selected addObject:repo];
  }
  if ([selected count] == 0) return;

  [self presentConfirmationSheetForRepositories:[selected copy]];
}

- (void)presentConfirmationSheetForRepositories:(NSArray<SWRepository *> *)selected
{
  BOOL anyRestart = NO, anyDirty = NO;
  for (SWRepository *repo in selected) {
    if ([repo restartRequired]) anyRestart = YES;
    if ([repo dirty]) anyDirty = YES;
  }

  NSMutableArray *notes = [NSMutableArray array];
  if (anyRestart) {
    [notes addObject:@"Your computer will need to restart to finish this update."];
  }
  if (_useDevBranch) {
    [notes addObject:@"Some repositories will switch to the Development branch."];
  }
  if (anyDirty) {
    [notes addObject:@"Local changes in the affected repositories will be temporarily set aside and restored afterward."];
  }

  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:[NSString stringWithFormat:@"Update %lu %@?",
    (unsigned long)[selected count], [selected count] == 1 ? @"Repository" : @"Repositories"]];
  [alert setInformativeText:[notes count] > 0 ? [notes componentsJoinedByString:@"\n"]
                                              : @"This will download and install the selected updates."];
  [alert addButtonWithTitle:@"Update"];
  [alert addButtonWithTitle:@"Cancel"];

  NSInteger response = [alert runModal];
  if (response == NSAlertFirstButtonReturn) {
    [[self delegate] mainWindowController:self didConfirmUpdateForRepositories:selected];
  }
}

- (void)quitClicked:(id)sender
{
  [[self delegate] mainWindowControllerDidClickQuit:self];
}

#pragma mark - Summary

- (void)updateSummaryAndButtonState
{
  NSUInteger selectedCount = 0;
  for (SWRepository *repo in _repositories) {
    if ([repo selected]) selectedCount++;
  }

  if (selectedCount == 0) {
    [_updateButton setTitle:@"Update"];
    [_updateButton setEnabled:NO];
  } else {
    [_updateButton setTitle:[NSString stringWithFormat:@"Update %lu %@",
      (unsigned long)selectedCount, selectedCount == 1 ? @"Repository" : @"Repositories"]];
    [_updateButton setEnabled:YES];
  }
  [self repositionBottomButtons];

  [_summaryField setStringValue:[NSString stringWithFormat:
    @"%lu of %lu repositories selected · %lu up to date",
    (unsigned long)selectedCount, (unsigned long)[_repositories count],
    (unsigned long)_upToDateCount]];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
  return (NSInteger)[_repositories count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  SWRepository *repo = [_repositories objectAtIndex:(NSUInteger)row];
  NSString *identifier = [column identifier];

  if ([identifier isEqualToString:@"install"]) {
    return @([repo selected]);
  }
  if ([identifier isEqualToString:@"name"]) {
    NSString *reason = [SWSelectionRules blockedReasonForRepository:repo];
    return reason ? [NSString stringWithFormat:@"%@ - %@", [repo name], reason] : [repo name];
  }
  if ([identifier isEqualToString:@"branch"]) {
    return [self branchDisplayStringForRepository:repo];
  }
  if ([identifier isEqualToString:@"commits"]) {
    if ([repo isPinned]) return [repo pinAdvanced] ? @"new" : @"";
    return [NSString stringWithFormat:@"%lu", (unsigned long)[repo commitCount]];
  }
  return nil;
}

- (NSString *)branchDisplayStringForRepository:(SWRepository *)repo
{
  if ([repo isPinned]) {
    NSString *sha = [repo pin];
    return [sha length] >= 7 ? [sha substringToIndex:7] : (sha ?: @"");
  }
  NSString *current = [repo currentBranch] ?: @"";
  NSString *target = [repo targetBranch] ?: current;
  if ([current isEqualToString:target] || [target length] == 0) {
    return current;
  }
  return [NSString stringWithFormat:@"%@ → %@", current, target];
}

- (void)tableView:(NSTableView *)tableView
   willDisplayCell:(id)cell
    forTableColumn:(NSTableColumn *)column
               row:(NSInteger)row
{
  SWRepository *repo = [_repositories objectAtIndex:(NSUInteger)row];
  BOOL blocked = [SWSelectionRules blockedReasonForRepository:repo] != nil;

  if ([[column identifier] isEqualToString:@"install"]) {
    [cell setEnabled:!blocked && ![repo isPinned]];
  } else if ([cell isKindOfClass:[NSCell class]] && [cell respondsToSelector:@selector(setTextColor:)]) {
    [(NSTextFieldCell *)cell setTextColor:blocked ? [NSColor disabledControlTextColor] : [NSColor controlTextColor]];
  }
}

#pragma mark - NSTableViewDelegate

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
  NSInteger row = [_tableView selectedRow];
  [self showDetailsForRepository:(row >= 0 ? [_repositories objectAtIndex:(NSUInteger)row] : nil)];
}

- (void)showDetailsForRepository:(SWRepository *)repo
{
  if (!repo) {
    [_detailsNameField setStringValue:@""];
    [_detailsSummaryField setStringValue:@""];
    [_detailsWarningField setHidden:YES];
    [[_detailsCommitsView textStorage] setAttributedString:[[NSAttributedString alloc] initWithString:@""]];
    return;
  }

  [_detailsNameField setStringValue:[repo name]];

  if ([repo isPinned]) {
    [_detailsSummaryField setStringValue:[NSString stringWithFormat:
      @"Pinned by gershwin-developer to %@", [self branchDisplayStringForRepository:repo]]];
  } else {
    [_detailsSummaryField setStringValue:[NSString stringWithFormat:
      @"origin/%@ · %lu new commit%@", [repo targetBranch] ?: @"",
      (unsigned long)[repo commitCount], [repo commitCount] == 1 ? @"" : @"s"]];
  }

  NSString *reason = [SWSelectionRules blockedReasonForRepository:repo];
  if (reason) {
    [_detailsWarningField setStringValue:[NSString stringWithFormat:@"%@: %@", [repo name], reason]];
    [_detailsWarningField setTextColor:[NSColor redColor]];
    [_detailsWarningField setHidden:NO];
  } else if ([repo dirty]) {
    [_detailsWarningField setStringValue:[NSString stringWithFormat:
      @"%lu modified file%@ will be set aside and restored after updating.",
      (unsigned long)[repo modifiedFileCount], [repo modifiedFileCount] == 1 ? @"" : @"s"]];
    [_detailsWarningField setTextColor:[NSColor colorWithCalibratedRed:0.6 green:0.4 blue:0.0 alpha:1.0]];
    [_detailsWarningField setHidden:NO];
  } else {
    [_detailsWarningField setHidden:YES];
  }

  NSMutableAttributedString *commitsText = [[NSMutableAttributedString alloc] init];
  for (SWGitCommit *commit in [repo commits]) {
    NSDictionary *shaAttrs = @{
      NSFontAttributeName: METRICS_FONT_SYSTEM_REGULAR_11,
      NSForegroundColorAttributeName: [NSColor disabledControlTextColor]
    };
    NSDictionary *textAttrs = @{NSFontAttributeName: METRICS_FONT_SYSTEM_REGULAR_11};
    NSString *line = [NSString stringWithFormat:@"%@  %@  (%@)\n", [commit sha], [commit subject], [commit date]];
    NSAttributedString *shaPart = [[NSAttributedString alloc]
      initWithString:[NSString stringWithFormat:@"%@  ", [commit sha]] attributes:shaAttrs];
    NSAttributedString *restPart = [[NSAttributedString alloc]
      initWithString:[line substringFromIndex:[[commit sha] length] + 2] attributes:textAttrs];
    [commitsText appendAttributedString:shaPart];
    [commitsText appendAttributedString:restPart];
  }
  [[_detailsCommitsView textStorage] setAttributedString:commitsText];
}

@end
