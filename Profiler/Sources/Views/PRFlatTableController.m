/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRFlatTableController.h"
#import "PRProfile.h"
#import "PRAppearance.h"

@implementation PRFlatTableController

@synthesize costUnit = _costUnit;
@synthesize frequency = _frequency;

- (id)init
{
    self = [super init];
    if (self == nil)
        return nil;
    _frequency = 999;
    _sortKey = @"self";
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

- (void)configureTableView:(NSTableView *)tableView
{
    [tableView addTableColumn:[self columnWithIdentifier:@"self"
                                                   title:@"Self"
                                                   width:90
                                                 aligned:NSRightTextAlignment]];
    [tableView addTableColumn:[self columnWithIdentifier:@"selfPercent"
                                                   title:@"Share"
                                                   width:70
                                                 aligned:NSRightTextAlignment]];
    [tableView addTableColumn:[self columnWithIdentifier:@"total"
                                                   title:@"Inclusive"
                                                   width:90
                                                 aligned:NSRightTextAlignment]];
    [tableView addTableColumn:[self columnWithIdentifier:@"name"
                                                   title:@"Name"
                                                   width:420
                                                 aligned:NSLeftTextAlignment]];
    [tableView addTableColumn:[self columnWithIdentifier:@"detail"
                                                   title:@"Binary or source"
                                                   width:220
                                                 aligned:NSLeftTextAlignment]];

    [tableView setDataSource:self];
    [tableView setDelegate:self];
    [tableView setRowHeight:18];
    [tableView setUsesAlternatingRowBackgroundColors:YES];
}

- (void)sortRows
{
    NSString *key = _sortKey;
    _rows = [_rows sortedArrayUsingComparator:
             ^NSComparisonResult(PRAggregateRow *a, PRAggregateRow *b) {
        if ([key isEqualToString:@"name"] || [key isEqualToString:@"detail"]) {
            NSString *left = [key isEqualToString:@"name"] ? [a name] : [a detail];
            NSString *right = [key isEqualToString:@"name"] ? [b name] : [b detail];
            return [left localizedCaseInsensitiveCompare:right];
        }
        double left = [key isEqualToString:@"total"] ? [a totalWeight] : [a selfWeight];
        double right = [key isEqualToString:@"total"] ? [b totalWeight] : [b selfWeight];
        if (left > right) return NSOrderedAscending;
        if (left < right) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

- (void)setRows:(NSArray *)rows total:(double)total inTableView:(NSTableView *)tableView
{
    _rows = [rows copy];
    _total = total;
    [self sortRows];
    [tableView reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    (void)tableView;
    return (NSInteger)[_rows count];
}

- (id)tableView:(NSTableView *)tableView
objectValueForTableColumn:(NSTableColumn *)column
            row:(NSInteger)rowIndex
{
    (void)tableView;
    PRAggregateRow *row = [_rows objectAtIndex:rowIndex];
    NSString *identifier = [column identifier];

    if ([identifier isEqualToString:@"self"])
        return [PRAppearance stringForWeight:[row selfWeight]
                                        unit:_costUnit
                                   frequency:_frequency];
    if ([identifier isEqualToString:@"selfPercent"])
        return [PRAppearance percentOf:[row selfWeight] total:_total];
    if ([identifier isEqualToString:@"total"])
        return [PRAppearance stringForWeight:[row totalWeight]
                                        unit:_costUnit
                                   frequency:_frequency];
    if ([identifier isEqualToString:@"name"])
        return [row name];
    if ([identifier isEqualToString:@"detail"])
        return [row detail];

    return @"";
}

- (void)tableView:(NSTableView *)tableView
didClickTableColumn:(NSTableColumn *)column
{
    _sortKey = [column identifier];
    if ([_sortKey isEqualToString:@"selfPercent"])
        _sortKey = @"self";
    [self sortRows];
    [tableView reloadData];
}

@end
