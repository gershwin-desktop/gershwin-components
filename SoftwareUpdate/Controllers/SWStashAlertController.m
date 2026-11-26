/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWStashAlertController.h"

@implementation SWStashConflict
@end

@implementation SWStashAlertController

+ (void)presentIfNeededForConflicts:(NSArray<SWStashConflict *> *)conflicts
{
  if ([conflicts count] == 0) return;

  NSString *message;
  if ([conflicts count] == 1) {
    message = [NSString stringWithFormat:@"Your local changes to %@ could not be re-applied.",
                [conflicts[0] repositoryName]];
  } else {
    NSArray *names = [conflicts valueForKey:@"repositoryName"];
    NSString *joined;
    if ([names count] == 2) {
      joined = [names componentsJoinedByString:@" and "];
    } else {
      NSArray *allButLast = [names subarrayWithRange:NSMakeRange(0, [names count] - 1)];
      joined = [NSString stringWithFormat:@"%@, and %@",
                 [allButLast componentsJoinedByString:@", "], [names lastObject]];
    }
    message = [NSString stringWithFormat:@"Your local changes to %lu repositories could not be re-applied.",
                (unsigned long)[conflicts count]];
    message = [message stringByAppendingFormat:@" (%@)", joined];
  }

  NSMutableArray *fileLines = [NSMutableArray array];
  for (SWStashConflict *conflict in conflicts) {
    if ([[conflict conflictedFiles] count] > 0) {
      [fileLines addObject:[NSString stringWithFormat:@"%@: %@", [conflict repositoryName],
        [[conflict conflictedFiles] componentsJoinedByString:@", "]]];
    }
  }
  NSString *informative = [fileLines componentsJoinedByString:@"\n"];
  informative = [informative stringByAppendingString:
    ([informative length] > 0 ? @"\n\nNothing was lost; the changes are kept in a git stash." :
      @"Nothing was lost; the changes are kept in a git stash.")];

  SWStashConflict *first = conflicts[0];
  BOOL keepShowing = YES;
  while (keepShowing) {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:message];
    [alert setInformativeText:informative];
    // Cocoa/GNUstep render the first-added button rightmost and default, so
    // Continue is added first to land on the right as the default action.
    [alert addButtonWithTitle:@"Continue"];
    [alert addButtonWithTitle:@"Show in Workspace"];

    NSInteger response = [alert runModal];
    if (response == NSAlertSecondButtonReturn) {
      [[NSWorkspace sharedWorkspace] selectFile:[first repositoryPath]
                        inFileViewerRootedAtPath:@""];
    } else {
      keepShowing = NO;
    }
  }
}

@end
