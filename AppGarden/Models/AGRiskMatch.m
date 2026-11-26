/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGRiskMatch.h"
#import "AGRiskCategory.h"

@implementation AGRiskMatch

- (instancetype)initWithCategory:(AGRiskCategory *)category
                         keywords:(NSArray<NSString *> *)keywords
{
  if (category == nil)
    return nil;   /* a match without a category has nothing to show */

  self = [super init];
  if (self == nil)
    return nil;

  _category = category;
  _keywords = [(keywords != nil ? keywords : [NSArray array]) copy];
  return self;
}

/* Defined only so the interface's NS_UNAVAILABLE entry has a body; the
 * attribute keeps callers out and the route to the designated initializer
 * keeps the compiler's initializer chain well formed. A match without a
 * category is nothing to show, so this is nil. */
- (instancetype)init
{
  return [self initWithCategory:nil keywords:nil];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<%@ %@ %@>",
                   NSStringFromClass([self class]), [_category identifier],
                   [_keywords componentsJoinedByString:@", "]];
}

@end