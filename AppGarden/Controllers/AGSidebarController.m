/*
 * Copyright (c) 2026 Simon Peter / SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGSidebarController.h"
#import "AGSourceListCell.h"
#import "AGCategoryNames.h"
#import "AGCatalog.h"
#import "AppearanceMetrics.h"

/* One source list row.  The cell renders the drawing, this carries what it
   draws: a section header, a spacer, or a selectable scope with a count. */
@interface AGSidebarRow : NSObject
@property (nonatomic, assign) BOOL isHeader;
@property (nonatomic, assign) BOOL isSpacer;
@property (nonatomic, assign) AGSidebarSection section;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *rawCategory;
@property (nonatomic, copy) NSString *countText;
@property (nonatomic, copy) NSString *iconName;
@end

/* Which glyph a scope row shows. The catalog's categories are open-ended,
   so anything without a glyph of its own takes the generic one. */
static NSString *AGSidebarIconNameForCategory(NSString *rawCategory)
{
  static NSDictionary *names = nil;
  if (names == nil)
    names = @{ @"Utility" : @"utility", @"Development" : @"development",
               @"Office" : @"office", @"Graphics" : @"graphics",
               @"AudioVideo" : @"audiovideo", @"Audio" : @"audio",
               @"Video" : @"video", @"Music" : @"music",
               @"Network" : @"network", @"Chat" : @"chat",
               @"Game" : @"game", @"Education" : @"education",
               @"Science" : @"science", @"Finance" : @"finance",
               @"System" : @"system", @"Settings" : @"system",
               @"News" : @"news", @"Engineering" : @"engineering",
               @"TerminalEmulator" : @"terminal", @"Emulator" : @"emulator",
               @"VideoConference" : @"videoconference",
               @"HamRadio" : @"hamradio", @"Electronics" : @"electronics",
               @"WordProcessor" : @"wordprocessor", @"Astronomy" : @"astronomy",
               @"AdventureGame" : @"game", @"StrategyGame" : @"game",
               @"ArtificialIntelligence" : @"ai", @"Database" : @"database",
               @"IDE" : @"development", @"WebDevelopment" : @"development",
               @"InstantMessaging" : @"chat", @"Photography" : @"photography",
               @"ProjectManagement" : @"office", @"Sequencer" : @"music",
               @"TextEditor" : @"texteditor", @"Viewer" : @"viewer",
               @"X-Tool" : @"utility", @"X-Utilities" : @"utility",
               @"Qt" : @"generic", @"GTK" : @"generic", @"GNOME" : @"generic",
               @"KDE" : @"generic", @"Application" : @"generic" };
  NSString *name = (rawCategory != nil) ? [names objectForKey:rawCategory] : nil;
  return (name != nil) ? name : @"generic";
}

static NSImage *AGSidebarIcon(NSString *name)
{
  static NSMutableDictionary *icons = nil;
  if (icons == nil)
    icons = [[NSMutableDictionary alloc] init];
  NSImage *icon = [icons objectForKey:name];
  if (icon == nil)
    {
      NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"tiff"];
      icon = [[NSImage alloc] initWithContentsOfFile:path];
      NSCAssert(icon != nil, @"sidebar glyph %@ missing from the bundle", name);
      [icon setSize:NSMakeSize([AGSourceListCell iconSide], [AGSourceListCell iconSide])];
      [icons setObject:icon forKey:name];
    }
  return icon;
}

@implementation AGSidebarRow
@end

@interface AGSidebarController ()
- (CGFloat)heightForRowAtIndex:(NSInteger)index;
@end

/* The spacer between the two Library rows and the categories only works if the
   table asks for each row's height, and this stack's NSTableView ignores
   -tableView:heightOfRow: because its row height is uniform unless the two
   private hooks below say otherwise - the same pair NSOutlineView overrides.
   The heights stay next to the row model instead of being guessed from the
   cell again. */
@interface AGSidebarTableView : NSTableView
@property (nonatomic, weak) AGSidebarController *sidebar;
@end

@implementation AGSidebarTableView

- (BOOL)_usesVariableRowHeights
{
  return YES;
}

- (CGFloat)_rowHeightForRow:(NSInteger)rowIndex
{
  return [_sidebar heightForRowAtIndex:rowIndex];
}

@end

@implementation AGSidebarController
{
  NSTableView *_tableView;
  NSScrollView *_scrollView;
  NSArray *_rows;
  BOOL _programmaticSelection;
  AGSidebarSection _selectedSection;
  NSString *_selectedRawCategory;
}

@synthesize target = _target;
@synthesize action = _action;

- (id)init
{
  self = [super init];
  if (self != nil)
    {
      _selectedSection = AGSidebarSectionDiscover;
      _rows = [[NSArray alloc] init];
      [self buildView];
      [self buildRowsWithCatalog:nil showToolkitCategories:YES];
    }
  return self;
}

- (void)buildView
{
  AGSidebarTableView *table = [[AGSidebarTableView alloc] initWithFrame:NSMakeRect(0, 0, 200, 600)];
  [table setSidebar:self];
  _tableView = table;
  [_tableView setGridStyleMask:NSTableViewGridNone];
  [_tableView setIntercellSpacing:NSMakeSize(0, 0)];
  [_tableView setRowHeight:[AGSourceListCell rowHeight]];
  [_tableView setHeaderView:nil];
  [_tableView setAllowsMultipleSelection:NO];
  [_tableView setDataSource:self];
  [_tableView setDelegate:self];

  NSTableColumn *column =
    [[NSTableColumn alloc] initWithIdentifier:@"scope"];
  [column setWidth:200];
  /* One uniform column so rows keep the full list width while the split view
     pins the sidebar: the cell positions its own text and count. */
  [column setResizingMask:NSTableColumnAutoresizingMask];
  /* One cell for the whole column; the row kind, count and glyph are set
   * per row in -tableView:willDisplayCell:forTableColumn:row:, the hook
   * this table view consults (it never asks for a data cell per row). */
  [column setDataCell:[[AGSourceListCell alloc] initTextCell:@""]];
  [_tableView addTableColumn:column];
  [_tableView setColumnAutoresizingStyle:NSTableViewUniformColumnAutoresizingStyle];

  _scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 200, 600)];
  [_scrollView setBorderType:NSNoBorder];
  [_scrollView setHasVerticalScroller:YES];
  [_scrollView setAutohidesScrollers:YES];
  [_scrollView setDrawsBackground:YES];
  [_scrollView setDocumentView:_tableView];
}

- (NSView *)view
{
  return _scrollView;
}

- (AGSidebarSection)selectedSection
{
  return _selectedSection;
}

- (NSString *)selectedRawCategory
{
  return _selectedRawCategory;
}

#pragma mark - Row building

- (void)addHeader:(NSString *)title into:(NSMutableArray *)rows
{
  AGSidebarRow *row = [[AGSidebarRow alloc] init];
  row.isHeader = YES;
  row.title = title;
  [rows addObject:row];
}

- (void)addSection:(AGSidebarSection)section
             title:(NSString *)title
      rawCategory:(NSString *)rawCategory
             count:(NSInteger)count
              into:(NSMutableArray *)rows
{
  AGSidebarRow *row = [[AGSidebarRow alloc] init];
  row.section = section;
  row.title = title;
  row.rawCategory = rawCategory;
  switch (section)
    {
      case AGSidebarSectionDiscover: row.iconName = @"discover"; break;
      case AGSidebarSectionInstalled: row.iconName = @"downloaded"; break;
      case AGSidebarSectionCategory: row.iconName = AGSidebarIconNameForCategory(rawCategory); break;
    }
  if (count >= 0)
    row.countText = [NSString stringWithFormat:@"%ld", (long)count];
  [rows addObject:row];
}

- (void)buildRowsWithCatalog:(AGCatalog *)catalog
        showToolkitCategories:(BOOL)showToolkitCategories
{
  NSMutableArray *rows = [[NSMutableArray alloc] init];

  NSArray *rawCategories = nil;
  if (catalog != nil)
    rawCategories = [catalog categories];

  if (rawCategories != nil && [rawCategories count] > 0)
    {
      /* Grouped layout: headers plus a spacer make the two scopes read as a
         library rather than as another category. */
      [self addHeader:NSLocalizedString(@"Library", @"") into:rows];
      [self addSection:AGSidebarSectionDiscover
                 title:NSLocalizedString(@"Discover", @"")
          rawCategory:nil
                 count:-1
                  into:rows];
      [self addSection:AGSidebarSectionInstalled
                 title:NSLocalizedString(@"Downloaded", @"")
          rawCategory:nil
                 count:-1
                  into:rows];

      AGSidebarRow *spacer = [[AGSidebarRow alloc] init];
      spacer.isSpacer = YES;
      [rows addObject:spacer];

      [self addHeader:NSLocalizedString(@"Categories", @"") into:rows];

      NSArray *sorted = [AGCategoryNames sortedRawCategories:rawCategories];
      for (NSString *raw in sorted)
        {
          if ([AGCategoryNames isHiddenCategory:raw] && !showToolkitCategories)
            continue;
          [self addSection:AGSidebarSectionCategory
                     title:[AGCategoryNames displayNameForCategory:raw]
              rawCategory:raw
                     count:(NSInteger)[[catalog appsInCategory:raw] count]
                      into:rows];
        }
    }
  else
    {
      /* No catalog yet: show only the two scopes, so the list is never empty
         and selection always has a home. */
      [self addSection:AGSidebarSectionDiscover
                 title:NSLocalizedString(@"Discover", @"")
          rawCategory:nil
                 count:-1
                  into:rows];
      [self addSection:AGSidebarSectionInstalled
                 title:NSLocalizedString(@"Downloaded", @"")
          rawCategory:nil
                 count:-1
                  into:rows];
    }

  _rows = rows;
}

- (void)reloadWithCatalog:(AGCatalog *)catalog
     showToolkitCategories:(BOOL)showToolkitCategories
{
  [self buildRowsWithCatalog:catalog
        showToolkitCategories:showToolkitCategories];
  [_tableView reloadData];

  if (![self selectSection:_selectedSection rawCategory:_selectedRawCategory])
    [self selectSection:AGSidebarSectionDiscover rawCategory:nil];
}

#pragma mark - Selection

- (NSInteger)rowIndexForSection:(AGSidebarSection)section
                    rawCategory:(NSString *)rawCategory
{
  NSInteger index = 0;
  for (AGSidebarRow *row in _rows)
    {
      if (!row.isHeader && !row.isSpacer && row.section == section)
        {
          if (section != AGSidebarSectionCategory
              || (rawCategory != nil
                  && [row.rawCategory isEqualToString:rawCategory]))
            return index;
        }
      index++;
    }
  return -1;
}

- (BOOL)selectSection:(AGSidebarSection)section rawCategory:(NSString *)rawCategory
{
  NSInteger index = [self rowIndexForSection:section rawCategory:rawCategory];
  if (index < 0)
    return NO;

  _programmaticSelection = YES;
  [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)index]
          byExtendingSelection:NO];
  [_tableView scrollRowToVisible:index];
  _programmaticSelection = NO;

  _selectedSection = section;
  _selectedRawCategory = [rawCategory copy];
  return YES;
}

/* Records what the user clicked and forwards it to the target.  The guard
   keeps -selectSection: from re-sending the action it just applied. */
- (void)userSelectedRow:(NSInteger)index
{
  if (index < 0 || index >= (NSInteger)[_rows count])
    return;
  AGSidebarRow *row = _rows[(NSUInteger)index];
  if (row.isHeader || row.isSpacer)
    return;

  _selectedSection = row.section;
  _selectedRawCategory = [row.rawCategory copy];

  if (_target != nil && _action != NULL)
    [NSApp sendAction:_action to:_target from:self];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
  (void)tableView;
  return (NSInteger)[_rows count];
}

- (id)tableView:(NSTableView *)tableView
objectValueForTableColumn:(NSTableColumn *)tableColumn
            row:(NSInteger)row
{
  (void)tableView;
  (void)tableColumn;
  if (row < 0 || row >= (NSInteger)[_rows count])
    return nil;
  return [_rows[(NSUInteger)row] title];
}

#pragma mark - NSTableViewDelegate

- (CGFloat)heightForRowAtIndex:(NSInteger)index
{
  if (index < 0 || index >= (NSInteger)[_rows count])
    return [AGSourceListCell rowHeight];
  AGSidebarRow *rowObject = _rows[(NSUInteger)index];
  if (rowObject.isSpacer)
    return [AGSourceListCell spacerRowHeight];
  return [AGSourceListCell rowHeight];
}

/* Kept as well for stacks that do consult the delegate; this one reads the
   subclass above instead, which is why both exist. */
- (CGFloat)tableView:(NSTableView *)tableView
     heightOfRow:(NSInteger)row
{
  (void)tableView;
  return [self heightForRowAtIndex:row];
}

- (void)tableView:(NSTableView *)tableView
  willDisplayCell:(id)cell
   forTableColumn:(NSTableColumn *)tableColumn
              row:(NSInteger)row
{
  (void)tableView; (void)tableColumn;
  if (row < 0 || row >= (NSInteger)[_rows count]
      || ![cell isKindOfClass:[AGSourceListCell class]])
    return;
  AGSidebarRow *rowObject = _rows[(NSUInteger)row];
  AGSourceListCell *sourceCell = cell;
  if (rowObject.isHeader)
    {
      [sourceCell setRowKind:AGSourceListRowKindHeader];
      [sourceCell setCountText:nil];
      [sourceCell setImage:nil];
    }
  else if (rowObject.isSpacer)
    {
      [sourceCell setRowKind:AGSourceListRowKindSpacer];
      [sourceCell setCountText:nil];
      [sourceCell setImage:nil];
    }
  else
    {
      [sourceCell setRowKind:AGSourceListRowKindItem];
      [sourceCell setCountText:rowObject.countText];
      [sourceCell setImage:AGSidebarIcon(rowObject.iconName)];
    }
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row
{
  (void)tableView;
  if (row < 0 || row >= (NSInteger)[_rows count])
    return NO;
  AGSidebarRow *rowObject = _rows[(NSUInteger)row];
  return !(rowObject.isHeader || rowObject.isSpacer);
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
  (void)notification;
  if (_programmaticSelection)
    return;
  [self userSelectedRow:[_tableView selectedRow]];
}

@end
