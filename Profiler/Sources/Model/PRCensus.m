/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRCensus.h"

@implementation PRCensusRow
@synthesize className = _className;
@synthesize live = _live;
@synthesize peak = _peak;
@synthesize total = _total;
@synthesize change = _change;

- (id)copyWithZone:(NSZone *)zone
{
    (void)zone;
    PRCensusRow *copy = [[PRCensusRow alloc] init];
    [copy setClassName:_className];
    [copy setLive:_live];
    [copy setPeak:_peak];
    [copy setTotal:_total];
    [copy setChange:_change];
    return copy;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ %ld alive", _className, (long)_live];
}
@end

@implementation PRCensusSnapshot

@synthesize rows = _rows;
@synthesize takenAt = _takenAt;

+ (PRCensusSnapshot *)snapshotFromText:(NSString *)text
{
    PRCensusSnapshot *snapshot = [[PRCensusSnapshot alloc] init];
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableDictionary *byName = [NSMutableDictionary dictionary];
    /* -invertedSet copies the whole Unicode bitmap, some 139 KB, and this
       runs for every field of every class in the census. */
    NSCharacterSet *nonDigits = [[NSCharacterSet characterSetWithCharactersInString:
                                  @"-0123456789"] invertedSet];

    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if ([line length] == 0 || [line isEqualToString:@"."])
            continue;

        /* "live peak total class name", and a class name may hold spaces.
           A program that cannot be counted says so in words, which must not
           be mistaken for a class. */
        NSArray *fields = [line componentsSeparatedByString:@" "];
        if ([fields count] < 4)
            continue;

        BOOL counts = YES;
        for (NSUInteger field = 0; field < 3; field++) {
            NSString *value = [fields objectAtIndex:field];
            if ([value length] == 0 ||
                [value rangeOfCharacterFromSet:nonDigits].location
                != NSNotFound)
                counts = NO;
        }
        if (!counts)
            continue;

        NSString *name = [[fields subarrayWithRange:
                           NSMakeRange(3, [fields count] - 3)]
                          componentsJoinedByString:@" "];
        if ([name length] == 0)
            continue;

        PRCensusRow *row = [[PRCensusRow alloc] init];
        [row setClassName:name];
        [row setLive:[[fields objectAtIndex:0] integerValue]];
        [row setPeak:[[fields objectAtIndex:1] integerValue]];
        [row setTotal:[[fields objectAtIndex:2] integerValue]];
        [rows addObject:row];
        [byName setObject:row forKey:name];
    }

    snapshot->_rows = [rows copy];
    snapshot->_rowsByName = [byName copy];
    snapshot->_takenAt = [NSDate date];
    return snapshot;
}

- (NSInteger)liveTotal
{
    NSInteger sum = 0;
    for (PRCensusRow *row in _rows)
        sum += [row live];
    return sum;
}

- (PRCensusRow *)rowForClassName:(NSString *)className
{
    return [_rowsByName objectForKey:className];
}

- (NSArray *)rowsComparedWith:(PRCensusSnapshot *)baseline
{
    NSMutableArray *result = [NSMutableArray array];

    for (PRCensusRow *row in _rows) {
        PRCensusRow *compared = [row copy];
        PRCensusRow *before = [baseline rowForClassName:[row className]];
        [compared setChange:[row live] - [before live]];
        [result addObject:compared];
    }

    /* A class whose last object has gone is no longer reported by the
       program, and its loss is exactly what the reader is looking for. */
    for (PRCensusRow *before in [baseline rows]) {
        if ([self rowForClassName:[before className]] != nil)
            continue;
        PRCensusRow *gone = [before copy];
        [gone setLive:0];
        [gone setChange:-[before live]];
        [result addObject:gone];
    }

    return [result sortedArrayUsingComparator:
            ^NSComparisonResult(PRCensusRow *a, PRCensusRow *b) {
        if ([a change] > [b change]) return NSOrderedAscending;
        if ([a change] < [b change]) return NSOrderedDescending;
        if ([a live] > [b live]) return NSOrderedAscending;
        if ([a live] < [b live]) return NSOrderedDescending;
        return [[a className] compare:[b className]];
    }];
}

@end
