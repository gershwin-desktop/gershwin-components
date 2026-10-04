/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Outcome of a completed external process run.
@interface DUProcessResult : NSObject

/* The process's EXIT CODE, as reported by -[NSTask terminationStatus].
 *
 * This is NOT the raw wait status, and WEXITSTATUS() must not be applied to
 * it: GNUstep's NSTask already decodes the waitpid status, so for an exit
 * code of 8 the property holds 8 while WEXITSTATUS(8) is 0 - which made every
 * failing tool below exit code 256 read as a success. Use
 * -exitedWithStatus: to test for a specific code. */
@property (nonatomic, readonly) int terminationStatus;

@property (nonatomic, readonly) NSString *standardOutput;
@property (nonatomic, readonly) NSString *standardError;
@property (nonatomic, readonly) BOOL exitedNormally;
@property (nonatomic, readonly) BOOL wasCancelled;
@property (nonatomic, readonly) BOOL timedOut;

// Whether the process exited of its own accord with the given exit code.
// This is the only correct way to read terminationStatus (see the property's
// comment): the value is already an exit code, not a wait status.
- (BOOL)exitedWithStatus:(int)status;

// Synthesized result used to report a refused privilege escalation through
// the same channel as a real run, so a caller that only receives a result
// cannot mistake "sudo never ran the tool" for "the tool found damage".
+ (DUProcessResult *)resultWithStandardOutput:(NSString *)standardOutput
                               standardError:(NSString *)standardError
                             terminationStatus:(int)terminationStatus
                               exitedNormally:(BOOL)exitedNormally
                                    timedOut:(BOOL)timedOut
                               wasCancelled:(BOOL)wasCancelled;

@end

// Handle for cancelling an in-flight streaming run. Safe to call from any
// thread; cancel is idempotent.
@interface DUProcessHandle : NSObject

// A process started through sudo runs as root, and the unprivileged app may
// not signal it; the authorization layer installs this to deliver the
// signal through an elevated kill instead.
@property (nonatomic, copy) void (^elevatedTerminate)(int processIdentifier);
@property (nonatomic, readonly) int processIdentifier;

- (void)cancel;

@end

// Synchronous NSTask wrapper used by backends from background threads.
//
// Security contract (ARCHITECTURE.md section 26):
//  - the executable is launched directly, never through a shell
//  - arguments are passed as an array, so user input can never gain shell
//    semantics
//  - callers pass absolute paths discovered via +executablePathForName:
//
// Threading contract: all methods BLOCK the calling thread. Backends must
// invoke them on background threads only (ARCHITECTURE.md section 53).
@interface DUProcessRunner : NSObject

// Locates an executable in a fixed set of system directories (never $PATH)
// so a caller-controlled PATH cannot redirect privileged operations.
+ (NSString *)executablePathForName:(NSString *)name;

// Runs to completion capturing both output streams concurrently so a full
// pipe cannot deadlock either side. On timeout the process is terminated.
// Returns nil only when the task could not be launched at all.
+ (DUProcessResult *)runExecutable:(NSString *)path
                         arguments:(NSArray<NSString *> *)arguments
                             error:(NSError **)error;

+ (DUProcessResult *)runExecutable:(NSString *)path
                         arguments:(NSArray<NSString *> *)arguments
                       environment:(NSDictionary<NSString *, NSString *> *)overrides
                           timeout:(NSTimeInterval)timeout
                             error:(NSError **)error;

// Streaming variant: stdoutLine fires per complete line on a reader thread;
// finish fires once with the final result. The handle allows cancellation.
+ (DUProcessHandle *)streamExecutable:(NSString *)path
                            arguments:(NSArray<NSString *> *)arguments
                          environment:(NSDictionary<NSString *, NSString *> *)overrides
                        stdoutHandler:(void (^)(NSString *line))stdoutHandler
                         finishHandler:(void (^)(DUProcessResult *result))finishHandler;

// Like streamExecutable:, but the child's stderr is redirected into the
// same pipe as its stdout, so lineHandler receives BOTH streams' lines in
// arrival order. Storage tools (dd, mkfs, fsck) report progress on stderr,
// so progress plumbing needs the merged view; the final result carries the
// merged text in standardOutput and leaves standardError empty.
+ (DUProcessHandle *)streamExecutableMergingErrorOutput:(NSString *)path
                                              arguments:(NSArray<NSString *> *)arguments
                                            environment:(NSDictionary<NSString *, NSString *> *)overrides
                                          stdoutHandler:(void (^)(NSString *line))stdoutHandler
                                         finishHandler:(void (^)(DUProcessResult *result))finishHandler;

@end
