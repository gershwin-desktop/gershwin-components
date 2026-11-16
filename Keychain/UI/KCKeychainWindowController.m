/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "KCKeychainWindowController.h"
#import "KCItemInspector.h"
#import "KCItemEditor.h"
#import "KCPasswordPanel.h"
#import "KCUI.h"
#import "KCKeyring.h"
#import "KCCollection.h"
#import "KCItem.h"

static NSString * const kDefaultAlias = @"default";
static const CGFloat kCollectionsWidth = 180.0;
static const CGFloat kSearchWidth = 220.0;
static const CGFloat kStatusHeight = 18.0;
/* The rectangular add/remove buttons of a list, as in the Global
 * Shortcuts pane. */
static const CGFloat kMiniButtonWidth = 28.0;

@implementation KCKeychainWindowController
{
  KCKeyring *_keyring;
  NSTableView *_collectionsTable;
  NSTableView *_itemsTable;
  NSSearchField *_searchField;
  NSButton *_lockButton;
  NSButton *_addButton;
  NSButton *_removeButton;
  NSTextField *_statusLabel;
  NSArray *_visibleItems;
  NSString *_query;
  NSDateFormatter *_dateFormatter;
  KCItemInspector *_inspector;
  KCItemEditor *_editor;
}

- (NSTableColumn *) columnWithIdentifier: (NSString *)identifier
                                   title: (NSString *)title
                                   width: (CGFloat)width
{
  NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier: identifier];
  [[column headerCell] setStringValue: title];
  [column setWidth: width];
  [column setMinWidth: 40];
  [column setEditable: NO];
  return column;
}

- (NSScrollView *) scrollViewWithTable: (NSTableView *)table
{
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame: NSZeroRect];
  [scroll setHasVerticalScroller: YES];
  [scroll setHasHorizontalScroller: NO];
  [scroll setBorderType: NSBezelBorder];
  [scroll setDocumentView: table];
  return scroll;
}

- (instancetype) initWithKeyring: (KCKeyring *)keyring
{
  CGFloat W = 760;
  CGFloat H = 460;
  NSWindow *window = [[NSWindow alloc]
    initWithContentRect: NSMakeRect(0, 0, W, H)
              styleMask: NSTitledWindowMask | NSClosableWindowMask
                         | NSMiniaturizableWindowMask | NSResizableWindowMask
                backing: NSBackingStoreBuffered defer: NO];

  if ((self = [super initWithWindow: window]) == nil)
    return nil;

  _keyring = keyring;
  _visibleItems = [NSArray array];
  _dateFormatter = [NSDateFormatter new];
  /* The list shows the day only; the inspector has the full time. */
  [_dateFormatter setDateStyle: NSDateFormatterShortStyle];
  [_dateFormatter setTimeStyle: NSDateFormatterNoStyle];

  [window setTitle: @"Keychain"];
  [window setMinSize: NSMakeSize(METRICS_WIN_MIN_WIDTH + 100, 320)];
  NSView *content = [window contentView];

  CGFloat side = METRICS_CONTENT_SIDE_MARGIN;
  CGFloat topRowY = H - METRICS_CONTENT_TOP_MARGIN - METRICS_TEXT_INPUT_FIELD_HEIGHT;
  CGFloat statusY = METRICS_SPACE_12;
  CGFloat buttonsY = statusY + kStatusHeight + METRICS_SPACE_8;
  CGFloat tablesY = buttonsY + METRICS_BUTTON_HEIGHT;
  CGFloat tablesTop = topRowY - METRICS_SPACE_12;
  CGFloat itemsX = side + kCollectionsWidth + METRICS_SPACE_8;

  _lockButton = KCMakeButton(@"Unlock", self, @selector(toggleLock:));
  [_lockButton setFrame: NSMakeRect(side, topRowY + 1, KCButtonWidth(_lockButton),
                                    METRICS_BUTTON_HEIGHT)];
  [_lockButton setAutoresizingMask: NSViewMinYMargin];
  [content addSubview: _lockButton];

  _searchField = [[NSSearchField alloc] initWithFrame:
    NSMakeRect(W - side - kSearchWidth, topRowY, kSearchWidth,
               METRICS_TEXT_INPUT_FIELD_HEIGHT)];
  [[_searchField cell] setPlaceholderString: @"Search"];
  [[_searchField cell] setSendsWholeSearchString: NO];
  [[_searchField cell] setSendsSearchStringImmediately: YES];
  [_searchField setDelegate: self];
  [_searchField setTarget: self];
  [_searchField setAction: @selector(searchChanged:)];
  [_searchField setAutoresizingMask: NSViewMinXMargin | NSViewMinYMargin];
  [content addSubview: _searchField];

  _collectionsTable = [[NSTableView alloc] initWithFrame: NSZeroRect];
  [_collectionsTable addTableColumn:
    [self columnWithIdentifier: @"label" title: @"Keychains" width: kCollectionsWidth - 20]];
  [_collectionsTable setDataSource: self];
  [_collectionsTable setDelegate: self];
  [_collectionsTable setAllowsEmptySelection: NO];
  NSScrollView *collectionsScroll = [self scrollViewWithTable: _collectionsTable];
  [collectionsScroll setFrame: NSMakeRect(side, tablesY, kCollectionsWidth,
                                          tablesTop - tablesY)];
  [collectionsScroll setAutoresizingMask: NSViewHeightSizable];
  [content addSubview: collectionsScroll];

  _itemsTable = [[NSTableView alloc] initWithFrame: NSZeroRect];
  /* Relative widths; fitColumnsOfTable: scales them to the view. */
  [_itemsTable addTableColumn: [self columnWithIdentifier: @"label" title: @"Name" width: 120]];
  [_itemsTable addTableColumn: [self columnWithIdentifier: @"service" title: @"Service" width: 100]];
  [_itemsTable addTableColumn: [self columnWithIdentifier: @"account" title: @"Account" width: 80]];
  [_itemsTable addTableColumn: [self columnWithIdentifier: @"created" title: @"Created" width: 70]];
  [_itemsTable addTableColumn: [self columnWithIdentifier: @"modified" title: @"Modified" width: 70]];
  [_itemsTable setColumnAutoresizingStyle: NSTableViewUniformColumnAutoresizingStyle];
  [_itemsTable setDataSource: self];
  [_itemsTable setDelegate: self];
  [_itemsTable setTarget: self];
  [_itemsTable setDoubleAction: @selector(showInspector:)];
  NSScrollView *itemsScroll = [self scrollViewWithTable: _itemsTable];
  [itemsScroll setFrame: NSMakeRect(itemsX, tablesY, W - side - itemsX, tablesTop - tablesY)];
  [itemsScroll setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
  [content addSubview: itemsScroll];

  _addButton = KCMakeButton(@"+", self, @selector(newItem:));
  [_addButton setBezelStyle: NSRegularSquareBezelStyle];
  [_addButton setFrame: NSMakeRect(itemsX, buttonsY, kMiniButtonWidth, METRICS_BUTTON_HEIGHT)];
  [_addButton setAutoresizingMask: NSViewMaxYMargin];
  [content addSubview: _addButton];
  _removeButton = KCMakeButton(@"-", self, @selector(deleteItem:));
  [_removeButton setBezelStyle: NSRegularSquareBezelStyle];
  /* One pixel of overlap so the two 1px outlines form a single line. */
  [_removeButton setFrame: NSMakeRect(itemsX + kMiniButtonWidth - 1, buttonsY,
                                      kMiniButtonWidth, METRICS_BUTTON_HEIGHT)];
  [_removeButton setAutoresizingMask: NSViewMaxYMargin];
  [content addSubview: _removeButton];

  _statusLabel = KCMakeLabel(@"");
  [_statusLabel setFont: METRICS_FONT_SYSTEM_REGULAR_11];
  [_statusLabel setFrame: NSMakeRect(side, statusY, W - 2 * side, kStatusHeight)];
  [_statusLabel setAutoresizingMask: NSViewWidthSizable | NSViewMaxYMargin];
  [content addSubview: _statusLabel];

  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  /* The window manager may shrink the window below the size built here, so
   * the columns follow their scroll view whenever it changes size. */
  [[collectionsScroll contentView] setPostsFrameChangedNotifications: YES];
  [[itemsScroll contentView] setPostsFrameChangedNotifications: YES];
  [nc addObserver: self selector: @selector(clipViewResized:)
             name: NSViewFrameDidChangeNotification
           object: [collectionsScroll contentView]];
  [nc addObserver: self selector: @selector(clipViewResized:)
             name: NSViewFrameDidChangeNotification
           object: [itemsScroll contentView]];
  /* Only now: restoring the saved frame resizes the window, and the
   * controls must already be there to follow it. */
  [window setFrameAutosaveName: @"KeychainMainWindow"];
  [self fitColumnsOfTable: _collectionsTable];
  [self fitColumnsOfTable: _itemsTable];
  [nc addObserver: self selector: @selector(modelChanged:)
             name: KCCollectionDidChangeNotification object: nil];
  [nc addObserver: self selector: @selector(modelChanged:)
             name: KCKeyringDidChangeCollectionsNotification object: keyring];

  [self reloadCollections];
  return self;
}

- (void) dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver: self];
}

#pragma mark Layout

/* Scales the columns so together they fill the visible width exactly. */
- (void) fitColumnsOfTable: (NSTableView *)table
{
  NSArray *columns = [table tableColumns];
  CGFloat spacing = [table intercellSpacing].width * [columns count];
  CGFloat available = NSWidth([[[table enclosingScrollView] contentView] bounds]) - spacing;
  CGFloat total = 0;
  NSEnumerator *e = [columns objectEnumerator];
  NSTableColumn *column;

  while ((column = [e nextObject]) != nil)
    total += [column width];
  if (total <= 0 || available <= 0)
    return;
  e = [columns objectEnumerator];
  while ((column = [e nextObject]) != nil)
    [column setWidth: floor([column width] * available / total)];
  /* Rounding leaves a few pixels; the last column takes them. */
  [table sizeLastColumnToFit];
  [table tile];
}

- (void) clipViewResized: (NSNotification *)n
{
  [self fitColumnsOfTable: [[n object] documentView]];
}

#pragma mark State

- (KCCollection *) selectedCollection
{
  NSInteger row = [_collectionsTable selectedRow];
  NSArray *collections = [_keyring collections];
  return (row >= 0 && row < (NSInteger)[collections count])
    ? [collections objectAtIndex: row] : nil;
}

- (KCItem *) selectedItem
{
  NSInteger row = [_itemsTable selectedRow];
  return (row >= 0 && row < (NSInteger)[_visibleItems count])
    ? [_visibleItems objectAtIndex: row] : nil;
}

- (BOOL) item: (KCItem *)item matches: (NSString *)query
{
  NSArray *fields = [NSArray arrayWithObjects: [item label], [item displayService],
    [item displayAccount], nil];
  NSEnumerator *e = [fields objectEnumerator];
  NSString *field;

  while ((field = [e nextObject]) != nil)
    {
      if ([field rangeOfString: query options: NSCaseInsensitiveSearch].location
          != NSNotFound)
        return YES;
    }
  return NO;
}

- (void) reloadItems
{
  KCCollection *c = [self selectedCollection];
  KCItem *selected = [self selectedItem];
  NSString *query = _query;
  NSMutableArray *items = [NSMutableArray array];
  NSEnumerator *e = [[c items] objectEnumerator];
  KCItem *item;
  NSUInteger index;

  while ((item = [e nextObject]) != nil)
    {
      if ([query length] == 0 || [self item: item matches: query])
        [items addObject: item];
    }
  [items sortUsingComparator: ^NSComparisonResult(KCItem *a, KCItem *b) {
    return [[a label] localizedCaseInsensitiveCompare: [b label]];
  }];
  _visibleItems = items;
  [_itemsTable reloadData];

  index = selected != nil ? [_visibleItems indexOfObjectIdenticalTo: selected] : NSNotFound;
  if (index != NSNotFound)
    [_itemsTable selectRowIndexes: [NSIndexSet indexSetWithIndex: index]
             byExtendingSelection: NO];
  else
    [_itemsTable deselectAll: nil];
  [self updateControls];
}

- (void) reloadCollections
{
  KCCollection *selected = [self selectedCollection];
  NSUInteger index;

  [_collectionsTable reloadData];
  index = selected != nil
    ? [[_keyring collections] indexOfObjectIdenticalTo: selected] : NSNotFound;
  if (index == NSNotFound && [[_keyring collections] count] > 0)
    {
      KCCollection *def = [_keyring collectionForAlias: kDefaultAlias];
      index = def != nil ? [[_keyring collections] indexOfObjectIdenticalTo: def] : 0;
    }
  if (index != NSNotFound)
    [_collectionsTable selectRowIndexes: [NSIndexSet indexSetWithIndex: index]
                   byExtendingSelection: NO];
  [self reloadItems];
}

- (void) updateControls
{
  KCCollection *c = [self selectedCollection];
  NSString *status;

  [_lockButton setTitle: (c != nil && ![c isLocked]) ? @"Lock" : @"Unlock"];
  [_lockButton setEnabled: c != nil];
  [_addButton setEnabled: c != nil && ![c isLocked]];
  [_removeButton setEnabled: [self selectedItem] != nil];
  [_searchField setEnabled: c != nil && ![c isLocked]];

  if (c == nil)
    status = @"No keychains yet. Choose File > New Keychain, or let an application create one.";
  else if ([c isLocked])
    status = [NSString stringWithFormat:
      @"\"%@\" is locked (%lu items). Click Unlock to see them.",
      [c label], (unsigned long)[[c itemIdentifiers] count]];
  else
    status = [NSString stringWithFormat: @"%lu of %lu items",
      (unsigned long)[_visibleItems count], (unsigned long)[[c items] count]];
  [_statusLabel setStringValue: status];
  [_inspector setItem: [self selectedItem] collection: c];

  /* NSMenu -update only revalidates submenus that are open, and the global
   * menu bar drops actions of items it believes disabled. */
  NSEnumerator *e = [[[NSApp mainMenu] itemArray] objectEnumerator];
  NSMenuItem *top;
  while ((top = [e nextObject]) != nil)
    [[top submenu] update];
}

- (void) modelChanged: (NSNotification *)n
{
  if ([[n name] isEqualToString: KCKeyringDidChangeCollectionsNotification])
    [self reloadCollections];
  else
    {
      [_collectionsTable reloadData];
      if ([n object] == [self selectedCollection])
        [self reloadItems];
    }
}

- (BOOL) saveCollection: (KCCollection *)collection
{
  NSError *error = nil;

  if ([_keyring saveCollection: collection error: &error])
    return YES;
  NSRunAlertPanel(@"The keychain could not be saved",
    @"%@", @"OK", nil, nil, [error localizedDescription]);
  return NO;
}

#pragma mark Table data

- (NSInteger) numberOfRowsInTableView: (NSTableView *)table
{
  return table == _collectionsTable
    ? (NSInteger)[[_keyring collections] count] : (NSInteger)[_visibleItems count];
}

- (id) tableView: (NSTableView *)table
    objectValueForTableColumn: (NSTableColumn *)column
                          row: (NSInteger)row
{
  NSString *identifier = [column identifier];

  if (table == _collectionsTable)
    {
      KCCollection *c = [[_keyring collections] objectAtIndex: row];
      return [c isLocked]
        ? [NSString stringWithFormat: @"%@ (locked)", [c label]] : [c label];
    }

  KCItem *item = [_visibleItems objectAtIndex: row];
  if ([identifier isEqual: @"label"])
    return [item label];
  if ([identifier isEqual: @"service"])
    return [item displayService];
  if ([identifier isEqual: @"account"])
    return [item displayAccount];
  if ([identifier isEqual: @"created"])
    return [_dateFormatter stringFromDate: [item created]];
  return [_dateFormatter stringFromDate: [item modified]];
}

- (void) tableView: (NSTableView *)table
   willDisplayCell: (id)cell
    forTableColumn: (NSTableColumn *)column
               row: (NSInteger)row
{
  if (table != _collectionsTable)
    return;
  /* The default keychain is where applications store new passwords, so it
   * stands out. */
  KCCollection *c = [[_keyring collections] objectAtIndex: row];
  [cell setFont: c == [_keyring collectionForAlias: kDefaultAlias]
    ? METRICS_FONT_SYSTEM_BOLD_13 : METRICS_FONT_SYSTEM_REGULAR_13];
}

- (void) tableViewSelectionDidChange: (NSNotification *)n
{
  if ([n object] == _collectionsTable)
    {
      [_searchField setStringValue: @""];
      _query = nil;
      [self reloadItems];
    }
  else
    [self updateControls];
}

- (void) searchChanged: (id)sender
{
  NSString *text = [_searchField stringValue];

  /* Both the action and the text notification arrive for one edit. */
  if ([text isEqualToString: _query != nil ? _query : @""])
    return;
  _query = [text copy];
  [self reloadItems];
}

- (void) controlTextDidChange: (NSNotification *)n
{
  if ([n object] != _searchField)
    return;
  /* The cell commits its value only when editing ends; the field editor
   * already holds what the user typed. */
  NSText *editor = [[n userInfo] objectForKey: @"NSFieldEditor"];
  NSString *text = editor != nil ? [editor string] : [_searchField stringValue];

  if ([text isEqualToString: _query != nil ? _query : @""])
    return;
  _query = [text copy];
  [self reloadItems];
}

#pragma mark Password confirmation

- (void) confirmPasswordForCollection: (KCCollection *)collection
                               reason: (NSString *)reason
                                 then: (void (^)(void))block
{
  KCPasswordPanel *panel = [[KCPasswordPanel alloc]
    initWithTitle: @"Confirm Access"
          message: reason
      newPassword: NO
          askName: NO
        validator: ^NSString *(KCPasswordPanel *p) {
          return [collection verifyPassword: [p password]]
            ? nil : @"The password is not correct.";
        }
       completion: ^(BOOL accepted) {
          if (accepted)
            block();
        }];
  [panel show];
}

#pragma mark Actions

- (IBAction) toggleLock: (id)sender
{
  KCCollection *c = [self selectedCollection];

  if (c == nil)
    return;
  if (![c isLocked])
    {
      [c lock];
      return;
    }
  KCPasswordPanel *panel = [[KCPasswordPanel alloc]
    initWithTitle: @"Unlock Keychain"
          message: [NSString stringWithFormat:
                     @"Enter the password of the keychain \"%@\".", [c label]]
      newPassword: NO
          askName: NO
        validator: ^NSString *(KCPasswordPanel *p) {
          NSError *error = nil;
          return [c unlockWithPassword: [p password] error: &error]
            ? nil : [error localizedDescription];
        }
       completion: nil];
  [panel show];
}

- (IBAction) lockAll: (id)sender
{
  [[_keyring collections] makeObjectsPerformSelector: @selector(lock)];
}

- (IBAction) newItem: (id)sender
{
  KCCollection *c = [self selectedCollection];

  if (c == nil || [c isLocked])
    return;
  if (_editor == nil)
    _editor = [[KCItemEditor alloc] initWithController: self];
  [_editor beginForCollection: c];
}

- (IBAction) deleteItem: (id)sender
{
  KCCollection *c = [self selectedCollection];
  KCItem *item = [self selectedItem];

  if (item == nil || [c isLocked])
    return;
  if (NSRunAlertPanel(@"Delete this item?",
        @"\"%@\" will be removed from the keychain \"%@\". Applications that "
        @"stored it will ask for the password again.",
        @"Delete", @"Cancel", nil, [item label], [c label]) != NSAlertDefaultReturn)
    return;
  [c deleteItem: item];
  [self saveCollection: c];
}

- (IBAction) newKeychain: (id)sender
{
  KCKeyring *keyring = _keyring;
  KCPasswordPanel *panel = [[KCPasswordPanel alloc]
    initWithTitle: @"New Keychain"
          message: @"Enter a name for the new keychain and choose its password."
      newPassword: YES
          askName: YES
        validator: ^NSString *(KCPasswordPanel *p) {
          NSError *error = nil;
          KCCollection *c = [keyring createCollectionWithLabel: [p name]
                                                      password: [p password]
                                                         error: &error];
          if (c == nil)
            return [error localizedDescription];
          /* The first keychain becomes the default, or applications would
           * have to create another one for their passwords. */
          if ([keyring collectionForAlias: kDefaultAlias] == nil
            && ![keyring setAlias: kDefaultAlias forCollection: c error: &error])
            return [error localizedDescription];
          return nil;
        }
       completion: nil];
  [panel show];
}

- (IBAction) deleteKeychain: (id)sender
{
  KCCollection *c = [self selectedCollection];
  NSError *error = nil;

  if (c == nil)
    return;
  if (NSRunAlertPanel(@"Delete this keychain?",
        @"The keychain \"%@\" and all %lu items in it will be deleted. "
        @"This cannot be undone.",
        @"Delete", @"Cancel", nil, [c label],
        (unsigned long)[[c itemIdentifiers] count]) != NSAlertDefaultReturn)
    return;
  if (![_keyring deleteCollection: c error: &error])
    NSRunAlertPanel(@"The keychain could not be deleted", @"%@", @"OK", nil, nil,
                    [error localizedDescription]);
}

- (IBAction) makeDefault: (id)sender
{
  NSError *error = nil;
  KCCollection *c = [self selectedCollection];

  if (c != nil && ![_keyring setAlias: kDefaultAlias forCollection: c error: &error])
    NSRunAlertPanel(@"The default keychain could not be changed", @"%@",
                    @"OK", nil, nil, [error localizedDescription]);
}

- (IBAction) showInspector: (id)sender
{
  if (_inspector == nil)
    _inspector = [[KCItemInspector alloc] initWithController: self];
  [_inspector setItem: [self selectedItem] collection: [self selectedCollection]];
  [_inspector showWindow: self];
}

- (IBAction) copyPassword: (id)sender
{
  KCCollection *c = [self selectedCollection];
  KCItem *item = [self selectedItem];

  if (item == nil || [c isLocked])
    return;
  [self confirmPasswordForCollection: c
    reason: [NSString stringWithFormat:
              @"To copy the password of \"%@\" to the clipboard, enter the "
              @"password of the keychain \"%@\".", [item label], [c label]]
      then: ^{
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        NSString *secret = [[NSString alloc] initWithData: [item secret]
                                                 encoding: NSUTF8StringEncoding];
        [pb declareTypes: [NSArray arrayWithObject: NSStringPboardType] owner: nil];
        [pb setString: secret != nil ? secret : @"" forType: NSStringPboardType];
      }];
}

- (IBAction) performFindPanelAction: (id)sender
{
  [[self window] makeFirstResponder: _searchField];
}

- (BOOL) validateMenuItem: (NSMenuItem *)item
{
  SEL action = [item action];
  KCCollection *c = [self selectedCollection];
  BOOL unlocked = c != nil && ![c isLocked];

  if (sel_isEqual(action, @selector(toggleLock:)))
    {
      [item setTitle: unlocked ? @"Lock Keychain" : @"Unlock Keychain"];
      return c != nil;
    }
  if (sel_isEqual(action, @selector(newItem:)))
    return unlocked;
  if (sel_isEqual(action, @selector(deleteItem:))
    || sel_isEqual(action, @selector(copyPassword:))
    || sel_isEqual(action, @selector(showInspector:)))
    return unlocked && [self selectedItem] != nil;
  if (sel_isEqual(action, @selector(deleteKeychain:)))
    return c != nil;
  if (sel_isEqual(action, @selector(makeDefault:)))
    return c != nil && c != [_keyring collectionForAlias: kDefaultAlias];
  if (sel_isEqual(action, @selector(performFindPanelAction:)))
    return unlocked;
  return YES;
}

@end
