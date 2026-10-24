/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "PRTypes.h"

@class PRSymbol;

/* A node of a call tree: one function reached over one particular path.
   The same function appearing under two callers is two nodes. */
@interface PRCallNode : NSObject
{
    PRSymbol *_symbol;
    NSString *_label;
    PRCallNode *_parent;
    NSMutableArray *_children;
    NSMutableDictionary *_childIndex;
    double _selfWeight;
    double _totalWeight;
}

- (id)initWithSymbol:(PRSymbol *)symbol label:(NSString *)label;

@property (nonatomic, readonly, strong) PRSymbol *symbol;
@property (nonatomic, readonly, strong) PRCallNode *parent;
@property (nonatomic, readonly) double selfWeight;
@property (nonatomic, readonly) double totalWeight;

/* Root nodes carry the recording's name instead of a symbol. */
@property (nonatomic, readonly, copy) NSString *label;

- (NSArray *)children;
- (PRCallNode *)childForSymbol:(PRSymbol *)symbol;
- (void)addSelfWeight:(double)weight;
- (void)addTotalWeight:(double)weight;

/* Depth of the deepest descendant, the root counting as level 0. */
- (NSUInteger)depth;

/* Sorts every level by total weight, heaviest first. */
- (void)sortRecursively;

@end
