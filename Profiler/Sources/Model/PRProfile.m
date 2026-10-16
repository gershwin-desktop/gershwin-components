/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRProfile.h"
#import "PRSymbol.h"
#import "PRCallNode.h"

typedef struct {
    double time;
    double weight;
    int32_t thread;
    uint32_t frameOffset;
    uint32_t frameCount;
} PRSampleRecord;

@implementation PRAggregateRow
@end

@implementation PRProfile

@synthesize totalWeight = _totalWeight;
@synthesize startTime = _startTime;
@synthesize endTime = _endTime;

- (id)init
{
    self = [super init];
    if (self == nil)
        return nil;
    _symbols = [[NSMutableArray alloc] init];
    _symbolIndex = [[NSMutableDictionary alloc] init];
    _frames = [[NSMutableData alloc] init];
    _samples = [[NSMutableData alloc] init];
    _threadNames = [[NSMutableDictionary alloc] init];
    _startTime = INFINITY;
    _endTime = -INFINITY;
    _costUnit = PRCostUnitSamples;
    return self;
}

- (NSUInteger)sampleCount
{
    return [_samples length] / sizeof(PRSampleRecord);
}

- (NSUInteger)symbolCount
{
    return [_symbols count];
}

- (PRSymbol *)symbolWithName:(NSString *)name modulePath:(NSString *)modulePath
{
    if (name == nil)
        name = @"[unknown]";
    if (modulePath == nil)
        modulePath = @"[unknown]";

    NSString *key = [NSString stringWithFormat:@"%@\n%@", name, modulePath];
    PRSymbol *symbol = [_symbolIndex objectForKey:key];
    if (symbol != nil)
        return symbol;

    symbol = [[PRSymbol alloc] initWithIndex:[_symbols count]
                                     rawName:name
                                  modulePath:modulePath];
    [_symbols addObject:symbol];
    [_symbolIndex setObject:symbol forKey:key];
    return symbol;
}

- (void)addSampleWithFrames:(const uint32_t *)frameIndices
                      count:(NSUInteger)count
                     weight:(double)weight
                       time:(double)time
                     thread:(int32_t)thread
{
    PRSampleRecord record;
    record.time = time;
    record.weight = weight;
    record.thread = thread;
    record.frameOffset = (uint32_t)([_frames length] / sizeof(uint32_t));
    record.frameCount = (uint32_t)count;

    [_frames appendBytes:frameIndices length:count * sizeof(uint32_t)];
    [_samples appendBytes:&record length:sizeof(record)];

    _totalWeight += weight;
    if (!isnan(time)) {
        if (time < _startTime) _startTime = time;
        if (time > _endTime) _endTime = time;
    }
}

- (void)addSampleWithSymbols:(NSArray *)symbolsOutermostFirst
                      weight:(double)weight
                        time:(double)time
                      thread:(int32_t)thread
{
    NSUInteger count = [symbolsOutermostFirst count];
    uint32_t stackBuffer[256];
    uint32_t *indices = stackBuffer;
    if (count > 256)
        indices = malloc(count * sizeof(uint32_t));

    NSUInteger i = 0;
    for (PRSymbol *symbol in symbolsOutermostFirst)
        indices[i++] = (uint32_t)[symbol index];

    [self addSampleWithFrames:indices count:count weight:weight
                         time:time thread:thread];
    if (indices != stackBuffer)
        free(indices);
}

- (void)setName:(NSString *)name forThread:(int32_t)thread
{
    [_threadNames setObject:name forKey:[NSNumber numberWithInt:thread]];
}

- (NSString *)nameForThread:(int32_t)thread
{
    return [_threadNames objectForKey:[NSNumber numberWithInt:thread]];
}

- (double)weightOfThread:(int32_t)thread
{
    const PRSampleRecord *records = (const PRSampleRecord *)[_samples bytes];
    NSUInteger count = [self sampleCount];
    double total = 0;
    for (NSUInteger i = 0; i < count; i++)
        if (records[i].thread == thread)
            total += records[i].weight;
    return total;
}

- (NSArray *)threads
{
    const PRSampleRecord *records = (const PRSampleRecord *)[_samples bytes];
    NSUInteger count = [self sampleCount];
    NSMutableDictionary *weights = [NSMutableDictionary dictionary];

    for (NSUInteger i = 0; i < count; i++) {
        NSNumber *key = [NSNumber numberWithInt:records[i].thread];
        double sum = [[weights objectForKey:key] doubleValue] + records[i].weight;
        [weights setObject:[NSNumber numberWithDouble:sum] forKey:key];
    }

    return [[weights allKeys] sortedArrayUsingComparator:
            ^NSComparisonResult(NSNumber *a, NSNumber *b) {
        double wa = [[weights objectForKey:a] doubleValue];
        double wb = [[weights objectForKey:b] doubleValue];
        if (wa > wb) return NSOrderedAscending;
        if (wa < wb) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

- (BOOL)sample:(const PRSampleRecord *)record
     matchesRange:(PRTimeRange)range
           thread:(int32_t)thread
{
    if (thread != PR_ALL_THREADS && record->thread != thread)
        return NO;
    if (PRTimeRangeIsAll(range) || isnan(record->time))
        return YES;
    return PRTimeRangeContains(range, record->time);
}

- (double)weightInRange:(PRTimeRange)range thread:(int32_t)thread
{
    const PRSampleRecord *records = (const PRSampleRecord *)[_samples bytes];
    NSUInteger count = [self sampleCount];
    double total = 0;
    for (NSUInteger i = 0; i < count; i++)
        if ([self sample:&records[i] matchesRange:range thread:thread])
            total += records[i].weight;
    return total;
}

- (PRCallNode *)callTreeInverted:(BOOL)inverted
                           range:(PRTimeRange)range
                          thread:(int32_t)thread
{
    const PRSampleRecord *records = (const PRSampleRecord *)[_samples bytes];
    const uint32_t *frames = (const uint32_t *)[_frames bytes];
    NSUInteger count = [self sampleCount];
    NSString *label = [self title] ? [self title] : @"All stacks";
    PRCallNode *root = [[PRCallNode alloc] initWithSymbol:nil label:label];

    for (NSUInteger i = 0; i < count; i++) {
        const PRSampleRecord *record = &records[i];
        if (![self sample:record matchesRange:range thread:thread])
            continue;
        if (record->frameCount == 0)
            continue;

        double weight = record->weight;
        [root addTotalWeight:weight];

        PRCallNode *node = root;
        for (uint32_t f = 0; f < record->frameCount; f++) {
            /* Stacks are stored outermost first; the bottom up tree walks
               them from the leaf, so the function that actually burned the
               cost becomes the root of its own branch. */
            uint32_t position = inverted ? record->frameCount - 1 - f : f;
            PRSymbol *symbol = [_symbols objectAtIndex:
                                frames[record->frameOffset + position]];
            node = [node childForSymbol:symbol];
            [node addTotalWeight:weight];
        }
        [node addSelfWeight:weight];
    }

    [root addSelfWeight:0];
    [root sortRecursively];
    return root;
}

- (NSArray *)aggregateByGrouping:(PRGrouping)grouping
                           range:(PRTimeRange)range
                          thread:(int32_t)thread
{
    const PRSampleRecord *records = (const PRSampleRecord *)[_samples bytes];
    const uint32_t *frames = (const uint32_t *)[_frames bytes];
    NSUInteger count = [self sampleCount];
    NSMutableDictionary *rows = [NSMutableDictionary dictionary];
    /* A key seen twice in one stack (recursion) must add to the inclusive
       cost only once, so remember which keys this sample already counted. */
    NSMutableSet *seen = [NSMutableSet set];

    for (NSUInteger i = 0; i < count; i++) {
        const PRSampleRecord *record = &records[i];
        if (![self sample:record matchesRange:range thread:thread])
            continue;
        if (record->frameCount == 0)
            continue;

        [seen removeAllObjects];
        double weight = record->weight;

        /* A thread is a property of the whole sample, not of its frames. */
        if (grouping == PRGroupingThread) {
            NSString *key = [NSString stringWithFormat:@"t:%d", record->thread];
            PRAggregateRow *row = [rows objectForKey:key];
            if (row == nil) {
                NSString *name = [self nameForThread:record->thread];
                row = [[PRAggregateRow alloc] init];
                [row setName:[NSString stringWithFormat:@"%@ (%d)",
                              name ? name : @"thread", record->thread]];
                [row setDetail:@""];
                [rows setObject:row forKey:key];
            }
            [row setSelfWeight:[row selfWeight] + weight];
            [row setTotalWeight:[row totalWeight] + weight];
            continue;
        }

        for (uint32_t f = 0; f < record->frameCount; f++) {
            PRSymbol *symbol = [_symbols objectAtIndex:
                                frames[record->frameOffset + f]];
            NSString *key = nil;
            NSString *name = nil;
            NSString *detail = nil;

            switch (grouping) {
                case PRGroupingClass:
                    name = [symbol className];
                    if (name == nil)
                        name = [symbol moduleName];
                    detail = [symbol className] ? @"Objective-C class" : @"C functions";
                    key = [NSString stringWithFormat:@"c:%@", name];
                    break;
                case PRGroupingModule:
                    name = [symbol moduleName];
                    detail = [symbol modulePath];
                    key = [NSString stringWithFormat:@"m:%@", name];
                    break;
                case PRGroupingFunction:
                default:
                    name = [symbol displayName];
                    detail = [symbol moduleName];
                    key = [NSString stringWithFormat:@"f:%lu",
                           (unsigned long)[symbol index]];
                    break;
            }

            PRAggregateRow *row = [rows objectForKey:key];
            if (row == nil) {
                row = [[PRAggregateRow alloc] init];
                [row setName:name];
                [row setDetail:detail];
                if (grouping == PRGroupingFunction)
                    [row setSymbol:symbol];
                [rows setObject:row forKey:key];
            }
            if (![seen containsObject:key]) {
                [seen addObject:key];
                [row setTotalWeight:[row totalWeight] + weight];
            }
            if (f + 1 == record->frameCount)
                [row setSelfWeight:[row selfWeight] + weight];
        }
    }

    return [[rows allValues] sortedArrayUsingComparator:
            ^NSComparisonResult(PRAggregateRow *a, PRAggregateRow *b) {
        if ([a selfWeight] > [b selfWeight]) return NSOrderedAscending;
        if ([a selfWeight] < [b selfWeight]) return NSOrderedDescending;
        return [[a name] localizedCaseInsensitiveCompare:[b name]];
    }];
}

- (BOOL)writeFoldedStacksToPath:(NSString *)path error:(NSError **)error
{
    const PRSampleRecord *records = (const PRSampleRecord *)[_samples bytes];
    const uint32_t *frames = (const uint32_t *)[_frames bytes];
    NSUInteger count = [self sampleCount];
    /* Samples that ran through the same stack become one line with their
       costs added up, which is what the folded stack format is for. */
    NSMutableDictionary *weights = [NSMutableDictionary dictionary];
    NSMutableArray *order = [NSMutableArray array];

    for (NSUInteger i = 0; i < count; i++) {
        const PRSampleRecord *record = &records[i];
        NSMutableString *stack = [NSMutableString string];

        for (uint32_t f = 0; f < record->frameCount; f++) {
            PRSymbol *symbol = [_symbols objectAtIndex:
                                frames[record->frameOffset + f]];
            if (f > 0)
                [stack appendString:@";"];
            [stack appendString:[symbol displayName]];
        }

        NSNumber *previous = [weights objectForKey:stack];
        if (previous == nil)
            [order addObject:stack];
        [weights setObject:[NSNumber numberWithDouble:
                            [previous doubleValue] + record->weight]
                    forKey:stack];
    }

    NSMutableString *text = [NSMutableString string];
    for (NSString *stack in order)
        [text appendFormat:@"%@ %.0f\n", stack,
         [[weights objectForKey:stack] doubleValue]];

    return [text writeToFile:path
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:error];
}

- (NSArray *)timelineWithBucketCount:(NSUInteger)buckets
{
    if (buckets == 0 || [self sampleCount] == 0 || _endTime <= _startTime)
        return [NSArray array];

    const PRSampleRecord *records = (const PRSampleRecord *)[_samples bytes];
    NSUInteger count = [self sampleCount];
    double span = _endTime - _startTime;
    double *sums = calloc(buckets, sizeof(double));

    for (NSUInteger i = 0; i < count; i++) {
        if (isnan(records[i].time))
            continue;
        NSUInteger bucket = (NSUInteger)((records[i].time - _startTime) / span *
                                         (double)(buckets - 1));
        if (bucket >= buckets)
            bucket = buckets - 1;
        sums[bucket] += records[i].weight;
    }

    NSMutableArray *result = [NSMutableArray arrayWithCapacity:buckets];
    for (NSUInteger i = 0; i < buckets; i++)
        [result addObject:[NSNumber numberWithDouble:sums[i]]];
    free(sums);
    return result;
}

@end
