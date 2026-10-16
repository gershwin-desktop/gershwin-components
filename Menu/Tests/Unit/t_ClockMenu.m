/* t_ClockMenu.m - ObjectTesting coverage for the Clock extra's menu.
 *
 * The extra caches its Global submenu (the world-clock rows) and hands the
 * same NSMenu object to a new menu item on every build. NSMenuItem refuses a
 * submenu that already has a supermenu, so every build after the first one
 * raised NSInvalidArgumentException. GSMenuExtraInstance's -menu wrapper
 * turns an exception into nil, MenuExtraManager then gives the extra's menu
 * bar item no submenu at all, and the date/time menu opens empty - with no
 * long-date row.
 *
 * The test replays the build order MenuExtraManager really drives (see
 * MenuExtraManager.m): applyEnabledSet builds each extra's menu BEFORE
 * loadMenuExtras calls menuExtraDidLoad, and hangs it off the menu bar item;
 * createExtrasMenuView then builds it again with that menu still attached;
 * and every open goes through menuNeedsUpdate:, which asks for one more
 * fresh menu the same way. The last set checks what the user then sees.
 *
 * Building an NSMenu creates the menu panel, so this test needs an X display
 * (DISPLAY), like t_PlayerViews.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <AppKit/AppKit.h>
#import "Testing.h"
#import "ClockExtra.h"
#import "GSMenuExtraContext.h"
#include "../../MenuItemSubmenuSwizzle.m"
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

/* Zombies report a message to a freed object on stderr, so the set below
 * reads stderr back from a file instead of hoping for a crash. */
static NSString *StderrCapturedWhile(void (^block)(void))
{
  char path[] = "/tmp/t_ClockMenu_stderr_XXXXXX";
  int fd = mkstemp(path);
  int saved = dup(2);
  fflush(stderr);
  dup2(fd, 2);
  block();
  fflush(stderr);
  dup2(saved, 2);
  close(saved);
  close(fd);
  NSString *text = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:path]
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
  unlink(path);
  return text ? text : @"";
}

/* What MenuExtraManager does as the delegate of an extra's menu: on
 * menuNeedsUpdate: it asks the extra for a fresh menu and moves that menu's
 * items into the one it is the delegate of, dropping the old items
 * (replaceMenu:withMenu:), guarded against nesting into itself exactly like
 * the real one (_needsUpdateGuard). */
@interface ManagerStandIn : NSObject
@property (assign) ClockExtra *extra;
@property (retain) NSMenuItem *barItem;
@property (assign) BOOL busy;
@end
@implementation ManagerStandIn
- (void)dealloc { self.barItem = nil; [super dealloc]; }
- (void)menuNeedsUpdate:(NSMenu *)menu
{
  if (self.busy) return;
  self.busy = YES;
  NSMenu *fresh = [self.extra menu];
  if (fresh && fresh != menu) {
    while ([menu numberOfItems] > 0) [menu removeItemAtIndex:0];
    while ([fresh numberOfItems] > 0) {
      NSMenuItem *item = [fresh itemAtIndex:0];
      [fresh removeItemAtIndex:0];
      [menu addItem:item];
    }
  }
  self.busy = NO;
}
- (void)menuWillOpen:(NSMenu *)menu { [self menuNeedsUpdate:menu]; }
- (void)menuDidClose:(NSMenu *)menu { (void)menu; }
@end

/* What MenuExtraManager does with what an extra returns: hang it off the
 * extra's menu bar item. That attachment is what makes the menu the child of
 * another menu, which is exactly what NSMenuItem checks before it will take
 * a submenu. */
static void AttachToMenuBar(NSMenu *extrasMenu, NSMenu *menu)
{
  NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:@"14:07"
                                                 action:NULL
                                          keyEquivalent:@""] autorelease];
  [item setSubmenu:menu];
  [extrasMenu addItem:item];
}

/* The row the manager shows first: the local date in full style, the same
 * formatter the extra builds its date row with. */
static NSString *LongDateNow(void)
{
  NSDateFormatter *full = [[[NSDateFormatter alloc] init] autorelease];
  [full setTimeStyle:NSDateFormatterNoStyle];
  [full setDateStyle:NSDateFormatterFullStyle];
  return [full stringFromDate:[NSDate date]];
}

/* The Global item and its rows, so the assertions read as what the user
 * opens rather than as indexes. */
static NSMenuItem *GlobalItem(NSMenu *menu)
{
  NSUInteger i;
  for (i = 0; i < [menu numberOfItems]; i++) {
    NSMenuItem *item = [menu itemAtIndex:i];
    if ([[item title] isEqualToString:@"Global"]) return item;
  }
  return nil;
}

int main(int argc, char **argv)
{
  /* NSObject reads NSZombieEnabled in +initialize, which library
   * constructors have already run by the time main starts, so the tool
   * starts itself over with the variable in place. */
  if (getenv("NSZombieEnabled") == NULL) {
    setenv("NSZombieEnabled", "YES", 1);
    execv(argv[0], argv);
    perror("execv");
    return 1;
  }
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  [NSApplication sharedApplication];

  ClockExtra *e = [[ClockExtra alloc] init];
  NSMenu *extrasMenu = [[[NSMenu alloc] initWithTitle:@"Extras"] autorelease];
  NSMenu *menu = nil;

  /* --- the manager's build order, replayed --- */
  START_SET("builds MenuExtraManager drives");

    /* applyEnabledSet, before the extra has been loaded. */
    PASS_RUNS(({ menu = [e menu]; }),
              "the first build runs without raising");
    PASS(menu != nil, "and hands back a menu");
    if (menu) AttachToMenuBar(extrasMenu, menu);

    [e menuExtraDidLoad];

    /* createExtrasMenuView: a second menu for the same extra, while the
       first one is still the submenu of its menu bar item. */
    menu = nil;
    PASS_RUNS(({ menu = [e menu]; }),
              "the second build runs with the first menu still attached");
    PASS(menu != nil,
         "and hands back a menu (nil means an exception was caught for it)");
    if (menu) AttachToMenuBar(extrasMenu, menu);

    /* menuNeedsUpdate:, on every open: one more fresh menu, the same way. */
    menu = nil;
    PASS_RUNS(({ menu = [e menu]; }),
              "the third build runs with the menu on screen still attached");
    PASS(menu != nil,
         "and hands back the menu the manager swaps in (nil leaves the old menu on screen)");

  END_SET("builds MenuExtraManager drives");

  /* --- what the user sees when the menu opens --- */
  START_SET("the open menu");

    menu = nil;
    PASS_RUNS(({ menu = [e menu]; }),
              "the menu is built for the open");
    [e menuExtraWillOpenMenu];

    if (menu) {
      PASS([menu numberOfItems] >= 3,
           "the menu has rows (%ld)", (long)[menu numberOfItems]);

      NSMenuItem *dateItem = [menu itemAtIndex:0];
      PASS([[dateItem title] length] > 0,
           "the first row carries a date, not an empty title");
      PASS_EQUAL([dateItem title], LongDateNow(),
                 "and it is the long date, in full style");

      NSMenuItem *global = GlobalItem(menu);
      PASS(global != nil && [global hasSubmenu],
           "the Global item is there with a submenu");
      PASS(global != nil && [[global submenu] numberOfItems] > 0,
           "and the submenu has world clock rows");
    } else {
      PASS(NO, "the open has a menu to show (none came back from -menu)");
    }

  END_SET("the open menu");

  /* --- the manager's delegate, answering while the extra still builds --- */
  START_SET("a build while the previous menu is still attached");

    /* MenuExtraManager is the delegate of every menu an extra hands it and
     * answers menuNeedsUpdate: by asking the extra for a fresh menu and
     * swapping the old one out (replaceMenu:withMenu:). Anything a build does
     * to an item of the previous menu - detaching a shared submenu, say -
     * makes that menu post itemChanged:, which reaches this delegate, which
     * re-enters -menu and frees the previous menu and its items while the
     * outer build is still using one of them. Menu crashed at startup, over
     * and over, on the second build. Zombies turn that use of a freed item
     * into a line on stderr the test can read. */
    ManagerStandIn *manager = [[[ManagerStandIn alloc] init] autorelease];
    manager.extra = e;
    manager.barItem = [[[NSMenuItem alloc] initWithTitle:@"14:07"
                                                  action:NULL
                                           keyEquivalent:@""] autorelease];
    /* Only the bar item owns the first menu, as in Menu: the manager keeps
     * no other reference, so the swap inside the re-entered build frees it,
     * and its items with it. */
    NSAutoreleasePool *firstBuild = [NSAutoreleasePool new];
    NSMenu *first = [e menu];
    [first setDelegate:manager];
    [manager.barItem setSubmenu:first];
    [firstBuild release];

    __block NSMenu *rebuilt = nil;
    NSString *complaints = StderrCapturedWhile(^{
      NSAutoreleasePool *again = [NSAutoreleasePool new];
      rebuilt = [[e menu] retain];
      [again release];
    });
    menu = rebuilt;
    PASS([complaints rangeOfString:@"deallocated instance"].location == NSNotFound,
         "the rebuild survives the manager re-entering it (%s)",
         [complaints UTF8String]);
    PASS(menu != nil && GlobalItem(menu) != nil && [GlobalItem(menu) hasSubmenu],
         "and the Global item of the new menu has its submenu");
    PASS(menu != nil && [[GlobalItem(menu) submenu] supermenu] == menu,
         "which belongs to the new menu");
    PASS(menu != nil && [[GlobalItem(menu) submenu] numberOfItems] > 0,
         "and has world clock rows");
    [menu release];

  END_SET("a build while the previous menu is still attached");

  [e release];
  [arp release];
  return 0;
}
