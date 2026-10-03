/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Stand-in for Menu.app: registers the server name, prints every menu it
 * receives, then validates and activates the item at the index path given in
 * MOCK_ACTIVATE_PATH (e.g. "0,1") to prove the way back works. */

#import <Foundation/Foundation.h>

#import "../../GNUStepMenuIPC.h"

@interface Mock : NSObject
{
  BOOL activated;
}
@end

@implementation Mock

- (oneway void)updateMenuForWindow:(bycopy NSNumber *)windowId
                          menuData:(bycopy NSDictionary *)menuData
                        clientName:(bycopy NSString *)clientName
{
  printf("UPDATE window=%s client=%s\n%s\n", [[windowId description] UTF8String],
         [clientName UTF8String], [[menuData description] UTF8String]);
  fflush(stdout);
  const char *path = getenv("MOCK_ACTIVATE_PATH");
  if (path == NULL || activated)
    return;
  activated = YES;
  NSMutableArray *indexPath = [NSMutableArray array];
  for (NSString *part in [[NSString stringWithUTF8String:path] componentsSeparatedByString:@","])
    [indexPath addObject:@([part intValue])];
  [self performSelector:@selector(activate:)
             withObject:@{ @"client" : clientName, @"window" : windowId, @"path" : indexPath }
             afterDelay:0.3];
}

- (oneway void)unregisterWindow:(bycopy NSNumber *)windowId clientName:(bycopy NSString *)clientName
{
  printf("UNREGISTER window=%s\n", [[windowId description] UTF8String]);
  fflush(stdout);
}

- (void)activate:(NSDictionary *)info
{
  NSConnection *c = [NSConnection connectionWithRegisteredName:info[@"client"] host:nil];
  id proxy = [c rootProxy];
  [proxy setProtocolForProxy:@protocol(GSGNUstepMenuClient)];
  printf("VALIDATE %s\n", [[[(id<GSGNUstepMenuClient>)proxy validateMenuStateForWindow:info[@"window"]] description] UTF8String]);
  id refreshed = [(id<GSGNUstepMenuClient>)proxy refreshedMenuDataForWindow:info[@"window"]];
  if ([refreshed isProxy])
    {
      /* A reply arrives as a proxy; copy it the way Menu.app does. */
      NSData *plist = [NSPropertyListSerialization dataWithPropertyList:refreshed
                                                                 format:NSPropertyListBinaryFormat_v1_0
                                                                options:0
                                                                  error:NULL];
      refreshed = [NSPropertyListSerialization propertyListWithData:plist options:0 format:NULL error:NULL];
    }
  printf("REFRESH %s\n", [[refreshed description] UTF8String]);
  [(id<GSGNUstepMenuClient>)proxy activateMenuItemAtPath:info[@"path"] forWindow:info[@"window"]];
  printf("ACTIVATE SENT\n");
  fflush(stdout);
}

@end

int main(void)
{
  @autoreleasepool
    {
      const char *name = getenv("GAD_MENU_SERVER_NAME");
      NSConnection *c = [[NSConnection alloc] init];
      [c setRootObject:[[Mock alloc] init]];
      if (![c registerName:name ? [NSString stringWithUTF8String:name]
                                : @"org.gnustep.Gershwin.MenuServer"])
        {
          fprintf(stderr, "mock-menu-server: cannot register server name\n");
          return 1;
        }
      printf("READY\n");
      fflush(stdout);
      [[NSRunLoop currentRunLoop] run];
    }
  return 0;
}
