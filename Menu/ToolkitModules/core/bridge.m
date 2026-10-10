/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#include <stdatomic.h>
#include <unistd.h>
#include <stdlib.h>
#include "gad.h"

#import "../../GNUStepMenuIPC.h"

static NSString *const kServerName = @"org.gnustep.Gershwin.MenuServer";
static NSString *const kClientPrefix = @"org.gnustep.Gershwin.MenuClient.";
static const NSTimeInterval kMaintenanceInterval = 2.0;
static const NSTimeInterval kCallTimeout = 0.5;

static atomic_int gConnected;
static NSThread *gThread;

@interface GADBridge : NSObject <GSGNUstepMenuClient>
{
  NSString *clientName;
  NSConnection *clientConnection;
  NSConnection *serverConnection;
  id serverProxy;
}
+ (GADBridge *)shared;
- (void)run;
- (void)postPush:(NSDictionary *)args;
- (void)postUnregister:(NSNumber *)windowId;
@end

static NSDictionary *DictionaryForNode(const GadNode *node, NSString *title);

static NSArray *ItemsForNode(const GadNode *node)
{
  NSMutableArray *items = [NSMutableArray arrayWithCapacity:(NSUInteger)node->nchildren];
  for (int i = 0; i < node->nchildren; i++)
    {
      const GadNode *child = node->children[i];
      if (child->separator)
        {
          [items addObject:@{ @"isSeparator" : @YES }];
          continue;
        }
      NSString *title = child->title ? [NSString stringWithUTF8String:child->title] : @"";
      if (title == nil)
        title = @"";
      NSMutableDictionary *d = [NSMutableDictionary dictionary];
      d[@"title"] = title;
      d[@"enabled"] = @(child->enabled != 0);
      d[@"state"] = @(child->state);
      d[@"keyEquivalent"] = [NSString stringWithUTF8String:child->key] ?: @"";
      d[@"keyEquivalentModifierMask"] = @(child->mods);
      /* GTK programs react to Control, not to the Command shown for it. */
      if (child->key[0] != '\0')
        d[@"shortcutViaMenu"] = @YES;
      if (child->has_submenu)
        d[@"submenu"] = DictionaryForNode(child, title);
      [items addObject:d];
    }
  return items;
}

static NSDictionary *DictionaryForNode(const GadNode *node, NSString *title)
{
  return @{ @"title" : title, @"items" : ItemsForNode(node) };
}

/* Same flat shape the Eau theme returns, which Menu.app matches by title. */
static void CollectStates(const GadNode *node, NSMutableArray *out)
{
  for (int i = 0; i < node->nchildren; i++)
    {
      const GadNode *child = node->children[i];
      if (child->separator || child->title == NULL || child->title[0] == '\0')
        continue;
      NSString *title = [NSString stringWithUTF8String:child->title];
      if (title == nil)
        continue;
      [out addObject:@[ title, @(child->enabled != 0), @(child->state) ]];
      if (child->has_submenu)
        CollectStates(child, out);
    }
}

@implementation GADBridge

+ (GADBridge *)shared
{
  static GADBridge *bridge;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ bridge = [[GADBridge alloc] init]; });
  return bridge;
}

- (NSString *)serverName
{
  /* Test seam: lets the test suite run a mock server next to a real Menu.app. */
  const char *override = getenv("GAD_MENU_SERVER_NAME");
  return override ? [NSString stringWithUTF8String:override] : kServerName;
}

- (void)setConnected:(BOOL)connected
{
  BOOL was = atomic_load(&gConnected) != 0;
  atomic_store(&gConnected, connected ? 1 : 0);
  if (connected && !was)
    gad_module_connected();
}

- (void)connectionDied:(NSNotification *)note
{
  if ([note object] == serverConnection)
    {
      serverProxy = nil;
      serverConnection = nil;
      [self setConnected:NO];
    }
}

- (BOOL)clientNameResolves
{
  /* A restarted name server (gdnc) forgets our registration while the
     connection still looks valid; Menu.app could then no longer reach us. */
  NSConnection *found = [NSConnection connectionWithRegisteredName:clientName host:nil];
  return found != nil;
}

- (void)ensureClientRegistered
{
  if (clientConnection != nil && [self clientNameResolves])
    return;
  clientConnection = [[NSConnection alloc] init];
  [clientConnection setRootObject:self];
  if (![clientConnection registerName:clientName])
    {
      NSLog(@"gtk-appmenu-do: cannot register %@", clientName);
      clientConnection = nil;
    }
}

- (void)ensureServerConnected
{
  if (serverProxy != nil && [serverConnection isValid])
    return;
  serverProxy = nil;
  serverConnection = nil;
  [self setConnected:NO];

  NSConnection *c = [NSConnection connectionWithRegisteredName:[self serverName] host:nil];
  if (c == nil)
    return;
  /* -rootProxy waits on the reply timeout, which defaults to practically forever. */
  [c setRequestTimeout:kCallTimeout];
  [c setReplyTimeout:kCallTimeout];
  id proxy = [c rootProxy];
  if (proxy == nil)
    return;
  [proxy setProtocolForProxy:@protocol(GSGNUstepMenuServer)];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(connectionDied:)
                                               name:NSConnectionDidDieNotification
                                             object:c];
  serverConnection = c;
  serverProxy = proxy;
  [self setConnected:YES];
}

- (void)maintenance:(NSTimer *)timer
{
  [self ensureClientRegistered];
  [self ensureServerConnected];
}

- (void)run
{
  @autoreleasepool
    {
      clientName = [[kClientPrefix stringByAppendingFormat:@"%d", (int)getpid()] copy];
      [self ensureClientRegistered];
      [self ensureServerConnected];
      [NSTimer scheduledTimerWithTimeInterval:kMaintenanceInterval
                                       target:self
                                     selector:@selector(maintenance:)
                                     userInfo:nil
                                      repeats:YES];
    }
  NSRunLoop *loop = [NSRunLoop currentRunLoop];
  for (;;)
    {
      @autoreleasepool
        {
          [loop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
        }
    }
}

- (void)doPush:(NSDictionary *)args
{
  [self ensureServerConnected];
  if (serverProxy == nil)
    return;
  @try
    {
      [(id<GSGNUstepMenuServer>)serverProxy updateMenuForWindow:args[@"window"]
                                                       menuData:args[@"data"]
                                                     clientName:clientName];
    }
  @catch (NSException *e)
    {
      NSLog(@"gtk-appmenu-do: push failed: %@", e);
      [self setConnected:NO];
      serverProxy = nil;
    }
}

- (void)doUnregister:(NSNumber *)windowId
{
  if (serverProxy == nil)
    return;
  @try
    {
      [(id<GSGNUstepMenuServer>)serverProxy unregisterWindow:windowId clientName:clientName];
    }
  @catch (NSException *e)
    {
      NSLog(@"gtk-appmenu-do: unregister failed: %@", e);
    }
}

- (void)postPush:(NSDictionary *)args
{
  [self performSelector:@selector(doPush:)
               onThread:gThread
             withObject:args
          waitUntilDone:NO];
}

- (void)postUnregister:(NSNumber *)windowId
{
  [self performSelector:@selector(doUnregister:)
               onThread:gThread
             withObject:windowId
          waitUntilDone:NO];
}

#pragma mark GSGNUstepMenuClient

- (oneway void)activateMenuItemAtPath:(NSArray *)indexPath forWindow:(NSNumber *)windowId
{
  NSUInteger n = [indexPath count];
  int *path = malloc(sizeof(int) * (n ? n : 1));
  if (path == NULL)
    return;
  for (NSUInteger i = 0; i < n; i++)
    path[i] = [[indexPath objectAtIndex:i] intValue];
  gad_module_activate([windowId unsignedLongValue], path, (int)n);
  free(path);
}

- (oneway void)requestMenuUpdateForWindow:(NSNumber *)windowId
{
  gad_module_request([windowId unsignedLongValue]);
}

- (bycopy id)validateMenuStateForWindow:(NSNumber *)windowId
{
  GadNode *root = gad_module_snapshot([windowId unsignedLongValue]);
  if (root == NULL)
    return nil;
  NSMutableArray *flat = [NSMutableArray array];
  CollectStates(root, flat);
  gad_node_free(root);
  return flat;
}

/* nil: no menu of this window needs refreshing; an empty dictionary: some do
   but nothing changed; otherwise the new menu data. */
- (bycopy id)refreshedMenuDataForWindow:(NSNumber *)windowId
{
  if (!gad_module_has_dynamic_menus())
    return nil;
  int changed = 0;
  GadNode *root = gad_module_refresh([windowId unsignedLongValue], &changed);
  if (root == NULL)
    return [NSDictionary dictionary];
  NSDictionary *data = DictionaryForNode(root, @"");
  gad_node_free(root);
  return data;
}

- (oneway void)requestApplicationMenuUpdate
{
  /* GTK has no application-level menu without a window. */
}

@end

#pragma mark C interface

extern char **environ;

void gad_bridge_start(void)
{
#if !defined(__linux__)
  /* Foundation learns the arguments and the environment of a program from the
     C runtime on Linux only.  Everywhere else the program that loads this code
     does not know Foundation, so it is told here; the arguments themselves are
     of no use to the bridge. */
  static char *argv[2];
  argv[0] = (char *)getprogname();
  GSInitializeProcess(1, argv, environ);
#endif
  GADBridge *bridge = [GADBridge shared];
  gThread = [[NSThread alloc] initWithTarget:bridge selector:@selector(run) object:nil];
  [gThread setName:@"gtk-appmenu-do"];
  [gThread start];
}

int gad_bridge_connected(void)
{
  return atomic_load(&gConnected);
}

void gad_bridge_push(unsigned long xid, const GadNode *root)
{
  @autoreleasepool
    {
      /* The module reads the program's own menu bar, so this is the whole menu
         of the window and Menu.app must not prefer another protocol for it. */
      NSMutableDictionary *data = [DictionaryForNode(root, @"") mutableCopy];
      data[@"authoritative"] = @YES;
      NSDictionary *args = @{ @"window" : @((unsigned int)xid), @"data" : data };
      [[GADBridge shared] postPush:args];
    }
}

void gad_bridge_unregister(unsigned long xid)
{
  @autoreleasepool
    {
      [[GADBridge shared] postUnregister:@((unsigned int)xid)];
    }
}
