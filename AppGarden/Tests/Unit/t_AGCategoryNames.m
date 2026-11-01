/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "AGCategoryNames.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* --- the mappings from the brief --- */
  PASS_EQUAL([AGCategoryNames displayNameForCategory: @"AudioVideo"], @"Audio & Video",
             "AudioVideo maps to its display name");
  PASS_EQUAL([AGCategoryNames displayNameForCategory: @"Development"], @"Developer Tools",
             "Development maps to its display name");
  PASS_EQUAL([AGCategoryNames displayNameForCategory: @"Game"], @"Games",
             "Game maps to its display name");
  PASS_EQUAL([AGCategoryNames displayNameForCategory: @"Network"], @"Internet",
             "Network maps to its display name");
  PASS_EQUAL([AGCategoryNames displayNameForCategory: @"Office"], @"Productivity",
             "Office maps to its display name");
  PASS_EQUAL([AGCategoryNames displayNameForCategory: @"Graphics"], @"Graphics & Design",
             "Graphics maps to its display name");
  PASS_EQUAL([AGCategoryNames displayNameForCategory: @"Utility"], @"Utilities",
             "Utility maps to its display name");
  PASS_EQUAL([AGCategoryNames displayNameForCategory: @"Science"], @"Science",
             "Science maps to its display name");
  PASS_EQUAL([AGCategoryNames displayNameForCategory: @"System"], @"System",
             "System maps to its display name");
  PASS_EQUAL([AGCategoryNames displayNameForCategory: @"Education"], @"Education",
             "Education maps to its display name");
  PASS_EQUAL([AGCategoryNames displayNameForCategory: @"Finance"], @"Finance",
             "Finance maps to its display name");

  /* --- toolkits are hidden, purposes are not --- */
  PASS([AGCategoryNames isHiddenCategory: @"Qt"], "Qt is hidden from the sidebar");
  PASS([AGCategoryNames isHiddenCategory: @"GTK"], "GTK is hidden from the sidebar");
  PASS([AGCategoryNames isHiddenCategory: @"GNOME"], "GNOME is hidden from the sidebar");
  PASS([AGCategoryNames isHiddenCategory: @"Application"],
       "Application is hidden from the sidebar");
  PASS(![AGCategoryNames isHiddenCategory: @"Utility"], "Utility stays visible");
  PASS(![AGCategoryNames isHiddenCategory: @"Development"], "Development stays visible");
  PASS(![AGCategoryNames isHiddenCategory: nil], "a nil category hides nothing");

  /* --- unknown categories keep their raw name --- */
  PASS_EQUAL([AGCategoryNames displayNameForCategory: @"Weather"], @"Weather",
             "an unknown category shows its raw name");
  PASS([AGCategoryNames displayNameForCategory: nil] == nil,
       "a nil category has no display name");

  /* --- sidebar order: known by sort order, then unknown alphabetically --- */
  {
    NSArray *input = @[ @"Weather", @"Game", @"Utility", @"Qt", @"Zebra", @"Banana" ];
    NSArray *want = @[ @"Utility", @"Game", @"Qt", @"Banana", @"Weather", @"Zebra" ];
    NSArray *sorted = [AGCategoryNames sortedRawCategories: input];
    PASS_EQUAL(sorted, want,
               "known categories come first in table order, unknown ones after them alphabetically");
  }
  {
    /* The brief's example categories in sidebar order: Utilities, then
     * Developer Tools, Graphics & Design, Internet, Games. */
    NSArray *want = @[ @"Utility", @"Development", @"Graphics", @"Network", @"Game" ];
    NSArray *sorted = [AGCategoryNames sortedRawCategories:
                         [NSArray arrayWithObjects: @"Network", @"Utility", @"Game",
                                                     @"Development", @"Graphics", nil]];
    PASS_EQUAL(sorted, want,
               "the brief's categories order by their sort order");
  }

  [arp release];
  return 0;
}
