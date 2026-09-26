/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class DKSidebarTableView;
@class DKTaskOutlineView;
@class DKList;
@class DKTask;

/*
 * Owns the whole (single) Docket window: the wood sidebar of lists, the
 * leather task outline (tasks and their subtasks) for whichever list is
 * selected, and the small notes/add-item controls around them. Built
 * entirely in code (no gorm), laid out by -relayoutSubviewsForSize: so
 * it resizes correctly.
 */
/*
 * NSOutlineViewDataSource/Delegate are deliberately not declared here:
 * this GNUstep version's headers list every method in those two
 * protocols as required (no @optional), so formally adopting them
 * would need dozens of no-op overrides just to silence -Wprotocol.
 * -setDataSource:/-setDelegate: take a plain id, so the outline view
 * methods below are picked up at runtime exactly the same way.
 */
@interface DKMainWindowController : NSObject
    <NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate>
{
  NSWindow *_window;

  DKSidebarTableView *_sidebarTable;
  NSScrollView *_sidebarScroll;
  NSTextField *_newListField;
  NSButton *_addListButton;

  DKTaskOutlineView *_taskOutline;
  NSScrollView *_taskScroll;
  NSScrollView *_notesScroll;
  NSTextView *_notesView;
  id _notesTarget; /* the DKTask (task or subtask) the notes view edits */
  NSTextField *_newTaskField;
  NSButton *_addTaskButtonRef;
  NSButton *_addSubtaskButton;

  NSButton *_pullButton;
  NSButton *_pushButton;
  NSTextField *_statusLabel;

  DKList *_selectedList;
  NSMutableArray *_draggedTaskItems;
  NSIndexSet *_draggedListRows;
}

- (void)relayoutSubviewsForSize: (NSSize)size;

- (void)showWindow;

@end
