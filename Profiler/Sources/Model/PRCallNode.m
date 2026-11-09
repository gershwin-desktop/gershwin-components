/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRCallNode.h"
#import "PRSymbol.h"

@implementation PRCallNode

@synthesize symbol = _symbol;
@synthesize parent = _parent;
@synthesize selfWeight = _selfWeight;
@synthesize totalWeight = _totalWeight;
@synthesize label = _label;

- (id)initWithSymbol:(PRSymbol *)symbol label:(NSString *)label
{
    self = [super init];
    if (self == nil)
        return nil;
    _symbol = symbol;
    _label = [label copy];
    _children = [[NSMutableArray alloc] init];
    _childIndex = [[NSMutableDictionary alloc] init];
    return self;
}

- (NSArray *)children
{
    return _children;
}

- (PRCallNode *)childForSymbol:(PRSymbol *)symbol
{
    NSNumber *key = [NSNumber numberWithUnsignedInteger:[symbol index]];
    PRCallNode *child = [_childIndex objectForKey:key];
    if (child == nil) {
        child = [[PRCallNode alloc] initWithSymbol:symbol label:nil];
        child->_parent = self;
        [_childIndex setObject:child forKey:key];
        [_children addObject:child];
    }
    return child;
}

- (void)addSelfWeight:(double)weight
{
    _selfWeight += weight;
}

- (void)addTotalWeight:(double)weight
{
    _totalWeight += weight;
}

- (NSUInteger)depth
{
    NSUInteger deepest = 0;
    for (PRCallNode *child in _children) {
        NSUInteger d = [child depth] + 1;
        if (d > deepest)
            deepest = d;
    }
    return deepest;
}

- (void)sortRecursively
{
    [_children sortUsingComparator:^NSComparisonResult(PRCallNode *a, PRCallNode *b) {
        if (a->_totalWeight > b->_totalWeight) return NSOrderedAscending;
        if (a->_totalWeight < b->_totalWeight) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    for (PRCallNode *child in _children)
        [child sortRecursively];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<PRCallNode %@ total=%.0f self=%.0f>",
            _symbol ? [_symbol displayName] : _label, _totalWeight, _selfWeight];
}

@end
