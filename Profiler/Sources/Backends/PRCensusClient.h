/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class PRCensusSnapshot;

/* Starts a program with the counting library in place and asks it, again and
   again, how many objects of every class it holds.

   The library has to be there before the first object is made, so the
   program is started by us; a program that is already running cannot be
   counted this way. */
@interface PRCensusClient : NSObject
{
    NSTask *_task;
    NSString *_socketDirectory;
    NSString *_socketPath;
}

/* Where the counting library is installed. */
+ (NSString *)libraryPath;
+ (BOOL)isLibraryInstalled;

- (BOOL)startProgram:(NSString *)path
           arguments:(NSArray *)arguments
               error:(NSError **)error;

/* Asks the program for a count. Returns nil once it has ended. */
- (PRCensusSnapshot *)takeSnapshotWithError:(NSError **)error;

- (BOOL)isRunning;
- (void)stop;

@property (nonatomic, readonly) int processIdentifier;

@end
