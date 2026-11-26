/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SWRunGuard - keeps two Software Update runs from building /Developer at the
 * same time.
 *
 * Why this exists: every run builds in the source trees themselves, so two
 * runs configure and compile the same checkout at once and destroy each
 * other's work. Observed on the test box as libs-base failing with
 * "C compiler cannot create executables", which turned out to be two
 * configure runs sharing one conftest.c - one of them linked an empty file
 * with no main(). The build was fine; the concurrency was not.
 *
 * Why not the obvious alternatives:
 *
 * - A lock FILE is out. It outlives a crash by definition, so something else
 *   has to clean it up, and that something may be the thing that crashed.
 *
 * - A named POSIX semaphore (sem_open) looks ideal - a kernel object, no file
 *   - and is not. A *named* object is NOT released when its holder dies: only
 *   sem_unlink() removes it, and SIGKILL never runs that. Measured on the test
 *   box: after killing the holder, sem_trywait() still returned EBUSY forever,
 *   with nothing in the filesystem to find and clear. A lock that can wedge
 *   itself until reboot is worse than no lock.
 *
 * - Distributed notifications need gdomap and the DO machinery up and
 *   healthy; when they are not, "I cannot tell" is indistinguishable from
 *   "nobody is running", which fails open on the one thing that must not.
 *
 * What is left is the plainest thing with the property we actually need: a
 * crashed run must stop existing, and a live one must be visible. Both are
 * true of the process table and of nothing else here.
 */

#import <Foundation/Foundation.h>

@interface SWRunGuard : NSObject

// YES when no other run is in progress. On NO, outReason (if given) receives
// a sentence for the user naming the other run's process id.
//
// Deliberately fails OPEN - if the process list cannot be read, the run is
// allowed through. Refusing to update because ps is missing or unfamiliar
// would be a far worse failure than the concurrency being guarded against,
// and a damaged source tree is recoverable in a way a wedged lock is not.
+ (BOOL)acquireRunLockWithReason:(NSString **)outReason;

// The decision itself, over an arbitrary listing. Exposed so it can be tested
// against every process-list shape there is without having to arrange for one
// of them to be running, and so the caller can be handed a listing it read
// some other way.
//
// listing must be "<pid> <command line>" per line, which is what
// +processList is responsible for producing.
+ (BOOL)rejectListing:(NSString *)listing
           executable:(NSString *)executable
                selfPID:(pid_t)selfPID
                reason:(NSString **)outReason;

@end
