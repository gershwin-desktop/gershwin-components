/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRRecorder.h"

/* What a concrete recorder implements, and what the base class offers it. */
@interface PRRecorder (Subclass)

/* Starts the external tool and stores its NSTask in _recordTask and the
   file it writes in _dataPath. */
- (BOOL)launchRecordTaskWithError:(NSError **)error;
/* YES when the recording tool has to run as root. */
- (BOOL)recordNeedsElevation;
/* Turns the recorded data into a profile. Runs on a worker thread. */
- (PRProfile *)analyzeWithError:(NSError **)error;

- (void)beginAnalysis;
- (void)reportStatus:(NSString *)status;
- (BOOL)failWithMessage:(NSString *)message error:(NSError **)error;
/* Everything the tool wrote to its error output. */
- (NSString *)toolLog;
- (NSFileHandle *)logFileHandle;

/* Runs a tool to completion, handing every line of its output to the
   block. Used for the decoding step. */
- (BOOL)runTool:(NSString *)toolPath
      arguments:(NSArray *)arguments
       elevated:(BOOL)elevated
    lineHandler:(void (^)(NSString *line))lineHandler
          error:(NSError **)error;

@end
