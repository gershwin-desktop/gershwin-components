/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* When an application's cached menu is shown again, the importer registers
   the shortcuts of its items once more.  Menu's own system menu sits in that
   same menu tree; picking its items too handed Force Quit (Cmd-Shift-Esc) to
   the application's D-Bus handler, so neither the menu item nor the shortcut
   opened the panel any more.  Headless: no display needed. */

#import <AppKit/AppKit.h>
#import "Testing.h"
#include "../../MenuShortcutItems.m"

@interface ImportedHandler : NSObject
@end
@implementation ImportedHandler
@end

@interface ForceQuitController : NSObject
@end
@implementation ForceQuitController
@end

/* Stand-ins answering what the walk asks of NSMenuItem and NSMenu: real
   submenus make menu windows, which would need a display. */
@interface Item : NSObject
@property (retain) id target;
@property (copy) NSString *keyEquivalent;
@property (retain) id submenu;
@end
@implementation Item
- (BOOL)hasSubmenu { return self.submenu != nil; }
@end

@interface Menu : NSObject
@property (retain) NSMutableArray *itemArray;
@end
@implementation Menu
- (id)init { if ((self = [super init])) { self.itemArray = [NSMutableArray array]; } return self; }
- (void)addItem:(Item *)i { [self.itemArray addObject: i]; }
@end

static Item *item(id target, NSString *key, Menu *submenu)
{
  Item *i = [[Item new] autorelease];
  i.target = target;
  i.keyEquivalent = key;
  i.submenu = submenu;
  return i;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  static NSString * const suiteName = @"shortcut re-registration of imported menus";
  ForceQuitController *forceQuit = [[ForceQuitController new] autorelease];

  /* The application's menu as Menu shows it: the system submenu first,
     then the imported File menu. */
  Menu *app = [[Menu new] autorelease];
  Menu *system = [[Menu new] autorelease];
  Item *forceQuitItem = item(forceQuit, @"\033", nil);
  [system addItem: forceQuitItem];
  [app addItem: item(nil, @"", system)];

  Menu *file = [[Menu new] autorelease];
  Item *save = item([ImportedHandler class], @"s", nil);
  Item *revert = item([ImportedHandler class], @"", nil);
  Menu *recent = [[Menu new] autorelease];
  Item *clear = item([ImportedHandler class], @"k", nil);
  [recent addItem: clear];
  [file addItem: save];
  [file addItem: revert];
  [file addItem: item(nil, @"", recent)];
  [app addItem: item(nil, @"", file)];

  NSArray *found = MenuItemsWithShortcutsHandledBy([app itemArray], [ImportedHandler class]);

  PASS(![found containsObject: forceQuitItem],
       "Menu's own Force Quit item is left alone");
  PASS([found containsObject: save],
       "an imported item with a shortcut is registered again");
  PASS([found containsObject: clear],
       "an imported item deep in a submenu is registered again");
  PASS(![found containsObject: revert],
       "an imported item without a shortcut is skipped");
  PASS([found count] == 2, "nothing else is picked (%lu)", (unsigned long)[found count]);
  PASS([forceQuitItem target] == forceQuit,
       "walking the menu does not change any item");

  (void)suiteName;
  [arp release];
  return 0;
}
