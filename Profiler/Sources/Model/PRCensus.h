/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* How many objects of one class a program holds. */
@interface PRCensusRow : NSObject
@property (nonatomic, copy) NSString *className;
/* Alive at the moment of the count. */
@property (nonatomic, assign) NSInteger live;
/* The most that were ever alive at the same time, and how many were ever
   created; together they tell a leak apart from mere churn. */
@property (nonatomic, assign) NSInteger peak;
@property (nonatomic, assign) NSInteger total;
/* Filled in when the row is compared with an earlier count. */
@property (nonatomic, assign) NSInteger change;
@end

/* One count of everything a program holds, as the counting library reports
   it: a line of "live peak total class" per class, closed by a full stop. */
@interface PRCensusSnapshot : NSObject
{
    NSArray *_rows;
    NSDictionary *_rowsByName;
    NSDate *_takenAt;
}

+ (PRCensusSnapshot *)snapshotFromText:(NSString *)text;

@property (nonatomic, readonly, copy) NSArray *rows;
@property (nonatomic, readonly, strong) NSDate *takenAt;
/* Objects alive in the whole program, the number that has to stop growing. */
@property (nonatomic, readonly) NSInteger liveTotal;

- (PRCensusRow *)rowForClassName:(NSString *)className;

/* This count with every row's change against an earlier one, heaviest
   growth first. A class that has appeared since counts as grown by all of
   its objects; one that has vanished is reported with its loss. */
- (NSArray *)rowsComparedWith:(PRCensusSnapshot *)baseline;

@end
