/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "TDMarkdownCodec.h"
#import "TDList.h"
#import "TDTask.h"

static NSUInteger
TDLeadingSpaceCount(NSString *line)
{
  NSUInteger n = 0;
  NSUInteger len = [line length];

  while (n < len && [line characterAtIndex: n] == ' ')
    {
      n++;
    }
  return n;
}

/* Recognizes "- [ ] <body>" / "- [x] <body>" once leading spaces are
 * stripped; the indentation itself (0 for a task, 2 for a subtask) is
 * reported back through outIndent so the caller decides what to do with
 * indents this format does not use. */
static BOOL
TDParseTaskLine(NSString *line, NSUInteger *outIndent, BOOL *outDone, NSString **outBody)
{
  NSUInteger indent = TDLeadingSpaceCount(line);
  NSString *rest = [line substringFromIndex: indent];
  BOOL done;

  if ([rest hasPrefix: @"- [ ] "])
    {
      done = NO;
      rest = [rest substringFromIndex: 6];
    }
  else if ([rest hasPrefix: @"- [x] "])
    {
      done = YES;
      rest = [rest substringFromIndex: 6];
    }
  else if ([rest isEqualToString: @"- [ ]"])
    {
      done = NO;
      rest = @"";
    }
  else if ([rest isEqualToString: @"- [x]"])
    {
      done = YES;
      rest = @"";
    }
  else
    {
      return NO;
    }

  *outIndent = indent;
  *outDone = done;
  *outBody = rest;
  return YES;
}

/* Splits the "!important" and "@YYYY-MM-DD" tokens out of a task body,
 * whitespace-delimited and order-independent, leaving the plain title. */
static void
TDExtractMarkers(NSString *body, NSString **outTitle, BOOL *outImportant, NSString **outDueDate)
{
  NSArray *tokens = [body componentsSeparatedByString: @" "];
  NSMutableArray *titleTokens = [NSMutableArray array];
  BOOL important = NO;
  NSString *dueDate = nil;

  for (NSString *tok in tokens)
    {
      if ([tok length] == 0)
        {
          continue;
        }
      if ([tok isEqualToString: @"!important"])
        {
          important = YES;
          continue;
        }
      if ([tok hasPrefix: @"@"] && [tok length] == 11)
        {
          dueDate = [tok substringFromIndex: 1];
          continue;
        }
      [titleTokens addObject: tok];
    }

  *outTitle = [titleTokens componentsJoinedByString: @" "];
  *outImportant = important;
  *outDueDate = dueDate;
}

static void
TDAppendTaskLine(NSMutableString *out, TDTask *task, NSUInteger indent)
{
  [out appendString: (indent == 0) ? @"" : @"  "];
  [out appendString: [task isDone] ? @"- [x] " : @"- [ ] "];
  [out appendString: [task title]];
  if ([task isImportant])
    {
      [out appendString: @" !important"];
    }
  if ([task dueDate] != nil)
    {
      [out appendFormat: @" @%@", [task dueDate]];
    }
  [out appendString: @"\n"];

  if ([task notes] != nil && [[task notes] length] > 0)
    {
      NSString *notePad = (indent == 0) ? @"    " : @"      ";
      NSArray *noteLines = [[task notes] componentsSeparatedByString: @"\n"];

      for (NSString *nl in noteLines)
        {
          [out appendString: notePad];
          [out appendString: nl];
          [out appendString: @"\n"];
        }
    }
}

@implementation TDMarkdownCodec

+ (TDList *)listFromMarkdown: (NSString *)markdown name: (NSString *)name
{
  TDList *list = [TDList listWithName: name];
  NSArray *lines = [markdown componentsSeparatedByString: @"\n"];
  NSUInteger count = [lines count];
  NSUInteger i;

  TDTask *currentTop = nil;
  TDTask *noteOwner = nil;
  NSUInteger noteIndentThreshold = 0;
  NSMutableArray *noteLines = nil;

  for (i = 0; i < count; i++)
    {
      NSString *line = [lines objectAtIndex: i];
      NSUInteger indent;
      BOOL done;
      NSString *body;

      if (TDParseTaskLine(line, &indent, &done, &body) && (indent == 0 || indent == 2))
        {
          NSString *title;
          BOOL important;
          NSString *dueDate;
          TDTask *task;

          if (noteOwner != nil && noteLines != nil)
            {
              [noteOwner setNotes: [noteLines componentsJoinedByString: @"\n"]];
              [noteLines release];
              noteLines = nil;
            }
          noteOwner = nil;

          TDExtractMarkers(body, &title, &important, &dueDate);

          task = [TDTask taskWithTitle: title];
          [task setDone: done];
          [task setImportant: important];
          [task setDueDate: dueDate];

          if (indent == 0)
            {
              [[list tasks] addObject: task];
              currentTop = task;
              noteOwner = task;
              noteIndentThreshold = 4;
            }
          else if (currentTop != nil)
            {
              /* A subtask with no owning task above it is malformed
               * input; only attach it when an owner is on record. */
              [[currentTop subtasks] addObject: task];
              noteOwner = task;
              noteIndentThreshold = 6;
            }
          continue;
        }

      {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]];
        NSUInteger lineIndent = TDLeadingSpaceCount(line);

        if ([trimmed length] == 0)
          {
            if (noteOwner != nil && noteLines != nil)
              {
                [noteOwner setNotes: [noteLines componentsJoinedByString: @"\n"]];
                [noteLines release];
                noteLines = nil;
              }
            noteOwner = nil;
            continue;
          }

        if ([trimmed hasPrefix: @"# "])
          {
            /* Heading; the caller supplies the list's real name. */
            continue;
          }

        if (noteOwner != nil && lineIndent >= noteIndentThreshold)
          {
            if (noteLines == nil)
              {
                noteLines = [[NSMutableArray alloc] init];
              }
            [noteLines addObject: trimmed];
            continue;
          }

        /* Not part of the documented format; skip rather than guess. */
      }
    }

  if (noteOwner != nil && noteLines != nil)
    {
      [noteOwner setNotes: [noteLines componentsJoinedByString: @"\n"]];
      [noteLines release];
      noteLines = nil;
    }

  return list;
}

+ (TDTask *)taskFromInlineText: (NSString *)text
{
  NSString *title;
  BOOL important;
  NSString *dueDate;
  TDTask *task;

  TDExtractMarkers(text, &title, &important, &dueDate);
  task = [TDTask taskWithTitle: title];
  [task setImportant: important];
  [task setDueDate: dueDate];
  return task;
}

+ (NSString *)markdownFromList: (TDList *)list
{
  NSMutableString *out = [NSMutableString string];

  [out appendFormat: @"# %@\n\n", [list name]];
  for (TDTask *task in [list tasks])
    {
      TDAppendTaskLine(out, task, 0);
      for (TDTask *sub in [task subtasks])
        {
          TDAppendTaskLine(out, sub, 2);
        }
    }
  return out;
}

@end
