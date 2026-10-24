/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "PRTypes.h"

/* Feeds a table with the flat cost list: every function, class, binary or
   thread once, with what it cost on its own and including everything it
   called. */
@interface PRFlatTableController : NSObject <NSTableViewDataSource, NSTableViewDelegate>
{
    NSArray *_rows;
    PRCostUnit _costUnit;
    NSUInteger _frequency;
    double _total;
    NSString *_sortKey;
}

@property (nonatomic, assign) PRCostUnit costUnit;
@property (nonatomic, assign) NSUInteger frequency;

- (void)configureTableView:(NSTableView *)tableView;
- (void)setRows:(NSArray *)rows total:(double)total inTableView:(NSTableView *)tableView;

@end
