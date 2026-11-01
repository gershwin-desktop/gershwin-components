/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* What a piece of a program's memory is being used for. The kind is what
   turns a list of address ranges into an answer: heap and anonymous memory
   are the program's own doing, code and files are shared with every other
   program that mapped them. */
typedef enum {
    PRMemoryKindHeap = 0,
    PRMemoryKindStack,
    PRMemoryKindAnonymous,
    PRMemoryKindCode,
    PRMemoryKindFile,
    PRMemoryKindShared,
    PRMemoryKindSystem,
    PRMemoryKindCount
} PRMemoryKind;

/* The name of a kind as it is shown, e.g. "Heap". */
extern NSString *PRMemoryKindName(PRMemoryKind kind);
/* One line saying what that kind is, for the reader who is not sure. */
extern NSString *PRMemoryKindExplanation(PRMemoryKind kind);

/* One mapping, or several of them added up. */
@interface PRMemoryRegion : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) PRMemoryKind kind;
/* Held in RAM at this moment. This is the number that adds up to what the
   program costs the machine. */
@property (nonatomic, assign) unsigned long long resident;
/* Of that, the part no other program shares, which is what would be freed
   if the program ended. */
@property (nonatomic, assign) unsigned long long privateBytes;
@property (nonatomic, assign) unsigned long long swap;
/* Address space claimed, which may be far more than is held in RAM. */
@property (nonatomic, assign) unsigned long long mapped;
/* How many mappings were added up into this row. */
@property (nonatomic, assign) NSUInteger count;
@end

/* Where a program's memory sits, read from the system rather than from any
   instrumentation, so it can be asked of a program that is already running
   and says where memory went that no allocation profile can explain. */
@interface PRMemoryMap : NSObject
{
    NSArray *_regions;
}

/* Reads the per mapping report of Linux. */
+ (PRMemoryMap *)mapFromSmapsText:(NSString *)text;
+ (PRMemoryMap *)mapWithRegions:(NSArray *)regions;

@property (nonatomic, readonly, copy) NSArray *regions;
@property (nonatomic, readonly) unsigned long long resident;
@property (nonatomic, readonly) unsigned long long privateBytes;
@property (nonatomic, readonly) unsigned long long swap;
@property (nonatomic, readonly) unsigned long long mapped;

/* One row per kind, heaviest first: the answer to "what is this memory". */
- (NSArray *)regionsByKind;
/* One row per file or label, heaviest first: the answer to "which of them". */
- (NSArray *)regionsByName;

@end
