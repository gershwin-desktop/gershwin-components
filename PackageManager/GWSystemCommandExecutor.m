/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWSystemCommandExecutor - NSTask-based implementation of the
 * GWSystemCommandExecutor protocol. Runs system commands and captures
 * their output.
 */

#import "GWSystemCommandExecutor.h"

@implementation GWSystemCommandExecutor

static GWSystemCommandExecutor *sharedExecutor = nil;

+ (GWSystemCommandExecutor *)sharedExecutor
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedExecutor = [[self alloc] init];
  });
  return sharedExecutor;
}

- (int)execute:(NSString *)path arguments:(NSArray *)args
{
  return [self execute:path arguments:args output:nil errorOutput:nil];
}

- (int)execute:(NSString *)path arguments:(NSArray *)args
        output:(NSString *__autoreleasing *)output
{
  return [self execute:path arguments:args output:output errorOutput:nil];
}

- (int)execute:(NSString *)path arguments:(NSArray *)args
        output:(NSString *__autoreleasing *)output
  errorOutput:(NSString *__autoreleasing *)errorOutput
{
  NSLog(@"GWSystemCommandExecutor -> execute: %@ %@", path, [args componentsJoinedByString:@" "]);

  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:path];
  [task setArguments:args];

  NSPipe *outPipe = [NSPipe pipe];
  NSPipe *errPipe = [NSPipe pipe];
  [task setStandardOutput:outPipe];
  [task setStandardError:errPipe];

  @try
    {
      [task launch];
      [task waitUntilExit];

      int status = [task terminationStatus];

      if (output)
        {
          NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
          *output = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
          if (!*output) *output = @"";
        }

      if (errorOutput)
        {
          NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
          *errorOutput = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
          if (!*errorOutput) *errorOutput = @"";
        }

      // "output" is an out-parameter, and the two convenience selectors above
      // deliberately pass nil for it: a caller that only wants the exit status
      // (every backend's "is this package installed?" check) has nowhere to put
      // a string. Reading through it anyway dereferenced NULL and took the
      // whole process down - which, in an app that runs this during a
      // privileged update, meant the update simply stopped. Report zero
      // characters when nothing was captured.
      NSUInteger outputLength = (output && *output) ? [*output length] : 0;
      NSLog(@"GWSystemCommandExecutor <- exit code %d (output length: %lu chars)", status, (unsigned long)outputLength);
      return status;
    }
  @catch (NSException *e)
    {
      NSLog(@"GWSystemCommandExecutor [FAIL] exception executing %@: %@", path, e);
      if (output) *output = @"";
      if (errorOutput) *errorOutput = [NSString stringWithFormat:@"%@", e];
      return -1;
    }
}

- (int)execute:(NSString *)path
     arguments:(NSArray *)args
 stderrCallback:(void (^)(NSString *line))callback
 capturedErrorOutput:(NSString *__autoreleasing *)errorOutput
{
  return [self execute:path arguments:args
        stdoutCallback:nil
        stderrCallback:callback
  capturedErrorOutput:errorOutput];
}


/* Reads one pipe to EOF on its own thread, handing each complete line to emit
 * as it arrives and appending everything to captured (which may be NULL).
 *
 * A line is held back until its newline arrives, so a partial line is never
 * reported as if it were whole; a trailing fragment with no newline is still
 * reported when the stream ends.
 *
 * This replaced a dispatch source per pipe, and the reason it is worth
 * spelling out is that the obvious version of it hangs. The sources signalled
 * a semaphore from their CANCEL handler, which only runs once the source sees
 * EOF - and the only thing that sees EOF is a read() inside the event handler.
 * A blocking read that consumed the last of the output left the source needing
 * one more event to observe the close, and when that event did not arrive the
 * waiter sat on DISPATCH_TIME_FOREVER with no way out and no timeout to
 * rescue it. Measured, with the real executor on Linux:
 *
 *   execute:@"/bin/sh" arguments:@[@"-c", @"printf a"]       -> hung
 *   execute:@"/bin/sh" arguments:@[@"-c", @"exit 0"]         -> returned 0
 *
 * A command that writes nothing is the one case that happened to work, which
 * is why this survived: the install path only reaches it when a package is
 * genuinely being installed. The same shape is used for the build output in
 * Software Update's SWRepositoryUpdater. */
static void SWDrainPipeToLines(NSFileHandle *handle,
                                NSMutableString *captured,
                                void (^emit)(NSString *line))
{
  NSMutableString *pending = [NSMutableString string];
  while (YES)
    {
      NSData *chunk = nil;
      @try
        {
          chunk = [handle availableData];
        }
      @catch (NSException *exception)
        {
          break; // the handle was closed under us: treat it as end of stream
        }
      if ([chunk length] == 0) break; // EOF

      NSString *text = [[NSString alloc] initWithData:chunk
                                            encoding:NSUTF8StringEncoding];
      if (!text)
        {
          // Not valid UTF-8, which a compiler diagnostic full of raw bytes
          // can easily be. Keep the bytes rather than dropping the output.
          text = [[NSString alloc] initWithData:chunk
                                        encoding:NSISOLatin1StringEncoding];
        }
      if (!text) break;
      if (captured) [captured appendString:text];
      [pending appendString:text];

      NSRange newline;
      while ((newline = [pending rangeOfString:@"\n"]).location != NSNotFound)
        {
          NSString *line = [pending substringToIndex:newline.location];
          [pending deleteCharactersInRange:
            NSMakeRange(0, newline.location + 1)];
          line = [line stringByTrimmingCharactersInSet:
                   [NSCharacterSet characterSetWithCharactersInString:@"\r"]];
          if ([line length] > 0 && emit) emit(line);
        }
    }

  NSString *tail = [pending stringByTrimmingCharactersInSet:
                     [NSCharacterSet characterSetWithCharactersInString:@"\r"]];
  if ([tail length] > 0 && emit) emit(tail);
}

// Starts a reader thread and returns it, or nil if it could not be started
// (in which case the caller's own fallback read covers the same ground).
static NSThread *SWStartReader(NSFileHandle *handle,
                               NSMutableString *captured,
                               void (^emit)(NSString *line))
{
  NSThread *thread = [[NSThread alloc] initWithBlock:^{
    SWDrainPipeToLines(handle, captured, emit);
  }];
  [thread setName:@"GWSystemCommandExecutor.output"];
  [thread start];
  return thread;
}

- (int)execute:(NSString *)path
     arguments:(NSArray *)args
 stdoutCallback:(void (^)(NSString *line))stdoutCallback
 stderrCallback:(void (^)(NSString *line))stderrCallback
 capturedErrorOutput:(NSString *__autoreleasing *)errorOutput
{
  NSLog(@"GWSystemCommandExecutor -> execute (live both): %@ %@", path, [args componentsJoinedByString:@" "]);

  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:path];
  [task setArguments:args];

  NSPipe *outPipe = [NSPipe pipe];
  [task setStandardOutput:outPipe];
  NSFileHandle *outHandle = [outPipe fileHandleForReading];

  NSPipe *errPipe = [NSPipe pipe];
  [task setStandardError:errPipe];
  NSFileHandle *errHandle = [errPipe fileHandleForReading];

  NSMutableString *captured = [NSMutableString string];
  NSMutableString *outBuf = [NSMutableString string];
  NSMutableString *errBuf = [NSMutableString string];

  @try
    {
      [task launch];
    }
  @catch (NSException *e)
    {
      NSLog(@"GWSystemCommandExecutor [FAIL] exception executing %@: %@", path, e);
      if (errorOutput) *errorOutput = [captured copy];
      return -1;
    }

  // Read on background threads and wait for them here. The child is free to
  // fill a pipe while these drain it, so neither side can wedge, and each line
  // is delivered as it appears rather than at the end.
  NSThread *outReader =
    SWStartReader(outHandle, nil, ^(NSString *line) {
      @synchronized (outBuf) { [outBuf appendString:line]; [outBuf appendString:@"\n"]; }
      if (stdoutCallback) stdoutCallback(line);
    });
  NSThread *errReader =
    SWStartReader(errHandle, captured, ^(NSString *line) {
      @synchronized (errBuf) { [errBuf appendString:line]; [errBuf appendString:@"\n"]; }
      if (stderrCallback) stderrCallback(line);
    });

  [task waitUntilExit];

  // Both readers finish as soon as the child closes its ends, which is just
  // before waitUntilExit returns; give them a bounded grace period in case a
  // final read is still in flight, so a last line is not lost. A generous one:
  // by now the child has exited, so there is nothing left to read but the tail.
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
  while ([deadline timeIntervalSinceNow] > 0) {
    if (![outReader isFinished] || ![errReader isFinished]) {
      [NSThread sleepForTimeInterval:0.01];
    } else {
      break;
    }
  }

  // Flush partial final lines, then report.
  int status = [task terminationStatus];
  if (errorOutput)
    {
      @synchronized(captured)
        {
          *errorOutput = [captured copy];
        }
    }

  NSLog(@"GWSystemCommandExecutor <- exit code %d (stderr: %lu chars)", status, (unsigned long)[captured length]);
  return status;
}

@end
