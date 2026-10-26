/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGSearchIndex.h"
#import "AGApp.h"
#import "AGAuthor.h"
#import "AGCatalog.h"
#import "AGCategoryNames.h"

static NSStringCompareOptions AGMatchOptions =
  NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;

// Both sides are folded and then compared literally: asking
// rangeOfString:options: for these two options at once finds nothing on some
// systems, while folding gives exactly the same comparison and can be
// checked with a plain search. The nil locale keeps the result independent of
// the desktop language, so a query typed in one language finds the same apps
// in another.
static NSString *AGFold(NSString *value)
{
  if (value == nil)
    return nil;
  return [value stringByFoldingWithOptions:AGMatchOptions locale:nil];
}

static BOOL AGFoldedContains(NSString *foldedHaystack, NSString *foldedTerm)
{
  if (foldedHaystack == nil)
    return NO;
  return [foldedHaystack rangeOfString:foldedTerm].location != NSNotFound;
}

// "net" opens a word of "apache netbeans", "beans" does not: a term the user
// could have typed at the front of a name ranks above one buried in it.
static BOOL AGFoldedOpensNameWord(NSString *foldedName, NSString *foldedTerm)
{
  if ([foldedName rangeOfString:foldedTerm options:NSAnchoredSearch].location != NSNotFound)
    return YES;

  NSString *word;
  for (word in [foldedName componentsSeparatedByCharactersInSet:
                  [NSCharacterSet whitespaceAndNewlineCharacterSet]])
    {
      if ([word rangeOfString:foldedTerm options:NSAnchoredSearch].location != NSNotFound)
        return YES;
    }
  return NO;
}

static BOOL AGFoldedAppMatchesTerm(AGApp *app, NSString *foldedTerm, NSString *foldedName)
{
  if (AGFoldedContains(foldedName, foldedTerm))
    return YES;
  if (AGFoldedContains(AGFold([app descriptionText]), foldedTerm))
    return YES;

  NSString *category;
  for (category in [app categories])
    {
      // Both spellings: the sidebar says "Audio & Video" while the feed says
      // "AudioVideo", and a typed word should find the app either way.
      if (AGFoldedContains(AGFold(category), foldedTerm))
        return YES;
      if (AGFoldedContains(AGFold([AGCategoryNames displayNameForCategory:category]), foldedTerm))
        return YES;
    }

  AGAuthor *author;
  for (author in [app authors])
    {
      if (AGFoldedContains(AGFold([author name]), foldedTerm))
        return YES;
    }

  return NO;
}

// 0: every term opens a word of the name, 1: every term is somewhere in the
// name, 2: every term matched somewhere else, NSNotFound: not a match.
static NSUInteger AGRankOfApp(AGApp *app, NSArray *foldedTerms)
{
  NSString *foldedName = AGFold([app displayName]);
  BOOL allInName = YES;
  NSString *term;

  for (term in foldedTerms)
    {
      if (!AGFoldedContains(foldedName, term))
        {
          allInName = NO;
          break;
        }
    }

  if (allInName)
    {
      for (term in foldedTerms)
        {
          if (!AGFoldedOpensNameWord(foldedName, term))
            return 1;
        }
      return 0;
    }

  for (term in foldedTerms)
    {
      if (!AGFoldedAppMatchesTerm(app, term, foldedName))
        return NSNotFound;
    }
  return 2;
}

static NSArray *AGQueryTerms(NSString *query)
{
  NSMutableArray *terms = [NSMutableArray array];
  NSString *part;
  for (part in [query componentsSeparatedByCharactersInSet:
                  [NSCharacterSet whitespaceAndNewlineCharacterSet]])
    {
      if ([part length] > 0)
        [terms addObject:part];
    }
  return terms;
}

static NSArray *AGSortedByName(NSArray *apps)
{
  NSMutableArray *sorted = [NSMutableArray arrayWithArray:apps];
  [sorted sortUsingComparator:^NSComparisonResult(AGApp *left, AGApp *right) {
    NSComparisonResult result = [[left displayName] localizedCaseInsensitiveCompare:[right displayName]];
    if (result == NSOrderedSame)
      result = [[left name] compare:[right name]];
    return result;
  }];
  return sorted;
}

@implementation AGSearchIndex
{
  AGCatalog *_catalog;
}

- (instancetype)initWithCatalog:(AGCatalog *)catalog
{
  self = [super init];
  if (self != nil)
    _catalog = catalog;
  return self;
}

- (NSArray<AGApp *> *)appsMatchingQuery:(NSString *)query inCategory:(NSString *)categoryOrNil
{
  NSArray *scope;
  if (categoryOrNil == nil)
    scope = [_catalog apps];
  else
    scope = [_catalog appsInCategory:categoryOrNil];

  NSMutableArray *foldedTerms = [NSMutableArray array];
  NSString *term;
  for (term in AGQueryTerms(query))
    [foldedTerms addObject:AGFold(term)];

  if ([foldedTerms count] == 0)
    return scope;

  NSMutableArray *opensName = [NSMutableArray array];
  NSMutableArray *inName = [NSMutableArray array];
  NSMutableArray *elsewhere = [NSMutableArray array];

  AGApp *app;
  for (app in scope)
    {
      NSUInteger rank = AGRankOfApp(app, foldedTerms);
      if (rank == 0)
        [opensName addObject:app];
      else if (rank == 1)
        [inName addObject:app];
      else if (rank == 2)
        [elsewhere addObject:app];
    }

  NSMutableArray *result = [NSMutableArray arrayWithCapacity:[scope count]];
  [result addObjectsFromArray:AGSortedByName(opensName)];
  [result addObjectsFromArray:AGSortedByName(inName)];
  [result addObjectsFromArray:AGSortedByName(elsewhere)];
  return result;
}

@end
