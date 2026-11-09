/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "KCDBusConnection.h"
#import "KCDBusMarshal.h"

static NSError *KCDBusError(DBusError *err, NSString *fallback)
{
  NSString *text = dbus_error_is_set(err)
    ? [NSString stringWithFormat: @"%s: %s", err->name, err->message]
    : fallback;
  if (dbus_error_is_set(err))
    dbus_error_free(err);
  return [NSError errorWithDomain: @"org.freedesktop.DBus" code: 1
    userInfo: [NSDictionary dictionaryWithObject: text
                                          forKey: NSLocalizedDescriptionKey]];
}

@interface KCDBusConnection () <RunLoopEvents>
- (void) dispatchPending;
- (id<KCDBusObjectHandler>) handlerForMessage: (DBusMessage *)message;
- (void) clientVanished: (NSString *)uniqueName;
@end

static DBusHandlerResult KCObjectMessage(DBusConnection *raw,
                                         DBusMessage *message, void *data)
{
  KCDBusConnection *self = (__bridge KCDBusConnection *)data;
  id<KCDBusObjectHandler> handler = nil;

  if (dbus_message_get_type(message) != DBUS_MESSAGE_TYPE_METHOD_CALL)
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
  handler = [self handlerForMessage: message];
  if (handler == nil)
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
  @autoreleasepool
    {
      [handler connection: self handleMessage: message];
    }
  return DBUS_HANDLER_RESULT_HANDLED;
}

static DBusHandlerResult KCFilter(DBusConnection *raw, DBusMessage *message,
                                  void *data)
{
  KCDBusConnection *self = (__bridge KCDBusConnection *)data;

  if (dbus_message_is_signal(message, DBUS_INTERFACE_DBUS, "NameOwnerChanged"))
    {
      const char *name = NULL;
      const char *oldOwner = NULL;
      const char *newOwner = NULL;

      if (dbus_message_get_args(message, NULL,
            DBUS_TYPE_STRING, &name, DBUS_TYPE_STRING, &oldOwner,
            DBUS_TYPE_STRING, &newOwner, DBUS_TYPE_INVALID)
        && name[0] == ':' && newOwner[0] == '\0')
        {
          @autoreleasepool
            {
              [self clientVanished: [NSString stringWithUTF8String: name]];
            }
        }
    }
  return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

static const DBusObjectPathVTable KCVTable = {
  NULL, KCObjectMessage, NULL, NULL, NULL, NULL
};

@implementation KCDBusConnection
{
  DBusConnection *_connection;
  NSMutableArray *_handlers;
  NSArray *_modes;
}

- (instancetype) initWithSessionBus: (NSError **)error
                       runLoopModes: (NSArray *)modes
{
  if ((self = [super init]) != nil)
    {
      DBusError err;
      NSEnumerator *e;
      NSString *mode;
      int fd = -1;

      dbus_error_init(&err);
      /* A private connection: nothing else in the process shares its
       * dispatch queue, so our run loop watcher sees every message. */
      _connection = dbus_bus_get_private(DBUS_BUS_SESSION, &err);
      if (_connection == NULL)
        {
          if (error != NULL)
            *error = KCDBusError(&err, @"Cannot connect to the session bus");
          return nil;
        }
      _handlers = [NSMutableArray new];

      if (!dbus_connection_add_filter(_connection, KCFilter,
                                      (__bridge void *)self, NULL))
        [NSException raise: NSMallocException format: @"dbus filter"];
      dbus_bus_add_match(_connection,
        "type='signal',sender='org.freedesktop.DBus',"
        "interface='org.freedesktop.DBus',member='NameOwnerChanged'", &err);
      if (dbus_error_is_set(&err))
        {
          if (error != NULL)
            *error = KCDBusError(&err, nil);
          return nil;
        }

      if (!dbus_connection_get_unix_fd(_connection, &fd))
        {
          if (error != NULL)
            *error = KCDBusError(&err, @"The session bus has no socket");
          return nil;
        }
      _modes = [modes copy];
      e = [modes objectEnumerator];
      while ((mode = [e nextObject]) != nil)
        [[NSRunLoop currentRunLoop] addEvent: (void *)(intptr_t)fd
                                        type: ET_RDESC
                                     watcher: self
                                     forMode: mode];
    }
  return self;
}

- (void) dealloc
{
  if (_connection != NULL)
    {
      dbus_connection_close(_connection);
      dbus_connection_unref(_connection);
    }
}

- (NSString *) uniqueName
{
  return [NSString stringWithUTF8String: dbus_bus_get_unique_name(_connection)];
}

- (void) scheduleDispatch
{
  /* Blocking libdbus calls may read messages into the queue without the
   * socket becoming readable again, so look at the queue explicitly. */
  [self performSelector: @selector(dispatchPending) withObject: nil
             afterDelay: 0.0
                inModes: _modes];
}

- (BOOL) requestName: (NSString *)name error: (NSError **)error
{
  DBusError err;
  int result;

  dbus_error_init(&err);
  result = dbus_bus_request_name(_connection, [name UTF8String],
                                 DBUS_NAME_FLAG_DO_NOT_QUEUE, &err);
  [self scheduleDispatch];
  if (result == DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER
    || result == DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER)
    return YES;
  if (error != NULL)
    *error = KCDBusError(&err, [NSString stringWithFormat:
      @"Another program already provides %@ on this session bus.", name]);
  return NO;
}

- (void) registerFallbackPath: (NSString *)path
                      handler: (id<KCDBusObjectHandler>)handler
{
  [_handlers addObject: [NSArray arrayWithObjects: path, handler, nil]];
  if (!dbus_connection_register_fallback(_connection, [path UTF8String],
                                         &KCVTable, (__bridge void *)self))
    [NSException raise: NSInternalInconsistencyException
                format: @"cannot register D-Bus path %@", path];
}

- (id<KCDBusObjectHandler>) handlerForMessage: (DBusMessage *)message
{
  NSString *path = [NSString stringWithUTF8String: dbus_message_get_path(message)];
  NSEnumerator *e = [_handlers objectEnumerator];
  NSArray *entry;

  while ((entry = [e nextObject]) != nil)
    {
      NSString *prefix = [entry objectAtIndex: 0];
      if ([path isEqualToString: prefix]
        || [path hasPrefix: [prefix stringByAppendingString: @"/"]])
        return [entry objectAtIndex: 1];
    }
  return nil;
}

- (void) clientVanished: (NSString *)uniqueName
{
  NSEnumerator *e = [_handlers objectEnumerator];
  NSArray *entry;

  while ((entry = [e nextObject]) != nil)
    {
      id<KCDBusObjectHandler> handler = [entry objectAtIndex: 1];
      if ([handler respondsToSelector: @selector(connection:clientDidVanish:)])
        [handler connection: self clientDidVanish: uniqueName];
    }
}

- (void) send: (DBusMessage *)message
{
  if (!dbus_connection_send(_connection, message, NULL))
    [NSException raise: NSMallocException format: @"dbus_connection_send"];
  dbus_connection_flush(_connection);
  dbus_message_unref(message);
}

- (void) replyTo: (DBusMessage *)call
       signature: (NSString *)signature
          values: (NSArray *)values
{
  DBusMessage *reply;

  if (dbus_message_get_no_reply(call))
    return;
  reply = dbus_message_new_method_return(call);
  if (reply == NULL)
    [NSException raise: NSMallocException format: @"dbus reply"];
  @try
    {
      KCDBusAppendArguments(reply, signature, values);
    }
  @catch (NSException *e)
    {
      dbus_message_unref(reply);
      @throw;
    }
  [self send: reply];
}

- (void) replyTo: (DBusMessage *)call
       errorName: (NSString *)name
         message: (NSString *)text
{
  DBusMessage *reply;

  if (dbus_message_get_no_reply(call))
    return;
  reply = dbus_message_new_error(call, [name UTF8String], [text UTF8String]);
  if (reply == NULL)
    [NSException raise: NSMallocException format: @"dbus error reply"];
  [self send: reply];
}

- (void) emitSignal: (NSString *)member
          interface: (NSString *)interface
               path: (NSString *)path
          signature: (NSString *)signature
             values: (NSArray *)values
{
  DBusMessage *signal = dbus_message_new_signal([path UTF8String],
    [interface UTF8String], [member UTF8String]);

  if (signal == NULL)
    [NSException raise: NSMallocException format: @"dbus signal"];
  KCDBusAppendArguments(signal, signature, values);
  [self send: signal];
}

- (void) dispatchPending
{
  while (dbus_connection_dispatch(_connection) == DBUS_DISPATCH_DATA_REMAINS)
    ;
}

- (void) receivedEvent: (void *)data
                  type: (RunLoopEventType)type
                 extra: (void *)extra
               forMode: (NSString *)mode
{
  if (!dbus_connection_read_write(_connection, 0))
    {
      /* The bus is gone, which only happens when the session ends. */
      NSLog(@"Keychain: the session bus closed the connection");
      exit(EXIT_FAILURE);
    }
  [self dispatchPending];
}

@end
