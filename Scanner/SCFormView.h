/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

/* One line of a form: a right-aligned label and a control, or a group heading */
@interface SCFormRow : NSObject
@property (nonatomic, copy) NSString *label;
@property (nonatomic, strong) NSView *control;
@property (nonatomic) BOOL heading;
+ (instancetype) rowWithLabel: (NSString *)label control: (NSView *)control;
+ (instancetype) headingWithTitle: (NSString *)title;
@end

/*
 * Lays out rows top to bottom in two columns and resizes its height to fit,
 * so it can sit in a scroll view; controls stretch with the width.
 */
@interface SCFormView : NSView
@property (nonatomic, copy) NSArray *rows;
@property (nonatomic) CGFloat labelWidth;
/* Space around the rows, for forms that fill a tab or scroll view */
@property (nonatomic) CGFloat margin;
- (void) layoutRows;
@end
