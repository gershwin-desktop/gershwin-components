/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRFormat.h"
#import "PRCallTreeController.h"
#import "PRCallNode.h"
#import "PRSymbol.h"
#import "PRAppearance.h"

@implementation PRCallTreeController

@synthesize costUnit = _costUnit;
@synthesize frequency = _frequency;

- (id)init
{
    self = [super init];
    if (self == nil)
        return nil;
    _frequency = 999;
    return self;
}

- (NSTableColumn *)columnWithIdentifier:(NSString *)identifier
                                  title:(NSString *)title
                                  width:(CGFloat)width
                                aligned:(NSTextAlignment)alignment
{
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
    [[column headerCell] setStringValue:title];
    [column setWidth:width];
    [column setMinWidth:40];
    [column setEditable:NO];
    [[column dataCell] setAlignment:alignment];
    [[column dataCell] setFont:[NSFont systemFontOfSize:11]];
    return column;
}

- (void)configureOutlineView:(NSOutlineView *)outlineView
{
    NSTableColumn *symbol = [self columnWithIdentifier:@"symbol"
                                                 title:@"Function"
                                                 width:420
                                               aligned:NSLeftTextAlignment];
    [outlineView addTableColumn:symbol];
    [outlineView setOutlineTableColumn:symbol];
    [outlineView addTableColumn:[self columnWithIdentifier:@"total"
                                                     title:@"Inclusive"
                                                     width:90
                                                   aligned:NSRightTextAlignment]];
    [outlineView addTableColumn:[self columnWithIdentifier:@"totalPercent"
                                                     title:@"Share"
                                                     width:70
                                                   aligned:NSRightTextAlignment]];
    [outlineView addTableColumn:[self columnWithIdentifier:@"self"
                                                     title:@"Self"
                                                     width:90
                                                   aligned:NSRightTextAlignment]];
    [outlineView addTableColumn:[self columnWithIdentifier:@"module"
                                                     title:@"Binary"
                                                     width:200
                                                   aligned:NSLeftTextAlignment]];

    [outlineView setDataSource:self];
    [outlineView setDelegate:self];
    [outlineView setRowHeight:18];
    [outlineView setUsesAlternatingRowBackgroundColors:YES];
    [outlineView setAllowsColumnResizing:YES];
    [outlineView setAutoresizesOutlineColumn:NO];
}

- (void)setRoot:(PRCallNode *)root inOutlineView:(NSOutlineView *)outlineView
{
    _root = root;
    _total = [root totalWeight];
    [outlineView reloadData];
    [self expandHotPathInOutlineView:outlineView maxDepth:6];
}

- (void)expandHotPathInOutlineView:(NSOutlineView *)outlineView
                          maxDepth:(NSUInteger)maxDepth
{
    /* The root itself is not a row of the outline view - its children are
       the top level - so the walk starts one level down. */
    if ([[_root children] count] == 0)
        return;

    PRCallNode *node = [[_root children] objectAtIndex:0];
    NSUInteger depth = 0;
    while (node != nil && depth < maxDepth && [[node children] count] > 0) {
        [outlineView expandItem:node];
        node = [[node children] objectAtIndex:0];
        depth++;
    }
}

- (id)outlineView:(NSOutlineView *)outlineView
            child:(NSInteger)index
           ofItem:(id)item
{
    PRCallNode *node = item ? item : _root;
    return [[node children] objectAtIndex:index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item
{
    (void)outlineView;
    PRCallNode *node = item ? item : _root;
    return [[node children] count] > 0;
}

- (NSInteger)outlineView:(NSOutlineView *)outlineView
  numberOfChildrenOfItem:(id)item
{
    (void)outlineView;
    PRCallNode *node = item ? item : _root;
    return (NSInteger)[[node children] count];
}

- (id)outlineView:(NSOutlineView *)outlineView
objectValueForTableColumn:(NSTableColumn *)column
           byItem:(id)item
{
    (void)outlineView;
    PRCallNode *node = item;
    NSString *identifier = [column identifier];

    if ([identifier isEqualToString:@"symbol"]) {
        PRSymbol *symbol = [node symbol];
        return symbol ? [symbol displayName] : [node label];
    }
    if ([identifier isEqualToString:@"total"])
        return [PRFormat stringForWeight:[node totalWeight]
                                    unit:_costUnit
                               frequency:_frequency];
    if ([identifier isEqualToString:@"totalPercent"])
        return [PRFormat percentOf:[node totalWeight] total:_total];
    if ([identifier isEqualToString:@"self"])
        return [node selfWeight] > 0 ?
            [PRFormat stringForWeight:[node selfWeight]
                                 unit:_costUnit
                            frequency:_frequency] : @"";
    if ([identifier isEqualToString:@"module"])
        return [[node symbol] moduleName];

    return @"";
}

@end
