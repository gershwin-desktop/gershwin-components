/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GNUStepMenuActionHandler.h"
#import "GNUStepMenuIPC.h"
#import "GNUStepMenuImporter.h"
#import <Foundation/NSConnection.h>
#import <AppKit/NSMenuItem.h>

/* Send ports of GNUstep clients (keyed by clientName), not NSConnections: a
   connection receives its replies on the default receive port of the thread
   that created it, so a synchronous call such as rootProxy made on any other
   thread raises "Waiting for reply ... in wrong thread".  Connections made by
   the background probes therefore must never reach the main thread. */
static NSMutableDictionary *sendPortCache = nil;
static NSLock *sendPortCacheLock = nil;

@implementation GNUStepMenuActionHandler

+ (void)initialize
{
    if (self == [GNUStepMenuActionHandler class]) {
        sendPortCache = [[NSMutableDictionary alloc] init];
        sendPortCacheLock = [[NSLock alloc] init];
    }
}

/* Return a connection for the CALLING thread to a client whose port is
   cached, WITHOUT doing a name lookup, or nil if the client is not yet cached.
   The main-thread refresh path uses this so a blocking
   connectionWithRegisteredName: can never run on the main thread. */
+ (NSConnection *)existingConnectionForClient:(NSString *)clientName
{
    [sendPortCacheLock lock];
    NSPort *sendPort = [sendPortCache objectForKey:clientName];
    if (sendPort && ![sendPort isValid]) {
        [sendPortCache removeObjectForKey:clientName];
        sendPort = nil;
    }
    [sendPortCacheLock unlock];
    if (!sendPort) return nil;

    /* Same receive port choice as connectionWithRegisteredName:, so this
       thread gets the very connection that lookup would have returned
       (NSConnection reuses the connection of a receive/send port pair). */
    NSPort *receivePort = [[NSConnection defaultConnection] receivePort];
    if (![receivePort isMemberOfClass:[sendPort class]]) {
        NSLog(@"GNUStepMenuActionHandler: cannot reach menu client %@: its %@ does not match this thread's %@",
              clientName, [sendPort class], [receivePort class]);
        return nil;
    }
    return [NSConnection connectionWithReceivePort:receivePort sendPort:sendPort];
}

/* Record the port of a connection discovered by a background probe, so the
   main thread finds it cached and skips the blocking DO name lookup entirely. */
+ (void)cacheConnection:(NSConnection *)connection forClient:(NSString *)clientName
{
    NSPort *sendPort = [connection sendPort];
    if (!sendPort || !clientName) return;
    [sendPortCacheLock lock];
    NSPort *existing = [sendPortCache objectForKey:clientName];
    if (existing == nil || ![existing isValid]) {
        [sendPortCache setObject:sendPort forKey:clientName];
    }
    [sendPortCacheLock unlock];
}

+ (void)performMenuAction:(id)sender
{
    
    /* Every early return below drops the user's menu action.  Log them all:
       a dropped action otherwise leaves no trace (in the UI tests the About
       box just never appears). */
    if (![sender isKindOfClass:[NSMenuItem class]]) {
        NSLog(@"GNUStepMenuActionHandler: dropping action: sender %@ is not an NSMenuItem", sender);
        return;
    }

    NSMenuItem *menuItem = (NSMenuItem *)sender;
    NSDictionary *info = [menuItem representedObject];
    
    NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Menu item '%@' representedObject: %@", [menuItem title], info);
    
    if (![info isKindOfClass:[NSDictionary class]]) {
        NSLog(@"GNUStepMenuActionHandler: dropping '%@': missing action metadata", [menuItem title]);
        return;
    }

    NSString *clientName = [info objectForKey:@"clientName"];
    NSNumber *windowId = [info objectForKey:@"windowId"];
    NSArray *indexPath = [info objectForKey:@"indexPath"];

    NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Extracted - clientName: %@, windowId: %@, indexPath: %@", clientName, windowId, indexPath);

    if (!clientName || !windowId || !indexPath) {
        NSLog(@"GNUStepMenuActionHandler: dropping '%@': incomplete action metadata %@", [menuItem title], info);
        return;
    }

    // Execute the IPC callback on the main thread to keep the NSConnection stable.
    // GNUstep DO requires connection/proxy traffic to run on the thread that
    // services the connection (the main run loop); sending from a GCD worker
    // thread silently fails and poisons the cached connection, which broke all
    // GNUstep menu actions when this was briefly moved to a background queue.
    // The oneway call is non-blocking, so this should not freeze Menu.app.
    NSDictionary *backgroundInfo = @{ @"clientName": clientName, @"windowId": windowId, @"indexPath": indexPath, @"menuItemTitle": [menuItem title] };
    [self _performMenuActionInBackground:backgroundInfo];
}

+ (void)_performMenuActionInBackground:(NSDictionary *)info
{
    NSString *clientName = info[@"clientName"];
    NSNumber *windowId = info[@"windowId"];
    NSArray *indexPath = info[@"indexPath"];
    NSString *menuItemTitle = info[@"menuItemTitle"];

    /* The displayed menu item may carry the client name of a PREVIOUS app
       instance (X reuses window IDs across relaunches).  Resolve the CURRENT
       client for the window from the importer - the authoritative mapping from
       the last accepted menu push - so actions reach the live process instead
       of silently targeting a dead one.  Fall back to the item's own name. */
    NSString *currentClient = [GNUStepMenuImporter currentClientNameForWindow:
      [windowId unsignedLongValue]];
    if ([currentClient length] > 0)
        clientName = currentClient;

    NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Main thread - getting connection to client %@", clientName);

    /* Menu item selection runs on the main thread.  Only use a connection that
       is already cached: a blocking connectionWithRegisteredName: here would
       freeze the menu bar if this client (e.g. Workspace) is stalled.  The
       background probes cache connections eagerly, so a healthy client is
       normally found here. */
    NSConnection *connection = [self existingConnectionForClient:clientName];
    if (!connection) {
        /* The background probe may not have cached this client's connection
           yet (a freshly relaunched app registers its MenuClient after Menu
           scanned).  Fall back to a name lookup here - the client pushed its
           menu, so it is alive and registered.  On a slow VM the name lookup
           can transiently fail; retry briefly so a menu action is not silently
           dropped (which made the About box never appear in the uitests).
           The lookup already blocks on the DO name server, so a bounded retry
           adds no new freeze risk. */
        for (int i = 0; i < 5 && !connection; i++) {
            @try {
                connection = [NSConnection connectionWithRegisteredName:clientName
                                                                   host:nil];
                if (connection)
                    [self cacheConnection:connection forClient:clientName];
            } @catch (NSException *e) {
                connection = nil;
            }
            if (!connection && i < 4)
                [NSThread sleepForTimeInterval:0.2];
        }
    }
    if (!connection) {
        NSLog(@"GNUStepMenuActionHandler: dropping '%@' for window %@: no connection to menu client %@",
              menuItemTitle, windowId, clientName);
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Have connection to client %@", clientName);

    id proxy = [connection rootProxy];
    if (!proxy) {
        NSLog(@"GNUStepMenuActionHandler: dropping '%@': no root proxy for menu client %@",
              menuItemTitle, clientName);
        return;
    }

    [proxy setProtocolForProxy:@protocol(GSGNUstepMenuClient)];
    
    NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Proxy protocol set, about to call activateMenuItemAtPath");
    NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Proxy responds to selector: %d", [proxy respondsToSelector:@selector(activateMenuItemAtPath:forWindow:)]);

    @try {
        // The oneway modifier ensures this doesn't block waiting for a response
        NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Calling activateMenuItemAtPath:forWindow: on proxy");
        [(id<GSGNUstepMenuClient>)proxy activateMenuItemAtPath:indexPath forWindow:windowId];
        NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Call completed, dispatched action for menu item '%@'", menuItemTitle);
    }
    @catch (NSException *exception) {
        NSLog(@"GNUStepMenuActionHandler: dropping '%@': %@ sending it to menu client %@: %@",
              menuItemTitle, [exception name], clientName, [exception reason]);
    }
}

@end
