/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/*
 * A single to-do item.  Mirrors one "- [ ] ..." or "- [x] ..." line of the
 * Markdown format documented in DKMarkdownCodec.h: a title, a done flag, an
 * optional "!important" star, an optional "@YYYY-MM-DD" due date, an
 * optional free-text notes paragraph and (one level of) subtasks.
 */
@interface DKTask : NSObject <NSCopying>
{
  NSString *_title;
  BOOL _done;
  BOOL _important;
  NSString *_dueDate;       /* "YYYY-MM-DD", or nil */
  NSString *_notes;         /* free text, or nil */
  NSMutableArray *_subtasks; /* array of DKTask; never nested more than one level */
}

@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign, getter=isDone) BOOL done;
@property (nonatomic, assign, getter=isImportant) BOOL important;
@property (nonatomic, copy) NSString *dueDate;
@property (nonatomic, copy) NSString *notes;
@property (nonatomic, readonly) NSMutableArray *subtasks;

+ (instancetype)taskWithTitle: (NSString *)title;

@end
