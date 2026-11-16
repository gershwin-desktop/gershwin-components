/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGCategoryNames.h"

// Localized once when the class is first used; the desktop language does not
// change under a running application.
static NSDictionary *AGCategoryDisplayNames = nil;
static NSDictionary *AGCategoryOrders = nil;
static NSSet *AGHiddenCategories = nil;

@implementation AGCategoryNames

+ (void)initialize
{
  if (self != [AGCategoryNames class])
    return;

  AGCategoryDisplayNames = @{
    @"AudioVideo": NSLocalizedString(@"Audio & Video", @""),
    @"Development": NSLocalizedString(@"Developer Tools", @""),
    @"Game": NSLocalizedString(@"Games", @""),
    @"Network": NSLocalizedString(@"Internet", @""),
    @"Office": NSLocalizedString(@"Productivity", @""),
    @"Graphics": NSLocalizedString(@"Graphics & Design", @""),
    @"Utility": NSLocalizedString(@"Utilities", @""),
    @"Science": NSLocalizedString(@"Science", @""),
    @"System": NSLocalizedString(@"System", @""),
    @"Education": NSLocalizedString(@"Education", @""),
    @"Finance": NSLocalizedString(@"Finance", @""),
    @"Audio": NSLocalizedString(@"Audio", @""),
    @"Music": NSLocalizedString(@"Music", @""),
    @"Video": NSLocalizedString(@"Video", @""),
    @"Chat": NSLocalizedString(@"Chat", @""),
    @"News": NSLocalizedString(@"News", @""),
    @"Settings": NSLocalizedString(@"Settings", @""),
    @"Engineering": NSLocalizedString(@"Engineering", @""),
    @"TerminalEmulator": NSLocalizedString(@"Terminal Emulators", @""),
    @"Emulator": NSLocalizedString(@"Emulators", @""),
    @"VideoConference": NSLocalizedString(@"Video Conferencing", @""),
    @"HamRadio": NSLocalizedString(@"Ham Radio", @""),
    @"Electronics": NSLocalizedString(@"Electronics", @""),
    @"WordProcessor": NSLocalizedString(@"Word Processors", @""),
    @"Astronomy": NSLocalizedString(@"Astronomy", @""),
    @"Qt": NSLocalizedString(@"Qt", @""),
    @"GTK": NSLocalizedString(@"GTK", @""),
    @"GNOME": NSLocalizedString(@"GNOME", @""),
    @"Application": NSLocalizedString(@"Application", @""),
  };

  AGCategoryOrders = @{
    @"Utility": @(10),
    @"Development": @(20),
    @"Office": @(30),
    @"Graphics": @(40),
    @"AudioVideo": @(50),
    @"Network": @(60),
    @"Game": @(70),
    @"Education": @(80),
    @"Science": @(90),
    @"Finance": @(100),
    @"System": @(110),
    @"Audio": @(120),
    @"Music": @(130),
    @"Video": @(140),
    @"Chat": @(150),
    @"News": @(160),
    @"Settings": @(170),
    @"Engineering": @(180),
    @"TerminalEmulator": @(190),
    @"Emulator": @(200),
    @"VideoConference": @(210),
    @"HamRadio": @(220),
    @"Electronics": @(230),
    @"WordProcessor": @(240),
    @"Astronomy": @(250),
    @"Qt": @(900),
    @"GTK": @(910),
    @"GNOME": @(920),
    @"Application": @(930),
  };

  AGHiddenCategories = [NSSet setWithObjects:@"Qt", @"GTK", @"GNOME", @"Application", nil];
}

+ (NSString *)displayNameForCategory:(NSString *)category
{
  if (category == nil)
    return nil;
  NSString *displayName = [AGCategoryDisplayNames objectForKey:category];
  return (displayName != nil) ? displayName : category;
}

+ (BOOL)isHiddenCategory:(NSString *)category
{
  if (category == nil)
    return NO;
  return [AGHiddenCategories containsObject:category];
}

+ (NSInteger)sortOrderForCategory:(NSString *)category
{
  if (category == nil)
    return NSIntegerMax;
  NSNumber *order = [AGCategoryOrders objectForKey:category];
  return (order != nil) ? [order integerValue] : NSIntegerMax;
}

+ (NSArray<NSString *> *)sortedRawCategories:(NSArray<NSString *> *)categories
{
  NSMutableArray *sorted = [NSMutableArray array];
  NSString *category;
  for (category in categories)
    {
      if ([category isKindOfClass:[NSString class]])
        [sorted addObject:category];
    }

  [sorted sortUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
    NSInteger leftOrder = [AGCategoryNames sortOrderForCategory:left];
    NSInteger rightOrder = [AGCategoryNames sortOrderForCategory:right];
    if (leftOrder != rightOrder)
      return (leftOrder < rightOrder) ? NSOrderedAscending : NSOrderedDescending;
    return [left localizedCaseInsensitiveCompare:right];
  }];

  return [sorted copy];
}

@end
