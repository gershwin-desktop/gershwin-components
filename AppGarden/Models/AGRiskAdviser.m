/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGRiskAdviser.h"
#import "AGRiskCategory.h"
#import "AGRiskMatch.h"
#import "AGApp.h"
#import "AGAuthor.h"
#import "AGLink.h"
#import "AGCategoryNames.h"

static NSString *const AGRiskCategoriesResource = @"RiskCategories";

static NSString *AGRiskStringValue(id value)
{
  if (![value isKindOfClass:[NSString class]])
    return @"";
  return [value stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

@implementation AGRiskAdviser

+ (instancetype)sharedAdviser
{
  /* Read once per process. No lock: the only caller is the Get button, which
   * runs on the main thread, and this component does not link libdispatch. */
  static AGRiskAdviser *shared = nil;
  if (shared != nil)
    return shared;

  NSString *path = [[NSBundle mainBundle] pathForResource:AGRiskCategoriesResource
                                                   ofType:@"plist"];
  NSData *data = (path != nil) ? [NSData dataWithContentsOfFile:path] : nil;
  id propertyList = (data != nil)
      ? [NSPropertyListSerialization propertyListWithData:data
                                                options:NSPropertyListImmutable
                                                 format:NULL
                                                  error:NULL]
      : nil;
  shared = [self adviserWithPropertyList:propertyList];
  return shared;
}

+ (instancetype)adviserWithPropertyList:(id)propertyList
{
  AGRiskAdviser *adviser = [[self alloc] init];
  if (adviser == nil)
    return nil;
  [adviser readPropertyList:propertyList];
  return adviser;
}

/* An entry the app cannot show anything useful from is skipped, so a broken
 * line in the file costs the reader that one category and not the warning
 * itself. */
- (void)readPropertyList:(id)propertyList
{
  _categories = [NSArray array];
  _disclaimerShort = @"";
  _disclaimerDetailed = @"";
  if (![propertyList isKindOfClass:[NSDictionary class]])
    return;

  NSDictionary *root = propertyList;
  _disclaimerShort = AGRiskStringValue([root objectForKey:@"DisclaimerShort"]);
  _disclaimerDetailed = AGRiskStringValue([root objectForKey:@"DisclaimerDetailed"]);

  id entries = [root objectForKey:@"Categories"];
  if (![entries isKindOfClass:[NSArray class]])
    return;

  NSMutableArray<AGRiskCategory *> *categories = [NSMutableArray array];
  id entry;
  for (entry in (NSArray *)entries)
    {
      AGRiskCategory *category = [[AGRiskCategory alloc] initWithPropertyListEntry:entry];
      if (category != nil)
        [categories addObject:category];
    }
  _categories = [categories copy];
}

- (NSArray<NSString *> *)searchTextsForApp:(AGApp *)app
{
  if (app == nil)
    return [NSArray array];

  NSMutableArray<NSString *> *texts = [NSMutableArray array];
  void (^add)(NSString *) = ^(NSString *text) {
    if ([text length] > 0)
      [texts addObject:text];
  };

  add([app name]);
  add([app displayName]);
  add([app summary]);
  add([app descriptionText]);

  NSString *category;
  for (category in [app categories])
    {
      /* Both spellings: the sidebar says "Audio & Video" where the feed says
       * "AudioVideo", so a keyword can be written either way. */
      add(category);
      add([AGCategoryNames displayNameForCategory:category]);
    }

  AGAuthor *author;
  for (author in [app authors])
    add([author name]);

  add([app githubRepo]);

  AGLink *link;
  for (link in [app links])
    add([[link url] absoluteString]);

  return texts;
}

- (NSArray<AGRiskMatch *> *)matchesForApp:(AGApp *)app
{
  if ([_categories count] == 0)
    return [NSArray array];

  NSArray<NSString *> *texts = [self searchTextsForApp:app];
  if ([texts count] == 0)
    return [NSArray array];

  NSMutableArray<AGRiskMatch *> *matches = [NSMutableArray array];
  AGRiskCategory *category;
  for (category in _categories)
    {
      NSArray<NSString *> *keywords = [category keywordsMatchedInTexts:texts];
      if ([keywords count] > 0)
        [matches addObject:[[AGRiskMatch alloc] initWithCategory:category
                                                        keywords:keywords]];
    }
  return matches;
}

@end