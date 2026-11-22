/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#include <sane/sane.h>

typedef NS_ENUM(NSInteger, SCOptionType)
{
  SCOptionTypeBool,
  SCOptionTypeInt,
  SCOptionTypeFixed,
  SCOptionTypeString,
  SCOptionTypeButton,
  SCOptionTypeGroup
};

typedef NS_ENUM(NSInteger, SCOptionConstraint)
{
  SCOptionConstraintNone,
  SCOptionConstraintRange,
  SCOptionConstraintList
};

/*
 * One SANE option as the driver currently describes it. Descriptors change
 * whenever the driver asks for a reload, so an SCOption is a snapshot and is
 * replaced, never updated, on reload.
 *
 * Values: NSNumber (BOOL, integer or double) for a single element, NSArray
 * of NSNumber for arrays such as gamma tables, NSString for strings.
 */
@interface SCOption : NSObject

@property (nonatomic, readonly) SANE_Int index;
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) NSString *help;
@property (nonatomic, readonly) NSString *groupTitle;
@property (nonatomic, readonly) SCOptionType type;
@property (nonatomic, readonly) SANE_Unit unit;
@property (nonatomic, readonly) NSUInteger count;
@property (nonatomic, readonly) NSUInteger bufferSize;
@property (nonatomic, readonly) SCOptionConstraint constraint;
@property (nonatomic, readonly) double minimum;
@property (nonatomic, readonly) double maximum;
@property (nonatomic, readonly) double step;
@property (nonatomic, readonly) NSArray *listValues;
@property (nonatomic, readonly, getter=isActive) BOOL active;
@property (nonatomic, readonly, getter=isSettable) BOOL settable;
@property (nonatomic, readonly, getter=isAdvanced) BOOL advanced;
@property (nonatomic, readonly) BOOL canBeAutomatic;
@property (nonatomic, strong) id value;

- (instancetype) initWithDescriptor: (const SANE_Option_Descriptor *)d
                              index: (SANE_Int)index
                         groupTitle: (NSString *)group;

- (id) valueFromBuffer: (const void *)buffer;
- (BOOL) fillBuffer: (void *)buffer fromValue: (id)value;

/* "mm", "dpi", ... or nil for unitless options */
- (NSString *) unitString;

/* Closest value the constraint allows */
- (double) constrainedNumber: (double)number;

@end
