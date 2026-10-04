/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGRiskCategory.h"

static NSString *AGRiskStringValue(id value)
{
  if (![value isKindOfClass:[NSString class]])
    return nil;
  NSString *text = [value stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return [text length] > 0 ? [text copy] : nil;
}

/* Case, accents and punctuation are all folded away, then the text becomes
 * lower-case words separated by exactly one space.
 *
 * The order matters: the camel-case boundaries have to be found in the text as
 * it was written, because the folding that follows lowers every letter and a
 * split that ran afterwards could never see one. So the boundaries are marked
 * first, then the whole string is folded.
 *
 * The loop walks UTF-16 units, which is safe here because a boundary can only
 * fall between ASCII letters and digits; a unit of a surrogate pair or of a
 * character from another script is never one of those and is dropped by the
 * folding below like any other non-alphanumeric. */
static NSString *AGRiskNormalized(NSString *text, BOOL splitCamelCase)
{
  if (text == nil)
    return @"";

  NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
  NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
  NSCharacterSet *lower = [NSCharacterSet lowercaseLetterCharacterSet];
  NSCharacterSet *upper = [NSCharacterSet uppercaseLetterCharacterSet];

  NSUInteger length = [text length];
  NSMutableString *marked = [NSMutableString stringWithCapacity:length + 8];
  NSUInteger index;
  for (index = 0; index < length; index++)
    {
      unichar character = [text characterAtIndex:index];
      [marked appendFormat:@"%C", character];

      if (!splitCamelCase || index + 1 >= length)
        continue;

      /* The boundaries that make a compound name searchable as its parts:
       * "OpenAIDesk" has to offer "openai" as well as "open", and "GPT4All"
       * has to offer "gpt". */
      unichar next = [text characterAtIndex:index + 1];
      unichar after = (index + 2 < length) ? [text characterAtIndex:index + 2] : 0;
      BOOL boundary = NO;
      if ([letters characterIsMember:character])
        {
          if ([digits characterIsMember:next])
            boundary = YES;
          else if ([lower characterIsMember:character] && [upper characterIsMember:next])
            boundary = YES;
          else if ([upper characterIsMember:character] && [upper characterIsMember:next]
                   && [lower characterIsMember:after])
            boundary = YES;
        }
      else if ([digits characterIsMember:character] && [letters characterIsMember:next])
        boundary = YES;
      if (boundary)
        [marked appendString:@" "];
    }

  /* No locale, so the comparison does not change with the desktop language:
   * the same item matches the same way in every language. */
  NSString *folded = [marked stringByFoldingWithOptions:NSCaseInsensitiveSearch |
                                                  NSDiacriticInsensitiveSearch
                                              locale:nil];

  NSMutableString *result = [NSMutableString stringWithCapacity:[folded length] + 8];
  BOOL pendingSpace = NO;
  for (index = 0; index < [folded length]; index++)
    {
      unichar character = [folded characterAtIndex:index];
      if ([letters characterIsMember:character] || [digits characterIsMember:character])
        {
          /* One space between words, none at either end: the caller pads the
           * text before looking for " keyword " in it. */
          if (pendingSpace && [result length] > 0)
            [result appendString:@" "];
          [result appendFormat:@"%C", character];
          pendingSpace = NO;
        }
      else
        {
          pendingSpace = YES;
        }
    }

  return result;
}

/* A keyword matches only as whole words: the text and the form are both
 * padded, so "ai" is found in "an ai workspace" and never inside
 * "available". The padding is what finds a keyword that the text begins or
 * ends with, which a normalized text has trimmed away. */
static BOOL AGRiskFormsAppearIn(NSArray<NSString *> *paddedTexts, NSString *form)
{
  NSString *needle = [@" " stringByAppendingString:[form stringByAppendingString:@" "]];
  NSUInteger index;
  for (index = 0; index < [paddedTexts count]; index++)
    {
      if ([[paddedTexts objectAtIndex:index] rangeOfString:needle].location != NSNotFound)
        return YES;
    }
  return NO;
}

/* The two spellings a keyword is searched under: split into words, and folded
 * to one run. An item that writes "openai" and a keyword written "OpenAI"
 * only meet in the second one. */
static NSArray<NSString *> *AGRiskSearchForms(NSString *keyword)
{
  NSMutableArray<NSString *> *forms = [NSMutableArray array];
  NSString *split = AGRiskNormalized(keyword, YES);
  NSString *plain = AGRiskNormalized(keyword, NO);
  if ([split length] > 0)
    [forms addObject:split];
  if ([plain length] > 0 && ![plain isEqualToString:split])
    [forms addObject:plain];
  return forms;
}

@implementation AGRiskCategory
{
  /* Parallel to keywords: the spellings each one is searched under. Built
   * once, because the same keywords are matched for every Get click. */
  NSArray<NSArray<NSString *> *> *_searchForms;
}

- (instancetype)initWithPropertyListEntry:(NSDictionary *)entry
{
  if (![entry isKindOfClass:[NSDictionary class]])
    return nil;

  NSString *identifier = AGRiskStringValue([entry objectForKey:@"Identifier"]);
  NSString *title = AGRiskStringValue([entry objectForKey:@"Title"]);
  NSString *shortRisk = AGRiskStringValue([entry objectForKey:@"ShortRisk"]);
  NSString *detailedRisk = AGRiskStringValue([entry objectForKey:@"DetailedRisk"]);
  if (identifier == nil || title == nil || shortRisk == nil || detailedRisk == nil)
    return nil;

  /* A keyword that differs only in case or spacing is the same word twice,
   * and the panel would list it twice. */
  NSMutableArray<NSString *> *keywords = [NSMutableArray array];
  NSMutableArray<NSArray<NSString *> *> *forms = [NSMutableArray array];
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  id value;
  for (value in [entry objectForKey:@"Keywords"])
    {
      NSString *keyword = AGRiskStringValue(value);
      NSArray<NSString *> *form = (keyword != nil) ? AGRiskSearchForms(keyword) : nil;
      if ([form count] == 0)
        continue;
      NSString *key = [form objectAtIndex:0];
      if ([seen containsObject:key])
        continue;
      [seen addObject:key];
      [keywords addObject:keyword];
      [forms addObject:form];
    }
  if ([keywords count] == 0)
    return nil;

  self = [super init];
  if (self == nil)
    return nil;

  _identifier = identifier;
  _title = title;
  _shortRisk = shortRisk;
  _detailedRisk = detailedRisk;
  _keywords = [keywords copy];
  _searchForms = [forms copy];
  return self;
}

/* Defined only so the interface's NS_UNAVAILABLE entry has a body; the
 * attribute keeps callers out and the route to the designated initializer
 * keeps the compiler's initializer chain well formed. A category without an
 * entry is no category, so this is nil. */
- (instancetype)init
{
  return [self initWithPropertyListEntry:nil];
}

- (NSArray<NSString *> *)keywordsMatchedInTexts:(NSArray<NSString *> *)texts
{
  if ([texts count] == 0)
    return [NSArray array];

  /* Padded once per text, because a normalized text has no space at either
   * end and the match looks for one on each side of the keyword. */
  NSMutableArray<NSString *> *padded = [NSMutableArray arrayWithCapacity:[texts count]];
  NSString *text;
  for (text in texts)
    {
      NSString *normalized = AGRiskNormalized(text, YES);
      [padded addObject:[@" " stringByAppendingString:
                           [normalized stringByAppendingString:@" "]]];
    }

  NSMutableArray<NSString *> *matched = [NSMutableArray array];
  NSUInteger index;
  for (index = 0; index < [_keywords count]; index++)
    {
      NSArray<NSString *> *forms = [_searchForms objectAtIndex:index];
      NSUInteger formIndex;
      for (formIndex = 0; formIndex < [forms count]; formIndex++)
        {
          if (AGRiskFormsAppearIn(padded, [forms objectAtIndex:formIndex]))
            {
              [matched addObject:[_keywords objectAtIndex:index]];
              break;
            }
        }
    }
  return matched;
}

@end