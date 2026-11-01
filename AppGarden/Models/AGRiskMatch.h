/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class AGRiskCategory;

/*
 * One category that matched an item, together with the keywords that said so.
 *
 * The panel shows the keywords on purpose: a category is a guess from a word
 * in a description, so the user is told which word fired and can disagree with
 * the guess instead of only being told that something is wrong.
 */
@interface AGRiskMatch : NSObject

@property (nonatomic, strong, readonly) AGRiskCategory *category;
@property (nonatomic, copy, readonly) NSArray<NSString *> *keywords;

- (instancetype)initWithCategory:(AGRiskCategory *)category
                         keywords:(NSArray<NSString *> *)keywords NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end