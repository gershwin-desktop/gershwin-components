/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "PRTypes.h"

@class PRSymbol;
@class PRCallNode;

/* One row of the flat cost list. */
@interface PRAggregateRow : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, strong) PRSymbol *symbol;
@property (nonatomic, assign) double selfWeight;
@property (nonatomic, assign) double totalWeight;
@end

/* A recorded profile: weighted call stacks, whatever tool produced them.
   CPU sampling contributes one sample of weight 1 per timer tick, heap
   profiling one entry per allocation site weighted by bytes, so every view
   works the same way for both. */
@interface PRProfile : NSObject
{
    NSMutableArray *_symbols;
    NSMutableDictionary *_symbolIndex;
    NSMutableData *_frames;
    NSMutableData *_samples;
    NSMutableDictionary *_threadNames;
    double _totalWeight;
    double _startTime;
    double _endTime;
}

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *command;
@property (nonatomic, copy) NSString *toolDescription;
@property (nonatomic, copy) NSString *summaryText;
@property (nonatomic, strong) NSDate *recordedAt;
@property (nonatomic, assign) PRCostUnit costUnit;

/* Memory profiles come with their own consumption curve because the
   allocation stacks themselves carry no time. Array of PRTimelinePoint
   boxed as NSDictionary { "time", "value" }. */
@property (nonatomic, copy) NSArray *memoryTimeline;

@property (nonatomic, readonly) double totalWeight;
@property (nonatomic, readonly) NSUInteger sampleCount;
@property (nonatomic, readonly) double startTime;
@property (nonatomic, readonly) double endTime;
@property (nonatomic, readonly) NSUInteger symbolCount;

/* Interning: equal name and module always yield the same object. */
- (PRSymbol *)symbolWithName:(NSString *)name modulePath:(NSString *)modulePath;

/* Stacks are passed outermost frame first. */
- (void)addSampleWithFrames:(const uint32_t *)frameIndices
                      count:(NSUInteger)count
                     weight:(double)weight
                       time:(double)time
                     thread:(int32_t)thread;
- (void)addSampleWithSymbols:(NSArray *)symbolsOutermostFirst
                      weight:(double)weight
                        time:(double)time
                      thread:(int32_t)thread;

- (void)setName:(NSString *)name forThread:(int32_t)thread;
- (NSString *)nameForThread:(int32_t)thread;
/* Thread ids that contributed samples, heaviest first. */
- (NSArray *)threads;
- (double)weightOfThread:(int32_t)thread;

- (PRCallNode *)callTreeInverted:(BOOL)inverted
                           range:(PRTimeRange)range
                          thread:(int32_t)thread;

- (NSArray *)aggregateByGrouping:(PRGrouping)grouping
                           range:(PRTimeRange)range
                          thread:(int32_t)thread;

/* Cost per time bucket, for the timeline strip. */
- (NSArray *)timelineWithBucketCount:(NSUInteger)buckets;

/* Cost inside the window, for the "x% of the recording" readouts. */
- (double)weightInRange:(PRTimeRange)range thread:(int32_t)thread;

/* Writes the samples as folded stacks, the format the FlameGraph scripts
   and heaptrack use, so a recording can be kept and looked at again. */
- (BOOL)writeFoldedStacksToPath:(NSString *)path error:(NSError **)error;

@end
