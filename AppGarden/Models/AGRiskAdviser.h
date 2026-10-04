/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class AGApp;
@class AGRiskCategory;
@class AGRiskMatch;

/*
 * The risk categories of Resources/RiskCategories.plist and the match they
 * make against a catalog item.
 *
 * Nothing in the catalog is vetted, so this is a warning, never a block: it
 * looks for the words of a threat category in what the publisher wrote and
 * hands the Get button something to say about it.
 *
 * Foundation only, so it can be tested headless.
 */
@interface AGRiskAdviser : NSObject

/*
 * The categories of the bundled file, read once per process. Never nil: a
 * missing or broken file gives an adviser with no categories, which means no
 * warning, rather than a warning about everything.
 */
+ (instancetype)sharedAdviser;

/* An adviser built from a parsed plist, for the tests. */
+ (instancetype)adviserWithPropertyList:(id)propertyList;

@property (nonatomic, copy, readonly) NSArray<AGRiskCategory *> *categories;

/*
 * Every category whose keywords appear in the item, in the order the file
 * lists them, each with the keywords that fired. Empty for the many items
 * that say nothing any category claims.
 */
- (NSArray<AGRiskMatch *> *)matchesForApp:(AGApp *)app;

/*
 * The same, also reading additionalTexts: text from somewhere other than the
 * catalog entry, such as the README of the repository the app is hosted in.
 */
- (NSArray<AGRiskMatch *> *)matchesForApp:(AGApp *)app
                          additionalTexts:(NSArray<NSString *> *)additionalTexts;

/*
 * The metadata searched, in the order it is searched: the item's name and
 * display name, its summary and full description, its categories (both
 * spellings), its authors, its repository and the URLs it links to. Exposed
 * because "any metadata" is a promise about what is read, and a promise the
 * tests hold this class to.
 */
- (NSArray<NSString *> *)searchTextsForApp:(AGApp *)app;

@end