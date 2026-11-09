/* Copyright (c) 2026 Simon Peter / SPDX-License-Identifier: BSD-2-Clause */

#import <AppKit/AppKit.h>

/*
 * The sidebar's single cell type. A source list is one column of text with
 * section labels above it, so one cell that knows the three row kinds keeps
 * the table's delegate down to a row model and nothing else.
 *
 * The row label is the cell's stringValue and the category count is
 * countText. Which row is which is the controller's knowledge: it answers
 * -tableView:willDisplayCell:forTableColumn:row: and sets rowKind there,
 * right before the cell is drawn, so the cell never needs to know the table's
 * row layout.
 */

typedef NS_ENUM(NSInteger, AGSourceListRowKind) {
  /* "Discover", "Installed", a category: 13 pt label, optional count. */
  AGSourceListRowKindItem = 0,
  /* "Library", "Categories": small caps, grey, no count. */
  AGSourceListRowKindHeader,
  /* The blank gap between sections: draws nothing. */
  AGSourceListRowKindSpacer
};

@interface AGSourceListCell : NSTextFieldCell

@property (nonatomic, assign) AGSourceListRowKind rowKind;

/* Right-aligned grey count beside an item label, nil for the other kinds. */
/* Kept in the cell's representedObject rather than an ivar of its own: this
   AppKit copies a cell with NSCopyObject, a bitwise copy that retains only
   the ivars NSCell knows about. An object ivar added here would be shared
   by the copy without a retain and freed twice once the table's tracking
   copy went away, which crashed the sidebar on the first click. The glyph
   uses NSCell's own image slot for the same reason. */
@property (nonatomic, copy) NSString *countText;
+ (CGFloat)iconSide;

/* Row pitches of the sidebar table: a full row and the section gap. */
+ (CGFloat)rowHeight;
+ (CGFloat)spacerRowHeight;

@end
