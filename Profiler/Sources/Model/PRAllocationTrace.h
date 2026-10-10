/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* One place in the program that asked the kernel for a large piece of
   memory, and how much it asked for while it was watched. */
@interface PRAllocationSite : NSObject
/* Innermost frame first, as the profiling tool printed them. */
@property (nonatomic, copy) NSArray *frames;
@property (nonatomic, assign) unsigned long long byteCount;
@property (nonatomic, assign) NSUInteger count;
/* The frames worth showing: the allocator's own machinery is dropped, so
   the first line is the code that wanted the memory. */
- (NSArray *)tellingFrames;
@end

/* Watches a running process for large allocations and says where they come
   from. Nothing is put into the process and nothing is recorded inside it:
   the kernel reports the mappings it is asked for, which is why this works
   on a program that has been running for days.

   Large is the point. A leak of many small pieces shows up as a class in
   the object census; a leak of a few big ones - decoded images, buffers,
   whole files read into memory - shows up here, and nowhere else. */
@interface PRAllocationTrace : NSObject

/* Reads what "perf script" printed for the mmap tracepoint. */
+ (NSArray *)sitesFromPerfScript:(NSString *)text;

/* Records for the given time and returns the sites, heaviest first.
   Needs perf and the rights to trace that process. */
+ (NSArray *)sitesForProcess:(pid_t)pid
                     minimum:(unsigned long long)minimumBytes
                     seconds:(NSTimeInterval)seconds
                       error:(NSError **)error;

@end
