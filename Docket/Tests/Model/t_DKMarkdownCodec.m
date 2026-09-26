/* t_DKMarkdownCodec.m - ObjectTesting coverage for DKMarkdownCodec. Headless.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "../../DKList.h"
#import "../../DKTask.h"
#include "../../DKMarkdownCodec.m"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* --- parsing a plain task list --- */
  {
    NSString *md = @"# Groceries\n\n- [ ] Buy milk\n- [x] Buy eggs\n";
    DKList *list = [DKMarkdownCodec listFromMarkdown: md name: @"Groceries"];

    PASS(list != nil, "parses a minimal list");
    PASS_EQUAL([list name], @"Groceries", "list keeps the name it was given");
    PASS([[list tasks] count] == 2, "finds both tasks");
    PASS_EQUAL([[[list tasks] objectAtIndex: 0] title], @"Buy milk", "first task title");
    PASS([[[list tasks] objectAtIndex: 0] isDone] == NO, "open task parses as not done");
    PASS([[[list tasks] objectAtIndex: 1] isDone] == YES, "[x] parses as done");
  }

  /* --- star and due date markers --- */
  {
    NSString *md = @"# Home\n\n- [ ] Pay rent !important @2026-10-01\n";
    DKList *list = [DKMarkdownCodec listFromMarkdown: md name: @"Home"];
    DKTask *task = [[list tasks] objectAtIndex: 0];

    PASS_EQUAL([task title], @"Pay rent", "!important and @date are stripped from the title");
    PASS([task isImportant] == YES, "!important marks the task as starred");
    PASS_EQUAL([task dueDate], @"2026-10-01", "@date is parsed as the due date");
  }

  /* --- subtasks and notes --- */
  {
    NSString *md = @"# Trip\n\n"
      @"- [ ] Pack bags\n"
      @"    Remember the passport and the charger.\n"
      @"  - [ ] Shirts\n"
      @"  - [x] Shoes\n";
    DKList *list = [DKMarkdownCodec listFromMarkdown: md name: @"Trip"];
    DKTask *task = [[list tasks] objectAtIndex: 0];

    PASS_EQUAL([task notes], @"Remember the passport and the charger.", "note paragraph attaches to its task");
    PASS([[task subtasks] count] == 2, "finds both subtasks");
    PASS_EQUAL([[[task subtasks] objectAtIndex: 0] title], @"Shirts", "subtask title");
    PASS([[[task subtasks] objectAtIndex: 1] isDone] == YES, "subtask done state parses");
  }

  /* --- round trip: parse(serialize(x)) == x --- */
  {
    DKList *list = [DKList listWithName: @"Round Trip"];
    DKTask *t1 = [DKTask taskWithTitle: @"First task"];
    [t1 setImportant: YES];
    [t1 setDueDate: @"2026-11-05"];
    [t1 setNotes: @"A short note."];
    DKTask *sub = [DKTask taskWithTitle: @"A subtask"];
    [sub setDone: YES];
    [[t1 subtasks] addObject: sub];
    [[list tasks] addObject: t1];

    DKTask *t2 = [DKTask taskWithTitle: @"Second task"];
    [t2 setDone: YES];
    [[list tasks] addObject: t2];

    NSString *serialized = [DKMarkdownCodec markdownFromList: list];
    DKList *reparsed = [DKMarkdownCodec listFromMarkdown: serialized name: @"Round Trip"];

    PASS(reparsed != nil, "serialized markdown parses back");
    PASS_EQUAL(reparsed, list, "round trip reproduces the same list structure");

    NSString *serializedAgain = [DKMarkdownCodec markdownFromList: reparsed];
    PASS_EQUAL(serializedAgain, serialized, "serializing a reparsed list is byte-identical (stable format)");
  }

  [arp release];
  return 0;
}
