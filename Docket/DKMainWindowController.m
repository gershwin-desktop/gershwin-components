/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DKMainWindowController.h"
#import "DKSidebarTableView.h"
#import "DKTaskOutlineView.h"
#import "DKTaskTitleCell.h"
#import "DKTexture.h"
#import "DKStore.h"
#import "DKList.h"
#import "DKTask.h"
#import "DKMarkdownCodec.h"

static NSString * const DKListPboardType = @"io.github.gershwin-desktop.Docket.list";
static NSString * const DKTaskPboardType = @"io.github.gershwin-desktop.Docket.task";

/* Top-down layout constants (see gershwin-appearance-metrics: all
 * multiples of 2, 24px side margins, 12/16/20 group spacing). */
static const CGFloat DKMargin = 24.0;
static const CGFloat DKTopMargin = 15.0;
static const CGFloat DKBottomMargin = 20.0;
static const CGFloat DKSpace8 = 8.0;
static const CGFloat DKSpace12 = 12.0;
static const CGFloat DKSpace16 = 16.0;
static const CGFloat DKButtonH = 20.0;
static const CGFloat DKFieldH = 22.0;
static const CGFloat DKToolbarH = 24.0;
static const CGFloat DKSidebarW = 180.0;
static const CGFloat DKNotesH = 70.0;

@interface DKMainContentView : NSView
{
  DKMainWindowController *_owner;
}
- (instancetype)initWithOwner: (DKMainWindowController *)owner;
@end

@implementation DKMainContentView

- (instancetype)initWithOwner: (DKMainWindowController *)owner
{
  self = [super initWithFrame: NSZeroRect];
  if (self)
    {
      _owner = owner; /* weak: the controller owns the window, which owns us */
    }
  return self;
}

- (void)setFrameSize: (NSSize)newSize
{
  [super setFrameSize: newSize];
  [_owner relayoutSubviewsForSize: newSize];
}

- (void)viewDidMoveToWindow
{
  [super viewDidMoveToWindow];
  if ([self window] != nil && [self superview] != nil)
    {
      [self setFrame: [[self superview] bounds]];
      [_owner relayoutSubviewsForSize: [self bounds].size];
    }
}

- (void)setFrame: (NSRect)frameRect
{
  /* The window system (e.g. a screen too small for the requested size)
   * can resize the content view through -setFrame: directly, which
   * bypasses -setFrameSize: entirely - so this needs its own hook or a
   * post-creation resize silently leaves the old, wrong layout in place. */
  [super setFrame: frameRect];
  [_owner relayoutSubviewsForSize: frameRect.size];
}

@end

@implementation DKMainWindowController

- (instancetype)init
{
  self = [super init];
  if (self)
    {
      [self buildWindow];
      [_sidebarTable reloadData];
    }
  return self;
}

- (void)dealloc
{
  [_window release];
  [_draggedTaskItems release];
  [_draggedListRows release];
  [super dealloc];
}

- (void)showWindow
{
  [_window makeKeyAndOrderFront: nil];
}

/* --- construction --- */

- (void)buildWindow
{
  NSRect frame = NSMakeRect(120.0, 120.0, 900.0, 560.0);
  DKMainContentView *content;
  NSScrollView *sidebarScroll, *taskScroll, *notesScroll;
  NSTableColumn *nameColumn, *doneColumn, *starColumn, *titleColumn;
  NSButton *addListButton, *addTaskButton;

  _window = [[NSWindow alloc] initWithContentRect: frame
                                         styleMask: (NSTitledWindowMask | NSClosableWindowMask
                                                      | NSMiniaturizableWindowMask | NSResizableWindowMask)
                                           backing: NSBackingStoreBuffered
                                             defer: NO];
  [_window setTitle: @"Docket"];
  [_window setMinSize: NSMakeSize(620.0, 380.0)];

  content = [[[DKMainContentView alloc] initWithOwner: self] autorelease];
  [_window setContentView: content];

  /* Toolbar: pull, push, status */
  _pullButton = [[NSButton alloc] initWithFrame: NSZeroRect];
  [_pullButton setTitle: @"Pull"];
  [_pullButton setBezelStyle: NSRoundedBezelStyle];
  [_pullButton setTarget: self];
  [_pullButton setAction: @selector(pull:)];
  [content addSubview: _pullButton];

  _pushButton = [[NSButton alloc] initWithFrame: NSZeroRect];
  [_pushButton setTitle: @"Push"];
  [_pushButton setBezelStyle: NSRoundedBezelStyle];
  [_pushButton setTarget: self];
  [_pushButton setAction: @selector(push:)];
  [content addSubview: _pushButton];

  _statusLabel = [[NSTextField alloc] initWithFrame: NSZeroRect];
  [_statusLabel setEditable: NO];
  [_statusLabel setSelectable: NO];
  [_statusLabel setBordered: NO];
  [_statusLabel setDrawsBackground: NO];
  [_statusLabel setAlignment: NSRightTextAlignment];
  [_statusLabel setFont: [NSFont systemFontOfSize: 11.0]];
  [_statusLabel setStringValue: @"Not yet synced"];
  [content addSubview: _statusLabel];

  /* Sidebar: wood table of lists, plus an add-list row */
  _sidebarTable = [[DKSidebarTableView alloc] initWithFrame: NSZeroRect];
  [_sidebarTable setHeaderView: nil];
  [_sidebarTable setAllowsMultipleSelection: NO];
  [_sidebarTable setRowHeight: 24.0];
  nameColumn = [[[NSTableColumn alloc] initWithIdentifier: @"name"] autorelease];
  [[nameColumn dataCell] setFont: [NSFont boldSystemFontOfSize: 13.0]];
  [_sidebarTable addTableColumn: nameColumn];
  [_sidebarTable setDataSource: self];
  [_sidebarTable setDelegate: self];
  [_sidebarTable registerForDraggedTypes: [NSArray arrayWithObject: DKListPboardType]];
  [_sidebarTable setDraggingSourceOperationMask: NSDragOperationMove forLocal: YES];
  /* A single-column list is reordered by dragging straight up/down; the
   * default in libs-gui requires some horizontal motion to arm a drag
   * (NSTableView.m, _verticalMotionDrag), which a one-column view never
   * has. */
  [_sidebarTable setVerticalMotionCanBeginDrag: YES];

  sidebarScroll = [[[NSScrollView alloc] initWithFrame: NSZeroRect] autorelease];
  [sidebarScroll setHasVerticalScroller: YES];
  [sidebarScroll setHasHorizontalScroller: NO];
  [sidebarScroll setBorderType: NSBezelBorder];
  [sidebarScroll setDocumentView: _sidebarTable];
  [_sidebarTable release];
  [content addSubview: sidebarScroll];
  _sidebarScroll = sidebarScroll;

  _newListField = [[NSTextField alloc] initWithFrame: NSZeroRect];
  [_newListField setPlaceholderString: @"New list"];
  [_newListField setTarget: self];
  [_newListField setAction: @selector(addList:)];
  [content addSubview: _newListField];

  addListButton = [[[NSButton alloc] initWithFrame: NSZeroRect] autorelease];
  [addListButton setTitle: @"Add List"];
  [addListButton setBezelStyle: NSRoundedBezelStyle];
  [addListButton setTarget: self];
  [addListButton setAction: @selector(addList:)];
  [content addSubview: addListButton];
  _addListButton = addListButton;

  /* Task outline: leather list of tasks/subtasks for the selected list */
  _taskOutline = [[DKTaskOutlineView alloc] initWithFrame: NSZeroRect];
  [_taskOutline setHeaderView: nil];
  [_taskOutline setRowHeight: 22.0];
  [_taskOutline setIndentationPerLevel: 16.0];
  [_taskOutline setAllowsMultipleSelection: NO];

  doneColumn = [[[NSTableColumn alloc] initWithIdentifier: @"done"] autorelease];
  [doneColumn setWidth: 24.0];
  [doneColumn setEditable: YES];
  {
    NSButtonCell *cell = [[[NSButtonCell alloc] init] autorelease];
    [cell setButtonType: NSSwitchButton];
    [cell setTitle: @""];
    [doneColumn setDataCell: cell];
  }
  [_taskOutline addTableColumn: doneColumn];

  starColumn = [[[NSTableColumn alloc] initWithIdentifier: @"star"] autorelease];
  [starColumn setWidth: 22.0];
  [starColumn setEditable: YES];
  {
    NSButtonCell *cell = [[[NSButtonCell alloc] init] autorelease];
    [cell setButtonType: NSToggleButton];
    [cell setImagePosition: NSImageOnly];
    [cell setBordered: NO];
    [cell setImage: [DKTexture starImageFilled: NO size: NSMakeSize(16.0, 16.0)]];
    [cell setAlternateImage: [DKTexture starImageFilled: YES size: NSMakeSize(16.0, 16.0)]];
    [starColumn setDataCell: cell];
  }
  [_taskOutline addTableColumn: starColumn];

  titleColumn = [[[NSTableColumn alloc] initWithIdentifier: @"title"] autorelease];
  [titleColumn setEditable: NO];
  [titleColumn setDataCell: [[[DKTaskTitleCell alloc] init] autorelease]];
  [_taskOutline addTableColumn: titleColumn];
  [_taskOutline setOutlineTableColumn: titleColumn];

  [_taskOutline setDataSource: self];
  [_taskOutline setDelegate: self];
  [_taskOutline registerForDraggedTypes: [NSArray arrayWithObject: DKTaskPboardType]];
  [_taskOutline setDraggingSourceOperationMask: NSDragOperationMove forLocal: YES];
  [_taskOutline setVerticalMotionCanBeginDrag: YES];

  taskScroll = [[[NSScrollView alloc] initWithFrame: NSZeroRect] autorelease];
  [taskScroll setHasVerticalScroller: YES];
  [taskScroll setHasHorizontalScroller: NO];
  [taskScroll setBorderType: NSBezelBorder];
  [taskScroll setDocumentView: _taskOutline];
  [_taskOutline release];
  [content addSubview: taskScroll];
  _taskScroll = taskScroll;

  _notesView = [[NSTextView alloc] initWithFrame: NSZeroRect];
  [_notesView setDelegate: self];
  [_notesView setFont: [NSFont systemFontOfSize: 12.0]];
  [_notesView setRichText: NO];
  [_notesView setEditable: NO];
  /* An NSTextView left at its defaults inside a scroll view grows to its
   * (effectively unbounded) container size and paints outside the small
   * clip rect meant for it, both corrupting the display and stealing
   * clicks from whatever sits under that overflow - it must be told to
   * track the scroll view's width and only grow vertically. */
  [_notesView setMinSize: NSMakeSize(0.0, 0.0)];
  [_notesView setMaxSize: NSMakeSize(1.0e7, 1.0e7)];
  [_notesView setVerticallyResizable: YES];
  [_notesView setHorizontallyResizable: NO];
  [_notesView setAutoresizingMask: NSViewWidthSizable];
  [[_notesView textContainer] setWidthTracksTextView: YES];
  notesScroll = [[[NSScrollView alloc] initWithFrame: NSZeroRect] autorelease];
  [notesScroll setHasVerticalScroller: YES];
  [notesScroll setBorderType: NSBezelBorder];
  [notesScroll setDocumentView: _notesView];
  [_notesView release];
  [content addSubview: notesScroll];
  _notesScroll = notesScroll;

  _newTaskField = [[NSTextField alloc] initWithFrame: NSZeroRect];
  [_newTaskField setPlaceholderString: @"New task, e.g. Buy milk !important @2026-10-01"];
  [_newTaskField setTarget: self];
  [_newTaskField setAction: @selector(addTask:)];
  [content addSubview: _newTaskField];

  addTaskButton = [[[NSButton alloc] initWithFrame: NSZeroRect] autorelease];
  [addTaskButton setTitle: @"Add Task"];
  [addTaskButton setBezelStyle: NSRoundedBezelStyle];
  [addTaskButton setTarget: self];
  [addTaskButton setAction: @selector(addTask:)];
  [content addSubview: addTaskButton];
  _addTaskButtonRef = addTaskButton;

  _addSubtaskButton = [[NSButton alloc] initWithFrame: NSZeroRect];
  [_addSubtaskButton setTitle: @"Add Subtask"];
  [_addSubtaskButton setBezelStyle: NSRoundedBezelStyle];
  [_addSubtaskButton setTarget: self];
  [_addSubtaskButton setAction: @selector(addSubtask:)];
  [_addSubtaskButton setEnabled: NO];
  [content addSubview: _addSubtaskButton];

  [self relayoutSubviewsForSize: frame.size];
}

- (void)relayoutSubviewsForSize: (NSSize)size
{
  CGFloat w = size.width;
  CGFloat h = size.height;
  CGFloat toolbarY = h - DKTopMargin - DKToolbarH;
  CGFloat contentTop = toolbarY - DKSpace16;
  CGFloat sidebarX = DKMargin;
  CGFloat taskX = DKMargin + DKSidebarW + DKSpace16;
  CGFloat taskW = w - DKMargin - taskX;
  CGFloat rowY = DKBottomMargin;

  if (_window == nil)
    {
      return;
    }

  [_pullButton setFrame: NSMakeRect(DKMargin, toolbarY, 90.0, DKButtonH)];
  [_pushButton setFrame: NSMakeRect(DKMargin + 90.0 + DKSpace12, toolbarY, 90.0, DKButtonH)];
  [_statusLabel setFrame: NSMakeRect(DKMargin + 2 * 90.0 + 2 * DKSpace12, toolbarY,
                                       w - DKMargin - (DKMargin + 2 * 90.0 + 2 * DKSpace12), DKButtonH)];

  /* Sidebar column: add-list row pinned to the bottom, table above it */
  [_addListButton setFrame: NSMakeRect(sidebarX + DKSidebarW - 70.0, rowY, 70.0, DKButtonH)];
  [_newListField setFrame: NSMakeRect(sidebarX, rowY, DKSidebarW - 70.0 - DKSpace8, DKFieldH)];
  [_sidebarScroll setFrame: NSMakeRect(sidebarX, rowY + DKFieldH + DKSpace8,
                                         DKSidebarW, contentTop - (rowY + DKFieldH + DKSpace8))];

  /* Task column: add-task row, notes above it, outline above that */
  [_addSubtaskButton setFrame: NSMakeRect(w - DKMargin - 100.0, rowY, 100.0, DKButtonH)];
  [_addTaskButtonRef setFrame: NSMakeRect(w - DKMargin - 100.0 - DKSpace12 - 80.0, rowY, 80.0, DKButtonH)];
  [_newTaskField setFrame: NSMakeRect(taskX, rowY, taskW - 100.0 - 80.0 - 2 * DKSpace12, DKFieldH)];

  [_notesScroll setFrame: NSMakeRect(taskX, rowY + DKFieldH + DKSpace8, taskW, DKNotesH)];
  [_taskScroll setFrame: NSMakeRect(taskX, rowY + DKFieldH + DKSpace8 + DKNotesH + DKSpace8,
                                      taskW, contentTop - (rowY + DKFieldH + DKSpace8 + DKNotesH + DKSpace8))];
}

/* --- data: sidebar (list of lists) --- */

- (NSInteger)numberOfRowsInTableView: (NSTableView *)tableView
{
  return (NSInteger)[[[DKStore sharedStore] lists] count];
}

- (id)tableView: (NSTableView *)tableView objectValueForTableColumn: (NSTableColumn *)column row: (NSInteger)row
{
  return [[[[DKStore sharedStore] lists] objectAtIndex: (NSUInteger)row] name];
}

- (void)tableView: (NSTableView *)tableView willDisplayCell: (id)cell
   forTableColumn: (NSTableColumn *)column row: (NSInteger)row
{
  if (tableView == _sidebarTable)
    {
      [cell setTextColor: [NSColor colorWithCalibratedWhite: 0.97 alpha: 1.0]];
      [cell setDrawsBackground: NO];
    }
}

- (void)tableViewSelectionDidChange: (NSNotification *)note
{
  if ([note object] == _sidebarTable)
    {
      NSInteger row = [_sidebarTable selectedRow];
      NSArray *lists = [[DKStore sharedStore] lists];

      _selectedList = (row >= 0 && row < (NSInteger)[lists count]) ? [lists objectAtIndex: (NSUInteger)row] : nil;
      [_taskOutline reloadData];
      [self displayNotesForItem: nil];
    }
}

- (BOOL)tableView: (NSTableView *)tableView writeRowsWithIndexes: (NSIndexSet *)rows toPasteboard: (NSPasteboard *)pboard
{
  [_draggedListRows release];
  _draggedListRows = [rows copy];
  [pboard declareTypes: [NSArray arrayWithObject: DKListPboardType] owner: self];
  [pboard setString: @"list" forType: DKListPboardType];
  return YES;
}

- (NSDragOperation)tableView: (NSTableView *)tableView validateDrop: (id <NSDraggingInfo>)info
                  proposedRow: (NSInteger)row proposedDropOperation: (NSTableViewDropOperation)op
{
  if (op == NSTableViewDropOn)
    {
      return NSDragOperationNone;
    }
  return NSDragOperationMove;
}

- (BOOL)tableView: (NSTableView *)tableView acceptDrop: (id <NSDraggingInfo>)info
              row: (NSInteger)row dropOperation: (NSTableViewDropOperation)op
{
  NSMutableArray *lists = [[DKStore sharedStore] lists];
  NSMutableArray *moved = [NSMutableArray array];
  NSUInteger insertAt = (NSUInteger)row;
  NSUInteger idx;

  if (_draggedListRows == nil)
    {
      return NO;
    }
  idx = [_draggedListRows lastIndex];
  while (idx != NSNotFound)
    {
      DKList *list = [lists objectAtIndex: idx];

      [moved insertObject: list atIndex: 0];
      [lists removeObjectAtIndex: idx];
      if (idx < insertAt)
        {
          insertAt--;
        }
      idx = [_draggedListRows indexLessThanIndex: idx];
    }
  [lists insertObjects: moved atIndexes:
    [NSIndexSet indexSetWithIndexesInRange: NSMakeRange(insertAt, [moved count])]];

  [[DKStore sharedStore] persistListOrder];
  [_sidebarTable reloadData];
  return YES;
}

/* --- data: task outline (tasks and their subtasks) --- */

- (id)outlineView: (NSOutlineView *)outlineView child: (NSInteger)index ofItem: (id)item
{
  if (item == nil)
    {
      return [[_selectedList tasks] objectAtIndex: (NSUInteger)index];
    }
  return [[(DKTask *)item subtasks] objectAtIndex: (NSUInteger)index];
}

- (BOOL)outlineView: (NSOutlineView *)outlineView isItemExpandable: (id)item
{
  return [[(DKTask *)item subtasks] count] > 0;
}

- (NSInteger)outlineView: (NSOutlineView *)outlineView numberOfChildrenOfItem: (id)item
{
  if (item == nil)
    {
      return (_selectedList != nil) ? (NSInteger)[[_selectedList tasks] count] : 0;
    }
  return (NSInteger)[[(DKTask *)item subtasks] count];
}

- (id)outlineView: (NSOutlineView *)outlineView objectValueForTableColumn: (NSTableColumn *)column byItem: (id)item
{
  NSString *ident = [column identifier];

  if ([ident isEqualToString: @"done"])
    {
      return [NSNumber numberWithBool: [(DKTask *)item isDone]];
    }
  if ([ident isEqualToString: @"star"])
    {
      return [NSNumber numberWithBool: [(DKTask *)item isImportant]];
    }
  return item;
}

- (void)outlineView: (NSOutlineView *)outlineView setObjectValue: (id)value
    forTableColumn: (NSTableColumn *)column byItem: (id)item
{
  NSString *ident = [column identifier];

  if ([ident isEqualToString: @"done"])
    {
      [(DKTask *)item setDone: [value boolValue]];
      [self commitAndSync];
    }
  else if ([ident isEqualToString: @"star"])
    {
      [(DKTask *)item setImportant: [value boolValue]];
      [self commitAndSync];
    }
}

- (void)outlineViewSelectionDidChange: (NSNotification *)note
{
  NSInteger row = [_taskOutline selectedRow];
  id item = (row >= 0) ? [_taskOutline itemAtRow: row] : nil;

  [self displayNotesForItem: item];
  [_addSubtaskButton setEnabled: (item != nil) && ([_taskOutline levelForItem: item] == 0)];
}

- (BOOL)outlineView: (NSOutlineView *)outlineView writeItems: (NSArray *)items toPasteboard: (NSPasteboard *)pboard
{
  [_draggedTaskItems release];
  _draggedTaskItems = [items mutableCopy];
  [pboard declareTypes: [NSArray arrayWithObject: DKTaskPboardType] owner: self];
  [pboard setString: @"task" forType: DKTaskPboardType];
  return YES;
}

- (NSDragOperation)outlineView: (NSOutlineView *)outlineView validateDrop: (id <NSDraggingInfo>)info
                   proposedItem: (id)item proposedChildIndex: (NSInteger)index
{
  NSMutableArray *targetLevel;
  DKTask *dragged;

  /* AppKit reports a drop into the empty area below the last row as
   * (item=nil, index=-1) - "on the outline view itself", not on any
   * item. Treat that the same as dropping past the last root row
   * (append), rather than refusing it: it is the natural target for
   * "drop it at the bottom" and the one most reliably hit by a pointer
   * that only needs to land somewhere below the rows. Any other
   * negative index is a genuine "onto an item" gesture, which this
   * one-level format has no use for and refuses.
   */
  if (item == nil && index < 0)
    {
      index = (NSInteger)[[_selectedList tasks] count];
    }
  if (index < 0 || [_draggedTaskItems count] == 0)
    {
      return NSDragOperationNone;
    }
  dragged = [_draggedTaskItems objectAtIndex: 0];
  targetLevel = (item == nil) ? [_selectedList tasks] : [(DKTask *)item subtasks];

  /* Only allow a drop among the dragged item's own siblings: this format
   * supports exactly one level of nesting, so promoting/demoting a task
   * across levels by drag is refused rather than silently reinterpreted. */
  if ([targetLevel indexOfObjectIdenticalTo: dragged] == NSNotFound)
    {
      return NSDragOperationNone;
    }
  return NSDragOperationMove;
}

- (BOOL)outlineView: (NSOutlineView *)outlineView acceptDrop: (id <NSDraggingInfo>)info
               item: (id)item childIndex: (NSInteger)index
{
  NSMutableArray *level = (item == nil) ? [_selectedList tasks] : [(DKTask *)item subtasks];
  NSUInteger insertAt;
  NSMutableArray *moved = [NSMutableArray array];
  DKTask *dragged;

  if (item == nil && index < 0)
    {
      index = (NSInteger)[level count];
    }
  insertAt = (NSUInteger)index;
  if (index < 0 || [_draggedTaskItems count] == 0)
    {
      return NO;
    }
  dragged = [_draggedTaskItems objectAtIndex: 0];
  {
    NSUInteger from = [level indexOfObjectIdenticalTo: dragged];

    if (from == NSNotFound)
      {
        return NO;
      }
    [moved addObject: dragged];
    [level removeObjectAtIndex: from];
    if (from < insertAt)
      {
        insertAt--;
      }
  }
  [level insertObjects: moved atIndexes: [NSIndexSet indexSetWithIndex: insertAt]];

  [self commitAndSync];
  [_taskOutline reloadData];
  return YES;
}

/* --- notes --- */

- (void)displayNotesForItem: (id)item
{
  _notesTarget = item;
  if (item == nil)
    {
      [_notesView setString: @""];
      [_notesView setEditable: NO];
    }
  else
    {
      NSString *notes = [(DKTask *)item notes];

      [_notesView setString: (notes != nil) ? notes : @""];
      [_notesView setEditable: YES];
    }
}

- (void)textDidEndEditing: (NSNotification *)note
{
  if ([note object] == _notesView && _notesTarget != nil)
    {
      NSString *text = [_notesView string];

      [(DKTask *)_notesTarget setNotes: ([text length] > 0) ? text : nil];
      [self commitAndSync];
    }
}

/* --- actions --- */

- (void)pull: (id)sender
{
  NSError *error = nil;

  if ([[DKStore sharedStore] pullWithError: &error])
    {
      [_statusLabel setStringValue: @"Pulled from gist"];
    }
  else
    {
      [_statusLabel setStringValue: [NSString stringWithFormat: @"Pull failed: %@", [error localizedDescription]]];
    }
  [_sidebarTable reloadData];
  [_taskOutline reloadData];
}

- (void)push: (id)sender
{
  NSError *error = nil;

  if ([[DKStore sharedStore] pushWithError: &error])
    {
      [_statusLabel setStringValue: @"Pushed to gist"];
    }
  else
    {
      [_statusLabel setStringValue: [NSString stringWithFormat: @"Push failed: %@", [error localizedDescription]]];
    }
}

- (void)addList: (id)sender
{
  NSString *name = [_newListField stringValue];

  if ([name length] == 0)
    {
      return;
    }
  [[DKStore sharedStore] addListNamed: name];
  [_newListField setStringValue: @""];
  [_sidebarTable reloadData];
  [self push: nil];
}

- (void)addTask: (id)sender
{
  NSString *text = [_newTaskField stringValue];
  DKTask *task;

  if (_selectedList == nil || [text length] == 0)
    {
      return;
    }
  task = [DKMarkdownCodec taskFromInlineText: text];
  [[_selectedList tasks] addObject: task];
  [_newTaskField setStringValue: @""];
  [self commitAndSync];
  [_taskOutline reloadData];
}

- (void)addSubtask: (id)sender
{
  NSInteger row = [_taskOutline selectedRow];
  id parent = (row >= 0) ? [_taskOutline itemAtRow: row] : nil;
  NSString *text = [_newTaskField stringValue];
  DKTask *task;

  if (parent == nil || [text length] == 0)
    {
      return;
    }
  task = [DKMarkdownCodec taskFromInlineText: text];
  [[(DKTask *)parent subtasks] addObject: task];
  [_newTaskField setStringValue: @""];
  [self commitAndSync];
  [_taskOutline reloadData];
  [_taskOutline expandItem: parent];
}

- (void)commitAndSync
{
  NSError *error = nil;

  if (_selectedList != nil)
    {
      [[DKStore sharedStore] saveListLocally: _selectedList];
    }
  if ([[DKStore sharedStore] pushWithError: &error])
    {
      [_statusLabel setStringValue: @"Pushed to gist"];
    }
  else
    {
      [_statusLabel setStringValue: [NSString stringWithFormat: @"Saved locally; push failed: %@",
                                       [error localizedDescription]]];
    }
}

@end
