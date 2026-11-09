/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* Finds command line tools without relying on the inherited PATH, which a
   GUI process started from the workspace may not have. */
@interface PRToolLocator : NSObject
+ (NSString *)pathForTool:(NSString *)name;
@end

/* Sampling the kernel's performance counters and attaching to a foreign
   process both need root. A GUI process owns no terminal, so the password
   is collected by the askpass helper named in SUDO_ASKPASS, the only sudo
   mode that can work from here. */
@interface PRPrivilegedTask : NSObject

+ (BOOL)isRoot;
+ (BOOL)isElevationAvailable;

/* In a terminal sudo can ask for the password itself, so no graphical
   helper is needed; the command line tool says so at startup. A program
   with no terminal must not be allowed to block on a prompt nobody can
   answer, which is why this is off by default. */
+ (void)setMayAskOnTerminal:(BOOL)flag;
/* Why elevation cannot work, for the error message. */
+ (NSString *)elevationProblem;

/* Wraps tool and arguments in sudo when the current user is not root. */
+ (NSTask *)taskForTool:(NSString *)toolPath
              arguments:(NSArray *)arguments
               elevated:(BOOL)elevated;

/* Runs a short command and waits for it. Returns the exit status. */
+ (int)runTool:(NSString *)toolPath
     arguments:(NSArray *)arguments
      elevated:(BOOL)elevated;

@end
