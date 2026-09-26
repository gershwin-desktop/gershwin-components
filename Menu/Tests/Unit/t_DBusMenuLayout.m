/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Electron exports its menu bar over com.canonical.dbusmenu with every
   top-level menu empty: the children of a "children-display=submenu" item
   only exist after AboutToShow has been called on that item, so a single
   GetLayout of the whole tree gave us eight empty menus and no shortcuts.
   DBusMenuLayout fills those holes before the tree is parsed.  Headless: a
   scripted stand-in answers the D-Bus calls. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "DBusMenuLayout.h"

/* Answers GetLayout from a table of canned subtrees and records every call
   in order, so the tests can check both what was fetched and that
   AboutToShow went out before the matching GetLayout. */
@interface FakeConnection : NSObject <DBusMenuLayoutSource>
@property (retain) NSMutableArray *calls;
@property (retain) NSDictionary *subtrees;
@end
@implementation FakeConnection
- (id)init
{
    self = [super init];
    self.calls = [NSMutableArray array];
    self.subtrees = [NSDictionary dictionary];
    return self;
}
- (void)dealloc
{
    self.calls = nil;
    self.subtrees = nil;
    [super dealloc];
}
- (id)callMethod:(NSString *)method
       onService:(NSString *)serviceName
      objectPath:(NSString *)objectPath
       interface:(NSString *)interfaceName
       arguments:(NSArray *)arguments
{
    NSNumber *itemId = [arguments objectAtIndex:0];
    [self.calls addObject:[NSString stringWithFormat:@"%@ %@", method, itemId]];
    if ([method isEqualToString:@"AboutToShow"]) {
        return [NSNumber numberWithBool:NO];
    }
    id subtree = [self.subtrees objectForKey:itemId];
    if (subtree == nil) {
        return nil;
    }
    return [NSArray arrayWithObjects:[NSNumber numberWithUnsignedInt:7], subtree, nil];
}
@end

static NSArray *lazyItem(int itemId, NSString *label)
{
    NSDictionary *props = [NSDictionary dictionaryWithObjectsAndKeys:
        label, @"label", @"submenu", @"children-display", nil];
    return [NSArray arrayWithObjects:[NSNumber numberWithInt:itemId], props,
            [NSArray array], nil];
}

static NSArray *leafItem(int itemId, NSString *label)
{
    NSDictionary *props = [NSDictionary dictionaryWithObjectsAndKeys:label, @"label", nil];
    return [NSArray arrayWithObjects:[NSNumber numberWithInt:itemId], props,
            [NSArray array], nil];
}

static NSArray *node(int itemId, id props, NSArray *children)
{
    return [NSArray arrayWithObjects:[NSNumber numberWithInt:itemId], props, children, nil];
}

static NSArray *childrenOf(NSArray *item)
{
    return [item objectAtIndex:2];
}

static NSString *labelOf(NSArray *item)
{
    return [[DBusMenuLayout propertiesOfLayoutItem:item] objectForKey:@"label"];
}

int main(void)
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    START_SET("DBusMenuLayout");

    /* Electron: an empty top-level menu is filled after AboutToShow. */
    FakeConnection *conn = [[FakeConnection new] autorelease];
    conn.subtrees = [NSDictionary dictionaryWithObjectsAndKeys:
        node(48, [NSDictionary dictionaryWithObject:@"File" forKey:@"label"],
             [NSArray arrayWithObjects:leafItem(53, @"New"), leafItem(54, @"Quit"), nil]),
        [NSNumber numberWithInt:48], nil];
    NSArray *root = node(0, [NSDictionary dictionary],
                         [NSArray arrayWithObjects:lazyItem(48, @"File"), nil]);
    NSArray *filled = [DBusMenuLayout layoutItem:root
                     withLazySubmenusFilledFromService:@":1.403"
                                            objectPath:@"/com/canonical/menu/1"
                                            connection:conn];
    NSArray *file = [childrenOf(filled) objectAtIndex:0];
    PASS_EQUAL([NSNumber numberWithInteger:[childrenOf(file) count]],
               [NSNumber numberWithInteger:2],
               "an empty submenu gets the children the app reveals on AboutToShow");
    PASS_EQUAL(labelOf([childrenOf(file) objectAtIndex:1]), @"Quit",
               "the fetched children keep their order and properties");
    PASS_EQUAL(labelOf(file), @"File",
               "the submenu item keeps its own properties");
    PASS_EQUAL(conn.calls,
               ([NSArray arrayWithObjects:@"AboutToShow 48", @"GetLayout 48", nil]),
               "AboutToShow goes out before the GetLayout of that item");

    /* Chrome: a submenu that already has children is left alone. */
    conn = [[FakeConnection new] autorelease];
    NSArray *populated = node(0, [NSDictionary dictionary],
        [NSArray arrayWithObjects:
            node(10, [NSDictionary dictionaryWithObjectsAndKeys:
                      @"File", @"label", @"submenu", @"children-display", nil],
                 [NSArray arrayWithObjects:leafItem(11, @"New Tab"), nil]),
            leafItem(12, @"Plain"), nil]);
    filled = [DBusMenuLayout layoutItem:populated
      withLazySubmenusFilledFromService:@":1.1" objectPath:@"/m" connection:conn];
    PASS_EQUAL(conn.calls, [NSArray array],
               "populated submenus and leaves cause no D-Bus traffic");
    PASS_EQUAL(filled, populated,
               "a tree without holes comes back unchanged");

    /* Electron: a lazy submenu inside a fetched subtree (Open Recent) is
       filled as well; properties may arrive as an array of dictionaries. */
    conn = [[FakeConnection new] autorelease];
    NSArray *recentProps = [NSArray arrayWithObjects:
        [NSDictionary dictionaryWithObject:@"Open Recent" forKey:@"label"],
        [NSDictionary dictionaryWithObject:@"submenu" forKey:@"children-display"], nil];
    conn.subtrees = [NSDictionary dictionaryWithObjectsAndKeys:
        node(48, [NSDictionary dictionaryWithObject:@"File" forKey:@"label"],
             [NSArray arrayWithObjects:node(67, recentProps, [NSArray array]), nil]),
        [NSNumber numberWithInt:48],
        node(67, recentProps, [NSArray arrayWithObjects:leafItem(68, @"a.tldr"), nil]),
        [NSNumber numberWithInt:67], nil];
    filled = [DBusMenuLayout layoutItem:root
      withLazySubmenusFilledFromService:@":1.403" objectPath:@"/m" connection:conn];
    file = [childrenOf(filled) objectAtIndex:0];
    NSArray *recent = [childrenOf(file) objectAtIndex:0];
    PASS_EQUAL(labelOf([childrenOf(recent) objectAtIndex:0]), @"a.tldr",
               "a lazy submenu nested in a fetched subtree is filled too");
    PASS_EQUAL(conn.calls,
               ([NSArray arrayWithObjects:@"AboutToShow 48", @"GetLayout 48",
                                          @"AboutToShow 67", @"GetLayout 67", nil]),
               "each hole is fetched exactly once");

    /* A GetLayout that fails leaves the item as it was. */
    conn = [[FakeConnection new] autorelease];
    filled = [DBusMenuLayout layoutItem:root
      withLazySubmenusFilledFromService:@":1.403" objectPath:@"/m" connection:conn];
    file = [childrenOf(filled) objectAtIndex:0];
    PASS_EQUAL([NSNumber numberWithInteger:[childrenOf(file) count]],
               [NSNumber numberWithInteger:0],
               "a failed fetch keeps the empty submenu rather than dropping it");
    PASS_EQUAL(labelOf(file), @"File", "a failed fetch keeps the item's properties");

    /* An app that answers every hole with another hole must not keep the
       menu bar busy forever. */
    conn = [[FakeConnection new] autorelease];
    conn.subtrees = [NSDictionary dictionaryWithObject:
        node(48, [NSDictionary dictionary],
             [NSArray arrayWithObjects:lazyItem(48, @"Again"), nil])
        forKey:[NSNumber numberWithInt:48]];
    filled = [DBusMenuLayout layoutItem:root
      withLazySubmenusFilledFromService:@":1.403" objectPath:@"/m" connection:conn];
    PASS([conn.calls count] <= 2 * DBusMenuLayoutMaxDepth,
         "fetching stops at the depth limit");

    END_SET("DBusMenuLayout");
    [pool release];
    return 0;
}
