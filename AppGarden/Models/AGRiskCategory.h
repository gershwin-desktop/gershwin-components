/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/*
 * One threat category from Resources/RiskCategories.plist: the words in a
 * catalog item's metadata that mean "this can do damage", plus the sentence
 * shown when one of them fires (ShortRisk).
 *
 * Foundation only, so the wording and the matching can be tested without a
 * display, like every other model here.
 *
 * Matching is whole-word and case, accent and punctuation insensitive, which
 * is what keeps a short keyword usable: "ai" finds "AI workspace" and
 * "Aarynwood" but never "available" or "email". Two spellings of a keyword are
 * searched, with and without the camel-case split, so "OpenAI" is still found
 * in an item that writes "openai" and "Wallet" is found in "WALLET".
 */
@interface AGRiskCategory : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;   // "ai-agents"
@property (nonatomic, copy, readonly) NSString *title;       // shown as the panel's headline
@property (nonatomic, copy, readonly) NSString *shortRisk;   // one sentence
@property (nonatomic, copy, readonly) NSArray<NSString *> *keywords; // as written, never empty

/*
 * A dictionary from the plist. Returns nil for an entry the app cannot show
 * anything useful from: no identifier, no title, an empty sentence or no
 * keyword. A category is dropped rather than shown as a blank warning, so one
 * broken entry costs the reader that category and nothing else.
 */
- (instancetype)initWithPropertyListEntry:(NSDictionary *)entry NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/*
 * The keywords of this category that appear in any of the texts, in the order
 * the plist lists them. The texts are the item's metadata as the feed wrote
 * it; each one is normalized once per call, which only happens on a click.
 */
- (NSArray<NSString *> *)keywordsMatchedInTexts:(NSArray<NSString *> *)texts;

@end