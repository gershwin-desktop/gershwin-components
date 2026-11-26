/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class TDList;
@class TDTask;

/*
 * Markdown file format for one Todo list (documented here since it is
 * also the format a person hand-editing the gist in a browser has to
 * follow):
 *
 *   # List name
 *
 *   - [ ] Buy milk
 *   - [x] Pay rent !important @2026-10-01
 *       A note is a paragraph indented four spaces more than the marker
 *       of the task or subtask it belongs to. It can span several lines
 *       and ends at the next "- [ ]"/"- [x]" line or a blank line.
 *     - [ ] Sub-item of the task above
 *     - [x] Another sub-item
 *
 * Rules:
 *  - A task line is "- [ ] <title>" (open) or "- [x] <title>" (done).
 *  - A subtask is the same marker indented two spaces under its parent
 *    task. Only one level of nesting is supported (matching the classic
 *    Wunderlist model: lists -> tasks -> subtasks, no deeper).
 *  - "!important" anywhere in the title, set off by whitespace, marks the
 *    task as starred/important. "@YYYY-MM-DD" anywhere in the title sets
 *    the due date. Both are optional, order-independent, and are stripped
 *    from the stored title.
 *  - Notes are a plain paragraph indented 4 columns past the owning
 *    item's marker (so column 4 for a top-level task, column 6 for a
 *    subtask), directly following that item's line.
 *  - A leading "# <name>" heading is optional and ignored when parsing;
 *    the list's name comes from the gist filename. The encoder always
 *    writes it, so hand edits in a browser keep a readable title.
 */
@interface TDMarkdownCodec : NSObject

+ (TDList *)listFromMarkdown: (NSString *)markdown name: (NSString *)name;
+ (NSString *)markdownFromList: (TDList *)list;

/* Builds one task straight from the same "title !important @date" syntax
 * used inside a list file, for the "add task" text field - so typing
 * "Buy milk !important @2026-10-01" there and writing it into the gist
 * by hand both go through one parser. */
+ (TDTask *)taskFromInlineText: (NSString *)text;

@end
