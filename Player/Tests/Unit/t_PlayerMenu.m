/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_PlayerMenu.m - Player's main menu: every shortcut does one thing, and
 * the commands a player needs are there.  NSMenu needs NSApp, so this
 * test needs an X display (DISPLAY). */

#import <AppKit/AppKit.h>
#import "Testing.h"
#import "PlayerMenu.h"

static void collect(NSMenu *menu, NSString *path, NSMutableArray *out)
{
  NSEnumerator *e = [[menu itemArray] objectEnumerator];
  NSMenuItem *item;
  while ((item = [e nextObject]) != nil)
    {
      if ([item isSeparatorItem])
        continue;
      NSString *p = [path length] ? [path stringByAppendingFormat: @"/%@", [item title]]
                                  : [item title];
      if ([item submenu])
        collect([item submenu], p, out);
      else
        [out addObject: @[p, item]];
    }
}

static NSMenuItem *find(NSArray *items, NSString *path)
{
  NSEnumerator *e = [items objectEnumerator];
  NSArray *pair;
  while ((pair = [e nextObject]) != nil)
    if ([[pair objectAtIndex: 0] isEqualToString: path])
      return [pair objectAtIndex: 1];
  return nil;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  [NSApplication sharedApplication];
  id target = [[NSObject new] autorelease];
  NSMenu *menu = [PlayerMenu mainMenuWithTarget: target];
  NSMutableArray *items = [NSMutableArray array];
  collect(menu, @"", items);

  START_SET("shortcuts")
    NSMutableDictionary *seen = [NSMutableDictionary dictionary];
    NSEnumerator *e = [items objectEnumerator];
    NSArray *pair;
    while ((pair = [e nextObject]) != nil)
      {
        NSMenuItem *item = [pair objectAtIndex: 1];
        NSString *key = [item keyEquivalent];
        if ([key length] == 0)
          continue;
        NSUInteger mask = [item keyEquivalentModifierMask];
        PASS(mask & NSCommandKeyMask,
             "%s needs Command, a bare key would fire while typing",
             [[pair objectAtIndex: 0] UTF8String]);
        /* NSMenu treats an uppercase letter as Shift + letter */
        if (![key isEqualToString: [key lowercaseString]])
          mask |= NSShiftKeyMask;
        NSString *combo = [NSString stringWithFormat: @"%@-%lu",
                            [key lowercaseString], (unsigned long)mask];
        NSString *other = [seen objectForKey: combo];
        PASS(other == nil, "%s has a shortcut of its own (clashes with %s)",
             [[pair objectAtIndex: 0] UTF8String], [other UTF8String]);
        [seen setObject: [pair objectAtIndex: 0] forKey: combo];
      }
  END_SET("shortcuts")

  START_SET("commands")
    NSArray *expected = @[
      @[@"Player/Quit Player", @"terminate:"],
      @[@"Player/Preferences...", @"openPreferences:"],
      @[@"File/Open...", @"openFile:"],
      @[@"File/Open URL...", @"openURL:"],
      @[@"File/Close Window", @"performClose:"],
      @[@"Playback/Play", @"playPause:"],
      @[@"Playback/Stop", @"stop:"],
      @[@"Playback/Next Track", @"nextTrack:"],
      @[@"Playback/Previous Track", @"previousTrack:"],
      @[@"Playback/Increase Volume", @"increaseVolume:"],
      @[@"Playback/Decrease Volume", @"decreaseVolume:"],
      @[@"Playback/Mute", @"toggleMute:"],
      @[@"Playback/Repeat", @"toggleRepeat:"],
      @[@"Playback/Shuffle", @"toggleShuffle:"],
      @[@"View/Enter Full Screen", @"toggleFullscreen:"],
      @[@"Radio/Internet Radio", @"toggleRadioMode:"]];
    NSEnumerator *e = [expected objectEnumerator];
    NSArray *want;
    while ((want = [e nextObject]) != nil)
      {
        NSMenuItem *item = find(items, [want objectAtIndex: 0]);
        const char *path = [[want objectAtIndex: 0] UTF8String];
        PASS(item != nil, "%s exists", path);
        PASS_EQUAL(NSStringFromSelector([item action]), [want objectAtIndex: 1],
                   "%s sends the right action", path);
      }
    PASS([find(items, @"File/Close Window") target] == nil,
         "Close Window goes to the key window, not to the controller");
    PASS([find(items, @"Playback/Play") target] == target,
         "player commands go to the controller");
    PASS(find(items, @"Radio/Stop Radio") == nil,
         "no second Stop: Playback/Stop stops the radio too");
    PASS(find(items, @"Radio/Open Radio Stream...") == nil,
         "no second URL dialog next to File/Open URL...");
  END_SET("commands")

  [arp release];
  return 0;
}
