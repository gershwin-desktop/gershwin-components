/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "KCSecretService.h"
#import "KCDBusMarshal.h"
#import "KCKeyring.h"
#import "KCCollection.h"
#import "KCItem.h"
#import "KCSecretSession.h"

NSString * const KCSecretServiceBusName = @"org.freedesktop.secrets";
NSString * const KCSecretServicePath = @"/org/freedesktop/secrets";

static NSString * const kServiceIface = @"org.freedesktop.Secret.Service";
static NSString * const kCollectionIface = @"org.freedesktop.Secret.Collection";
static NSString * const kItemIface = @"org.freedesktop.Secret.Item";
static NSString * const kSessionIface = @"org.freedesktop.Secret.Session";
static NSString * const kPromptIface = @"org.freedesktop.Secret.Prompt";
static NSString * const kPropertiesIface = @"org.freedesktop.DBus.Properties";
static NSString * const kIntrospectIface = @"org.freedesktop.DBus.Introspectable";

static NSString * const kErrIsLocked = @"org.freedesktop.Secret.Error.IsLocked";
static NSString * const kErrNoSession = @"org.freedesktop.Secret.Error.NoSession";
static NSString * const kErrNoSuchObject = @"org.freedesktop.Secret.Error.NoSuchObject";
static NSString * const kErrNotSupported = @"org.freedesktop.DBus.Error.NotSupported";
static NSString * const kErrInvalidArgs = @"org.freedesktop.DBus.Error.InvalidArgs";
static NSString * const kErrUnknownMethod = @"org.freedesktop.DBus.Error.UnknownMethod";
static NSString * const kErrUnknownObject = @"org.freedesktop.DBus.Error.UnknownObject";
static NSString * const kErrFailed = @"org.freedesktop.DBus.Error.Failed";
static NSString * const kErrPropertyReadOnly = @"org.freedesktop.DBus.Error.PropertyReadOnly";

static NSString * const kLabelProperty = @"org.freedesktop.Secret.Collection.Label";
static NSString * const kItemLabelProperty = @"org.freedesktop.Secret.Item.Label";
static NSString * const kItemAttributesProperty = @"org.freedesktop.Secret.Item.Attributes";

typedef NS_ENUM(NSInteger, KCObjectKind) {
  KCObjectNone,
  KCObjectService,
  KCObjectCollection,
  KCObjectItem,
  KCObjectSession,
  KCObjectPrompt,
  KCObjectNode
};

static KCDBusObjectPath *KCPath(NSString *s)
{
  return [KCDBusObjectPath pathWithString: s];
}

static KCDBusObjectPath *KCNoObject(void)
{
  return KCPath(@"/");
}

static KCDBusVariant *KCVar(NSString *signature, id value)
{
  return [KCDBusVariant variantWithSignature: signature value: value];
}

static NSNumber *KCSeconds(NSDate *date)
{
  return [NSNumber numberWithUnsignedLongLong:
    date != nil ? (unsigned long long)[date timeIntervalSince1970] : 0ULL];
}

/* One pending Prompt object. What it does when the client calls Prompt()
 * is a block, so each operation keeps its own continuation. */
@interface KCPrompt : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *owner;
@property (nonatomic, copy) void (^run)(KCPrompt *prompt);
@property (nonatomic, strong) id request;
@property (nonatomic) BOOL started;
@end

@implementation KCPrompt
@end

/* A parsed object path. */
@interface KCObjectRef : NSObject
@property (nonatomic) KCObjectKind kind;
@property (nonatomic, strong) KCCollection *collection;
@property (nonatomic, copy) NSString *itemIdentifier;
@property (nonatomic, copy) NSString *path;
@end

@implementation KCObjectRef
@end

@implementation KCSecretService
{
  KCKeyring *_keyring;
  KCDBusConnection *_bus;
  id<KCPasswordRequester> _requester;
  NSMutableDictionary *_sessions;
  NSMutableDictionary *_sessionOwners;
  NSMutableDictionary *_prompts;
  unsigned long _nextSession;
  unsigned long _nextPrompt;
}

- (instancetype) initWithKeyring: (KCKeyring *)keyring
                      connection: (KCDBusConnection *)connection
                       requester: (id<KCPasswordRequester>)requester
{
  if ((self = [super init]) != nil)
    {
      _keyring = keyring;
      _bus = connection;
      _requester = requester;
      _sessions = [NSMutableDictionary new];
      _sessionOwners = [NSMutableDictionary new];
      _prompts = [NSMutableDictionary new];
    }
  return self;
}

- (void) dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver: self];
}

- (BOOL) start: (NSError **)error
{
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

  [_bus registerFallbackPath: KCSecretServicePath handler: self];
  [nc addObserver: self selector: @selector(collectionChanged:)
             name: KCCollectionDidChangeNotification object: nil];
  [nc addObserver: self selector: @selector(collectionsChanged:)
             name: KCKeyringDidChangeCollectionsNotification object: _keyring];
  return [_bus requestName: KCSecretServiceBusName error: error];
}

#pragma mark Paths

- (NSString *) pathForCollection: (KCCollection *)c
{
  return [NSString stringWithFormat: @"%@/collection/%@",
    KCSecretServicePath, [c name]];
}

- (NSString *) pathForItem: (NSString *)identifier inCollection: (KCCollection *)c
{
  return [NSString stringWithFormat: @"%@/%@", [self pathForCollection: c], identifier];
}

- (NSArray *) itemPathsOfCollection: (KCCollection *)c
{
  NSMutableArray *paths = [NSMutableArray array];
  NSEnumerator *e = [[c itemIdentifiers] objectEnumerator];
  NSString *identifier;

  while ((identifier = [e nextObject]) != nil)
    [paths addObject: KCPath([self pathForItem: identifier inCollection: c])];
  return paths;
}

- (NSArray *) collectionPaths
{
  NSMutableArray *paths = [NSMutableArray array];
  NSEnumerator *e = [[_keyring collections] objectEnumerator];
  KCCollection *c;

  while ((c = [e nextObject]) != nil)
    [paths addObject: KCPath([self pathForCollection: c])];
  return paths;
}

- (KCObjectRef *) resolve: (NSString *)path
{
  KCObjectRef *ref = [KCObjectRef new];
  NSArray *parts;
  NSUInteger n;

  [ref setPath: path];
  if ([path isEqualToString: KCSecretServicePath])
    {
      [ref setKind: KCObjectService];
      return ref;
    }
  if (![path hasPrefix: [KCSecretServicePath stringByAppendingString: @"/"]])
    return ref;
  parts = [[path substringFromIndex: [KCSecretServicePath length] + 1]
            componentsSeparatedByString: @"/"];
  n = [parts count];

  if (n == 1)
    {
      if ([[parts objectAtIndex: 0] isEqualToString: @"collection"]
        || [[parts objectAtIndex: 0] isEqualToString: @"aliases"])
        [ref setKind: KCObjectNode];
      return ref;
    }
  if (n == 2 && [[parts objectAtIndex: 0] isEqualToString: @"session"])
    {
      if ([_sessions objectForKey: path] != nil)
        [ref setKind: KCObjectSession];
      return ref;
    }
  if (n == 2 && [[parts objectAtIndex: 0] isEqualToString: @"prompt"])
    {
      if ([_prompts objectForKey: path] != nil)
        [ref setKind: KCObjectPrompt];
      return ref;
    }

  KCCollection *c = nil;
  if ([[parts objectAtIndex: 0] isEqualToString: @"collection"])
    c = [_keyring collectionNamed: [parts objectAtIndex: 1]];
  else if ([[parts objectAtIndex: 0] isEqualToString: @"aliases"])
    c = [_keyring collectionForAlias: [parts objectAtIndex: 1]];
  if (c == nil)
    return ref;
  [ref setCollection: c];
  if (n == 2)
    {
      [ref setKind: KCObjectCollection];
      return ref;
    }
  if (n == 3 && [[c itemIdentifiers] containsObject: [parts objectAtIndex: 2]])
    {
      [ref setKind: KCObjectItem];
      [ref setItemIdentifier: [parts objectAtIndex: 2]];
    }
  return ref;
}

#pragma mark Properties

- (NSDictionary *) propertiesOfService
{
  return [NSDictionary dictionaryWithObject: KCVar(@"ao", [self collectionPaths])
                                     forKey: @"Collections"];
}

- (NSDictionary *) propertiesOfCollection: (KCCollection *)c
{
  return [NSDictionary dictionaryWithObjectsAndKeys:
    KCVar(@"ao", [self itemPathsOfCollection: c]), @"Items",
    KCVar(@"s", [c label]), @"Label",
    KCVar(@"b", [NSNumber numberWithBool: [c isLocked]]), @"Locked",
    KCVar(@"t", KCSeconds([c created])), @"Created",
    KCVar(@"t", KCSeconds([c modified])), @"Modified",
    nil];
}

/* A locked item's label and attributes are encrypted; the specification
 * lets them read as empty until the collection is unlocked. */
- (NSDictionary *) propertiesOfItem: (NSString *)identifier inCollection: (KCCollection *)c
{
  KCItem *item = [c itemWithIdentifier: identifier];

  return [NSDictionary dictionaryWithObjectsAndKeys:
    KCVar(@"b", [NSNumber numberWithBool: [c isLocked]]), @"Locked",
    KCVar(@"a{ss}", item != nil ? [item attributes] : [NSDictionary dictionary]),
      @"Attributes",
    KCVar(@"s", item != nil ? [item label] : @""), @"Label",
    KCVar(@"t", KCSeconds([item created])), @"Created",
    KCVar(@"t", KCSeconds([item modified])), @"Modified",
    nil];
}

- (NSString *) interfaceForKind: (KCObjectKind)kind
{
  switch (kind)
    {
      case KCObjectService: return kServiceIface;
      case KCObjectCollection: return kCollectionIface;
      case KCObjectItem: return kItemIface;
      case KCObjectSession: return kSessionIface;
      case KCObjectPrompt: return kPromptIface;
      default: return nil;
    }
}

- (NSDictionary *) propertiesOf: (KCObjectRef *)ref
{
  switch ([ref kind])
    {
      case KCObjectService: return [self propertiesOfService];
      case KCObjectCollection: return [self propertiesOfCollection: [ref collection]];
      case KCObjectItem:
        return [self propertiesOfItem: [ref itemIdentifier]
                         inCollection: [ref collection]];
      default: return [NSDictionary dictionary];
    }
}

#pragma mark Signals

- (void) emitProperties: (NSArray *)names
                     of: (NSDictionary *)all
              interface: (NSString *)interface
                   path: (NSString *)path
{
  NSMutableDictionary *changed = [NSMutableDictionary dictionary];
  NSEnumerator *e = [names objectEnumerator];
  NSString *name;

  while ((name = [e nextObject]) != nil)
    [changed setObject: [all objectForKey: name] forKey: name];
  [_bus emitSignal: @"PropertiesChanged" interface: kPropertiesIface path: path
         signature: @"sa{sv}as"
            values: [NSArray arrayWithObjects: interface, changed, [NSArray array], nil]];
}

- (void) collectionChanged: (NSNotification *)n
{
  KCCollection *c = [n object];
  NSString *kind = [[n userInfo] objectForKey: KCChangeKindKey];
  KCItem *item = [[n userInfo] objectForKey: KCChangedItemKey];
  NSString *cPath = [self pathForCollection: c];

  if ([_keyring collectionNamed: [c name]] != c)
    return;

  if ([kind isEqualToString: KCChangeCollection])
    {
      [_bus emitSignal: @"CollectionChanged" interface: kServiceIface
                  path: KCSecretServicePath signature: @"o"
                values: [NSArray arrayWithObject: KCPath(cPath)]];
      [self emitProperties: [NSArray arrayWithObjects: @"Label", @"Locked",
                              @"Items", @"Modified", nil]
                        of: [self propertiesOfCollection: c]
                 interface: kCollectionIface path: cPath];
      return;
    }

  NSString *iPath = [self pathForItem: [item identifier] inCollection: c];
  NSString *member = kind;
  [_bus emitSignal: member interface: kCollectionIface path: cPath
         signature: @"o" values: [NSArray arrayWithObject: KCPath(iPath)]];
  if (![kind isEqualToString: KCChangeItemChanged])
    [self emitProperties: [NSArray arrayWithObjects: @"Items", @"Modified", nil]
                      of: [self propertiesOfCollection: c]
               interface: kCollectionIface path: cPath];
  else
    [self emitProperties: [NSArray arrayWithObjects: @"Label", @"Attributes",
                            @"Modified", nil]
                      of: [self propertiesOfItem: [item identifier] inCollection: c]
               interface: kItemIface path: iPath];
}

- (void) collectionsChanged: (NSNotification *)n
{
  KCCollection *added = [[n userInfo] objectForKey: KCAddedCollectionKey];
  KCCollection *removed = [[n userInfo] objectForKey: KCRemovedCollectionKey];

  if (added != nil)
    [_bus emitSignal: @"CollectionCreated" interface: kServiceIface
                path: KCSecretServicePath signature: @"o"
              values: [NSArray arrayWithObject: KCPath([self pathForCollection: added])]];
  if (removed != nil)
    [_bus emitSignal: @"CollectionDeleted" interface: kServiceIface
                path: KCSecretServicePath signature: @"o"
              values: [NSArray arrayWithObject: KCPath([self pathForCollection: removed])]];
  if (added != nil || removed != nil)
    [self emitProperties: [NSArray arrayWithObject: @"Collections"]
                      of: [self propertiesOfService]
               interface: kServiceIface path: KCSecretServicePath];
}

#pragma mark Prompts

- (KCPrompt *) newPromptFor: (DBusMessage *)call run: (void (^)(KCPrompt *))run
{
  KCPrompt *p = [KCPrompt new];

  [p setPath: [NSString stringWithFormat: @"%@/prompt/p%lu",
    KCSecretServicePath, ++_nextPrompt]];
  [p setOwner: [NSString stringWithUTF8String: dbus_message_get_sender(call)]];
  [p setRun: run];
  [_prompts setObject: p forKey: [p path]];
  return p;
}

- (void) finishPrompt: (KCPrompt *)p dismissed: (BOOL)dismissed result: (KCDBusVariant *)result
{
  if ([_prompts objectForKey: [p path]] != p)
    return;
  [_prompts removeObjectForKey: [p path]];
  [_bus emitSignal: @"Completed" interface: kPromptIface path: [p path]
         signature: @"bv"
            values: [NSArray arrayWithObjects: [NSNumber numberWithBool: dismissed],
                      result != nil ? result : KCVar(@"s", @""), nil]];
}

- (BOOL) save: (KCCollection *)c
{
  NSError *error = nil;

  if ([_keyring saveCollection: c error: &error])
    return YES;
  NSLog(@"Keychain: saving keyring %@ failed: %@", [c name],
        [error localizedDescription]);
  return NO;
}

/* Unlocks the collections one after the other, each with its own panel,
 * then calls done(YES), or done(NO) as soon as the user cancels one. */
- (void) unlockCollections: (NSMutableArray *)queue
                    prompt: (KCPrompt *)prompt
                      done: (void (^)(BOOL ok))done
{
  KCCollection *c;

  while ([queue count] > 0 && ![[queue objectAtIndex: 0] isLocked])
    [queue removeObjectAtIndex: 0];
  if ([queue count] == 0)
    {
      done(YES);
      return;
    }
  c = [queue objectAtIndex: 0];

  NSString *message = [NSString stringWithFormat:
    @"An application wants to use the keyring \"%@\". "
    @"Enter the keyring password to unlock it.", [c label]];
  __weak KCSecretService *weakSelf = self;
  [prompt setRequest: [_requester requestPasswordWithTitle: @"Unlock Keyring"
    message: message newPassword: NO
    validator: ^NSString *(NSString *password) {
      NSError *error = nil;
      if ([c unlockWithPassword: password error: &error])
        return nil;
      return [error localizedDescription];
    }
    completion: ^(BOOL accepted) {
      [prompt setRequest: nil];
      if (!accepted)
        {
          done(NO);
          return;
        }
      [queue removeObjectAtIndex: 0];
      [weakSelf unlockCollections: queue prompt: prompt done: done];
    }]];
}

#pragma mark Dispatch

- (void) connection: (KCDBusConnection *)connection
      handleMessage: (DBusMessage *)call
{
  NSString *path = [NSString stringWithUTF8String: dbus_message_get_path(call)];
  const char *ifaceC = dbus_message_get_interface(call);
  NSString *iface = ifaceC != NULL ? [NSString stringWithUTF8String: ifaceC] : nil;
  NSString *member = [NSString stringWithUTF8String: dbus_message_get_member(call)];
  KCObjectRef *ref = [self resolve: path];
  NSString *objectIface = [self interfaceForKind: [ref kind]];
  NSArray *args;
  SEL sel;

  if ([ref kind] == KCObjectNone)
    {
      [_bus replyTo: call errorName: kErrUnknownObject
            message: [NSString stringWithFormat: @"No such object %@", path]];
      return;
    }

  if (iface == nil)
    iface = [member isEqualToString: @"Introspect"] ? kIntrospectIface
      : ([@[@"Get", @"GetAll", @"Set"] containsObject: member]
         ? kPropertiesIface : objectIface);

  if ([iface isEqualToString: kIntrospectIface] && [member isEqualToString: @"Introspect"])
    {
      [_bus replyTo: call signature: @"s"
             values: [NSArray arrayWithObject: [self introspect: ref]]];
      return;
    }

  if ([iface isEqualToString: kPropertiesIface])
    sel = NSSelectorFromString([NSString stringWithFormat: @"properties%@:ref:args:", member]);
  else if (objectIface != nil && [iface isEqualToString: objectIface])
    sel = NSSelectorFromString([NSString stringWithFormat: @"%@%@:ref:args:",
      [[iface pathExtension] lowercaseString], member]);
  else
    sel = NULL;

  if (sel == NULL || ![self respondsToSelector: sel])
    {
      [_bus replyTo: call errorName: kErrUnknownMethod
            message: [NSString stringWithFormat: @"%@.%@ is not supported on %@",
                       iface, member, path]];
      return;
    }

  args = KCDBusReadArguments(call);
  void (*imp)(id, SEL, DBusMessage *, KCObjectRef *, NSArray *)
    = (void (*)(id, SEL, DBusMessage *, KCObjectRef *, NSArray *))[self methodForSelector: sel];
  imp(self, sel, call, ref, args);
}

- (void) connection: (KCDBusConnection *)connection
    clientDidVanish: (NSString *)uniqueName
{
  NSEnumerator *e = [[_sessionOwners allKeysForObject: uniqueName] objectEnumerator];
  NSString *path;
  NSArray *prompts = [[_prompts allValues] copy];
  KCPrompt *p;

  while ((path = [e nextObject]) != nil)
    {
      [_sessions removeObjectForKey: path];
      [_sessionOwners removeObjectForKey: path];
    }
  e = [prompts objectEnumerator];
  while ((p = [e nextObject]) != nil)
    {
      if ([[p owner] isEqualToString: uniqueName])
        {
          if ([p request] != nil)
            [_requester cancelPasswordRequest: [p request]];
          [_prompts removeObjectForKey: [p path]];
        }
    }
}

- (BOOL) call: (DBusMessage *)call hasSignature: (const char *)signature
{
  if (dbus_message_has_signature(call, signature))
    return YES;
  [_bus replyTo: call errorName: kErrInvalidArgs
        message: [NSString stringWithFormat: @"Expected arguments (%s), got (%s)",
                   signature, dbus_message_get_signature(call)]];
  return NO;
}

- (void) replyFailed: (DBusMessage *)call
{
  [_bus replyTo: call errorName: kErrFailed
        message: @"The keyring could not be written to disk"];
}

#pragma mark org.freedesktop.DBus.Properties

- (void) propertiesGet: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  KCDBusVariant *value;

  if (![self call: call hasSignature: "ss"])
    return;
  value = [[self propertiesOf: ref] objectForKey: [args objectAtIndex: 1]];
  if (value == nil || ![[args objectAtIndex: 0] isEqual: [self interfaceForKind: [ref kind]]])
    {
      [_bus replyTo: call errorName: kErrInvalidArgs
            message: [NSString stringWithFormat: @"No property %@.%@",
                       [args objectAtIndex: 0], [args objectAtIndex: 1]]];
      return;
    }
  [_bus replyTo: call signature: @"v" values: [NSArray arrayWithObject: value]];
}

- (void) propertiesGetAll: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  NSDictionary *props;

  if (![self call: call hasSignature: "s"])
    return;
  props = [[args objectAtIndex: 0] isEqual: [self interfaceForKind: [ref kind]]]
    ? [self propertiesOf: ref] : [NSDictionary dictionary];
  [_bus replyTo: call signature: @"a{sv}" values: [NSArray arrayWithObject: props]];
}

- (void) propertiesSet: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  NSString *name;
  KCDBusVariant *value;
  KCCollection *c = [ref collection];

  if (![self call: call hasSignature: "ssv"])
    return;
  name = [args objectAtIndex: 1];
  value = [args objectAtIndex: 2];

  if (c != nil && [c isLocked])
    {
      [_bus replyTo: call errorName: kErrIsLocked message: @"The keyring is locked"];
      return;
    }
  if ([ref kind] == KCObjectCollection && [name isEqual: @"Label"]
    && [[value signature] isEqual: @"s"])
    [c setLabel: [value value]];
  else if ([ref kind] == KCObjectItem && [name isEqual: @"Label"]
    && [[value signature] isEqual: @"s"])
    {
      KCItem *item = [c itemWithIdentifier: [ref itemIdentifier]];
      [item setLabel: [value value]];
      [c itemDidChange: item];
    }
  else if ([ref kind] == KCObjectItem && [name isEqual: @"Attributes"]
    && [[value signature] isEqual: @"a{ss}"])
    {
      KCItem *item = [c itemWithIdentifier: [ref itemIdentifier]];
      [item setAttributes: [value value]];
      [c itemDidChange: item];
    }
  else
    {
      [_bus replyTo: call errorName: kErrPropertyReadOnly
            message: [NSString stringWithFormat: @"%@ cannot be set", name]];
      return;
    }
  if (![self save: c])
    {
      [self replyFailed: call];
      return;
    }
  [_bus replyTo: call signature: @"" values: [NSArray array]];
}

#pragma mark org.freedesktop.Secret.Service

- (void) serviceOpenSession: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  NSString *algorithm;
  KCDBusVariant *input;
  NSData *inputData;
  NSString *path;
  KCSecretSession *session;
  NSString *outputSignature;
  id output;

  if (![self call: call hasSignature: "sv"])
    return;
  algorithm = [args objectAtIndex: 0];
  input = [args objectAtIndex: 1];
  inputData = [[input value] isKindOfClass: [NSData class]] ? [input value] : [NSData data];
  path = [NSString stringWithFormat: @"%@/session/s%lu", KCSecretServicePath, ++_nextSession];

  session = [KCSecretSession sessionWithAlgorithm: algorithm input: inputData path: path];
  if (session == nil)
    {
      BOOL known = [algorithm isEqual: KCAlgorithmDH];
      [_bus replyTo: call errorName: known ? kErrInvalidArgs : kErrNotSupported
            message: known ? @"Invalid public key"
                           : [NSString stringWithFormat: @"Algorithm %@ is not supported",
                               algorithm]];
      return;
    }
  [_sessions setObject: session forKey: path];
  [_sessionOwners setObject: [NSString stringWithUTF8String: dbus_message_get_sender(call)]
                     forKey: path];

  if ([algorithm isEqual: KCAlgorithmPlain])
    {
      outputSignature = @"s";
      output = @"";
    }
  else
    {
      outputSignature = @"ay";
      output = [session output];
    }
  [_bus replyTo: call signature: @"vo"
         values: [NSArray arrayWithObjects: KCVar(outputSignature, output),
                   KCPath(path), nil]];
}

- (void) serviceCreateCollection: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  NSDictionary *props;
  NSString *alias;
  NSString *label;
  KCCollection *existing;
  KCPrompt *prompt;
  __weak KCSecretService *weakSelf = self;

  if (![self call: call hasSignature: "a{sv}s"])
    return;
  props = [args objectAtIndex: 0];
  alias = [args objectAtIndex: 1];
  label = [[props objectForKey: kLabelProperty] value];
  if (![label isKindOfClass: [NSString class]] || [label length] == 0)
    label = @"Login";

  existing = [alias length] > 0 ? [_keyring collectionForAlias: alias] : nil;
  if (existing != nil)
    {
      [_bus replyTo: call signature: @"oo"
             values: [NSArray arrayWithObjects:
                       KCPath([self pathForCollection: existing]), KCNoObject(), nil]];
      return;
    }

  prompt = [self newPromptFor: call run: ^(KCPrompt *p) {
    KCSecretService *me = weakSelf;
    __block KCCollection *created = nil;
    NSString *message = [NSString stringWithFormat:
      @"An application wants to create a new keyring called \"%@\". "
      @"Choose a password for it.", label];

    [p setRequest: [me->_requester requestPasswordWithTitle: @"New Keyring"
      message: message newPassword: YES
      validator: ^NSString *(NSString *password) {
        NSError *error = nil;
        created = [me->_keyring createCollectionWithLabel: label
                                                 password: password error: &error];
        if (created == nil)
          return [error localizedDescription];
        if ([alias length] > 0
          && ![me->_keyring setAlias: alias forCollection: created error: &error])
          return [error localizedDescription];
        return nil;
      }
      completion: ^(BOOL accepted) {
        [p setRequest: nil];
        if (!accepted)
          [me finishPrompt: p dismissed: YES result: nil];
        else
          [me finishPrompt: p dismissed: NO
                    result: KCVar(@"o", KCPath([me pathForCollection: created]))];
      }]];
  }];

  [_bus replyTo: call signature: @"oo"
         values: [NSArray arrayWithObjects: KCNoObject(), KCPath([prompt path]), nil]];
}

- (NSArray *) searchCollection: (KCCollection *)c attributes: (NSDictionary *)query
{
  NSMutableArray *paths = [NSMutableArray array];
  NSEnumerator *e = [[c itemIdentifiersMatchingAttributes: query] objectEnumerator];
  NSString *identifier;

  while ((identifier = [e nextObject]) != nil)
    [paths addObject: KCPath([self pathForItem: identifier inCollection: c])];
  return paths;
}

- (void) serviceSearchItems: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  NSMutableArray *unlocked = [NSMutableArray array];
  NSMutableArray *locked = [NSMutableArray array];
  NSEnumerator *e = [[_keyring collections] objectEnumerator];
  KCCollection *c;

  if (![self call: call hasSignature: "a{ss}"])
    return;
  while ((c = [e nextObject]) != nil)
    [[c isLocked] ? locked : unlocked addObjectsFromArray:
      [self searchCollection: c attributes: [args objectAtIndex: 0]]];
  [_bus replyTo: call signature: @"aoao"
         values: [NSArray arrayWithObjects: unlocked, locked, nil]];
}

/* Collections the given collection or item paths belong to, in order,
 * without duplicates; unknown paths are ignored as the specification's
 * reference implementation does. */
- (NSArray *) collectionsForPaths: (NSArray *)paths
{
  NSMutableArray *result = [NSMutableArray array];
  NSEnumerator *e = [paths objectEnumerator];
  KCDBusObjectPath *p;

  while ((p = [e nextObject]) != nil)
    {
      KCCollection *c = [[self resolve: [p string]] collection];
      if (c != nil && [result indexOfObjectIdenticalTo: c] == NSNotFound)
        [result addObject: c];
    }
  return result;
}

- (NSArray *) paths: (NSArray *)paths inLockState: (BOOL)locked
{
  NSMutableArray *result = [NSMutableArray array];
  NSEnumerator *e = [paths objectEnumerator];
  KCDBusObjectPath *p;

  while ((p = [e nextObject]) != nil)
    {
      KCCollection *c = [[self resolve: [p string]] collection];
      if (c != nil && [c isLocked] == locked)
        [result addObject: p];
    }
  return result;
}

- (void) serviceUnlock: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  NSArray *objects;
  NSMutableArray *pending = [NSMutableArray array];
  NSEnumerator *e;
  KCCollection *c;
  KCPrompt *prompt;
  __weak KCSecretService *weakSelf = self;

  if (![self call: call hasSignature: "ao"])
    return;
  objects = [args objectAtIndex: 0];
  e = [[self collectionsForPaths: objects] objectEnumerator];
  while ((c = [e nextObject]) != nil)
    if ([c isLocked])
      [pending addObject: c];

  if ([pending count] == 0)
    {
      [_bus replyTo: call signature: @"aoo"
             values: [NSArray arrayWithObjects: [self paths: objects inLockState: NO],
                       KCNoObject(), nil]];
      return;
    }

  prompt = [self newPromptFor: call run: ^(KCPrompt *p) {
    [weakSelf unlockCollections: pending prompt: p done: ^(BOOL ok) {
      KCSecretService *me = weakSelf;
      if (ok)
        [me finishPrompt: p dismissed: NO
                  result: KCVar(@"ao", [me paths: objects inLockState: NO])];
      else
        [me finishPrompt: p dismissed: YES result: KCVar(@"ao", [NSArray array])];
    }];
  }];
  [_bus replyTo: call signature: @"aoo"
         values: [NSArray arrayWithObjects: [self paths: objects inLockState: NO],
                   KCPath([prompt path]), nil]];
}

- (void) serviceLock: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  NSArray *objects;
  NSEnumerator *e;
  KCCollection *c;

  if (![self call: call hasSignature: "ao"])
    return;
  objects = [args objectAtIndex: 0];
  e = [[self collectionsForPaths: objects] objectEnumerator];
  while ((c = [e nextObject]) != nil)
    [c lock];
  [_bus replyTo: call signature: @"aoo"
         values: [NSArray arrayWithObjects: [self paths: objects inLockState: YES],
                   KCNoObject(), nil]];
}

- (KCSecretSession *) sessionForPath: (NSString *)path call: (DBusMessage *)call
{
  KCSecretSession *session = [_sessions objectForKey: path];
  NSString *sender = [NSString stringWithUTF8String: dbus_message_get_sender(call)];

  /* Only the client that opened a session may use it: its key belongs to
   * that client alone. */
  if (session == nil || ![[_sessionOwners objectForKey: path] isEqual: sender])
    {
      [_bus replyTo: call errorName: kErrNoSession
            message: [NSString stringWithFormat: @"No session %@", path]];
      return nil;
    }
  return session;
}

- (NSArray *) secretStructFor: (KCItem *)item session: (KCSecretSession *)session
{
  KCSecret *s = [session encodePlaintext: [item secret] contentType: [item contentType]];
  return [NSArray arrayWithObjects: KCPath([s sessionPath]), [s parameters],
    [s value], [s contentType], nil];
}

- (void) serviceGetSecrets: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  NSMutableDictionary *result = [NSMutableDictionary dictionary];
  KCSecretSession *session;
  NSEnumerator *e;
  KCDBusObjectPath *p;

  if (![self call: call hasSignature: "aoo"])
    return;
  session = [self sessionForPath: [[args objectAtIndex: 1] string] call: call];
  if (session == nil)
    return;
  e = [[args objectAtIndex: 0] objectEnumerator];
  while ((p = [e nextObject]) != nil)
    {
      KCObjectRef *item = [self resolve: [p string]];
      KCItem *it;

      if ([item kind] != KCObjectItem || [[item collection] isLocked])
        continue;
      it = [[item collection] itemWithIdentifier: [item itemIdentifier]];
      [result setObject: [self secretStructFor: it session: session] forKey: p];
    }
  [_bus replyTo: call signature: @"a{o(oayays)}" values: [NSArray arrayWithObject: result]];
}

- (void) serviceReadAlias: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  KCCollection *c;

  if (![self call: call hasSignature: "s"])
    return;
  c = [_keyring collectionForAlias: [args objectAtIndex: 0]];
  [_bus replyTo: call signature: @"o" values: [NSArray arrayWithObject:
    c != nil ? KCPath([self pathForCollection: c]) : KCNoObject()]];
}

- (void) serviceSetAlias: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  NSString *target;
  KCCollection *c = nil;
  NSError *error = nil;

  if (![self call: call hasSignature: "so"])
    return;
  target = [[args objectAtIndex: 1] string];
  if (![target isEqualToString: @"/"])
    {
      KCObjectRef *r = [self resolve: target];
      if ([r kind] != KCObjectCollection)
        {
          [_bus replyTo: call errorName: kErrNoSuchObject
                message: [NSString stringWithFormat: @"No collection %@", target]];
          return;
        }
      c = [r collection];
    }
  if (![_keyring setAlias: [args objectAtIndex: 0] forCollection: c error: &error])
    {
      [self replyFailed: call];
      return;
    }
  [_bus replyTo: call signature: @"" values: [NSArray array]];
}

#pragma mark org.freedesktop.Secret.Collection

- (void) collectionSearchItems: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  if (![self call: call hasSignature: "a{ss}"])
    return;
  [_bus replyTo: call signature: @"ao" values: [NSArray arrayWithObject:
    [self searchCollection: [ref collection] attributes: [args objectAtIndex: 0]]]];
}

- (void) collectionDelete: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  NSError *error = nil;

  if (![self call: call hasSignature: ""])
    return;
  if (![_keyring deleteCollection: [ref collection] error: &error])
    {
      [self replyFailed: call];
      return;
    }
  [_bus replyTo: call signature: @"o" values: [NSArray arrayWithObject: KCNoObject()]];
}

- (KCItem *) createItemIn: (KCCollection *)c
               properties: (NSDictionary *)props
                   secret: (NSData *)plain
              contentType: (NSString *)type
                  replace: (BOOL)replace
{
  NSString *label = [[props objectForKey: kItemLabelProperty] value];
  NSDictionary *attributes = [[props objectForKey: kItemAttributesProperty] value];

  if (![label isKindOfClass: [NSString class]])
    label = @"";
  if (![attributes isKindOfClass: [NSDictionary class]])
    attributes = [NSDictionary dictionary];
  return [c createItemWithLabel: label attributes: attributes secret: plain
                    contentType: type replace: replace];
}

- (void) collectionCreateItem: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  NSDictionary *props;
  NSArray *secretStruct;
  BOOL replace;
  KCSecretSession *session;
  KCSecret *secret;
  NSData *plain;
  KCCollection *c = [ref collection];
  KCPrompt *prompt;
  __weak KCSecretService *weakSelf = self;

  if (![self call: call hasSignature: "a{sv}(oayays)b"])
    return;
  props = [args objectAtIndex: 0];
  secretStruct = [args objectAtIndex: 1];
  replace = [[args objectAtIndex: 2] boolValue];

  session = [self sessionForPath: [[secretStruct objectAtIndex: 0] string] call: call];
  if (session == nil)
    return;
  secret = [KCSecret secretWithSessionPath: [[secretStruct objectAtIndex: 0] string]
    parameters: [secretStruct objectAtIndex: 1] value: [secretStruct objectAtIndex: 2]
    contentType: [secretStruct objectAtIndex: 3]];
  plain = [session decodeSecret: secret];
  if (plain == nil)
    {
      [_bus replyTo: call errorName: kErrInvalidArgs
            message: @"The secret could not be decrypted with this session"];
      return;
    }

  if (![c isLocked])
    {
      KCItem *item = [self createItemIn: c properties: props secret: plain
                            contentType: [secret contentType] replace: replace];
      if (![self save: c])
        {
          [self replyFailed: call];
          return;
        }
      [_bus replyTo: call signature: @"oo" values: [NSArray arrayWithObjects:
        KCPath([self pathForItem: [item identifier] inCollection: c]), KCNoObject(), nil]];
      return;
    }

  /* A locked keyring first needs the user's password; the item is created
   * when the prompt completes, as the specification describes. */
  prompt = [self newPromptFor: call run: ^(KCPrompt *p) {
    [weakSelf unlockCollections: [NSMutableArray arrayWithObject: c] prompt: p
                           done: ^(BOOL ok) {
      KCSecretService *me = weakSelf;
      KCItem *item;

      if (!ok)
        {
          [me finishPrompt: p dismissed: YES result: nil];
          return;
        }
      item = [me createItemIn: c properties: props secret: plain
                  contentType: [secret contentType] replace: replace];
      if (![me save: c])
        {
          [me finishPrompt: p dismissed: YES result: nil];
          return;
        }
      [me finishPrompt: p dismissed: NO result: KCVar(@"o",
        KCPath([me pathForItem: [item identifier] inCollection: c]))];
    }];
  }];
  [_bus replyTo: call signature: @"oo"
         values: [NSArray arrayWithObjects: KCNoObject(), KCPath([prompt path]), nil]];
}

#pragma mark org.freedesktop.Secret.Item

- (KCItem *) unlockedItem: (KCObjectRef *)ref call: (DBusMessage *)call
{
  if ([[ref collection] isLocked])
    {
      [_bus replyTo: call errorName: kErrIsLocked message: @"The keyring is locked"];
      return nil;
    }
  return [[ref collection] itemWithIdentifier: [ref itemIdentifier]];
}

- (void) itemGetSecret: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  KCSecretSession *session;
  KCItem *item;

  if (![self call: call hasSignature: "o"])
    return;
  item = [self unlockedItem: ref call: call];
  if (item == nil)
    return;
  session = [self sessionForPath: [[args objectAtIndex: 0] string] call: call];
  if (session == nil)
    return;
  [_bus replyTo: call signature: @"(oayays)"
         values: [NSArray arrayWithObject: [self secretStructFor: item session: session]]];
}

- (void) itemSetSecret: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  NSArray *st;
  KCSecretSession *session;
  KCSecret *secret;
  NSData *plain;
  KCItem *item;

  if (![self call: call hasSignature: "(oayays)"])
    return;
  item = [self unlockedItem: ref call: call];
  if (item == nil)
    return;
  st = [args objectAtIndex: 0];
  session = [self sessionForPath: [[st objectAtIndex: 0] string] call: call];
  if (session == nil)
    return;
  secret = [KCSecret secretWithSessionPath: [[st objectAtIndex: 0] string]
    parameters: [st objectAtIndex: 1] value: [st objectAtIndex: 2]
    contentType: [st objectAtIndex: 3]];
  plain = [session decodeSecret: secret];
  if (plain == nil)
    {
      [_bus replyTo: call errorName: kErrInvalidArgs
            message: @"The secret could not be decrypted with this session"];
      return;
    }
  [item setSecret: plain];
  [item setContentType: [secret contentType]];
  [[ref collection] itemDidChange: item];
  if (![self save: [ref collection]])
    {
      [self replyFailed: call];
      return;
    }
  [_bus replyTo: call signature: @"" values: [NSArray array]];
}

- (void) itemDelete: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  KCItem *item;

  if (![self call: call hasSignature: ""])
    return;
  item = [self unlockedItem: ref call: call];
  if (item == nil)
    return;
  [[ref collection] deleteItem: item];
  if (![self save: [ref collection]])
    {
      [self replyFailed: call];
      return;
    }
  [_bus replyTo: call signature: @"o" values: [NSArray arrayWithObject: KCNoObject()]];
}

#pragma mark org.freedesktop.Secret.Session and Prompt

- (void) sessionClose: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  [_sessions removeObjectForKey: [ref path]];
  [_sessionOwners removeObjectForKey: [ref path]];
  [_bus replyTo: call signature: @"" values: [NSArray array]];
}

- (void) promptPrompt: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  KCPrompt *p = [_prompts objectForKey: [ref path]];

  if (![self call: call hasSignature: "s"])
    return;
  /* Reply first: the client waits for Completed, not for this call. */
  [_bus replyTo: call signature: @"" values: [NSArray array]];
  if (![p started])
    {
      [p setStarted: YES];
      [p run](p);
    }
}

- (void) promptDismiss: (DBusMessage *)call ref: (KCObjectRef *)ref args: (NSArray *)args
{
  KCPrompt *p = [_prompts objectForKey: [ref path]];

  [_bus replyTo: call signature: @"" values: [NSArray array]];
  if ([p request] != nil)
    [_requester cancelPasswordRequest: [p request]];
  [self finishPrompt: p dismissed: YES result: nil];
}

#pragma mark Introspection

- (NSString *) introspect: (KCObjectRef *)ref
{
  static NSString *properties =
    @"<interface name=\"org.freedesktop.DBus.Properties\">"
    "<method name=\"Get\"><arg name=\"interface\" type=\"s\" direction=\"in\"/>"
    "<arg name=\"name\" type=\"s\" direction=\"in\"/>"
    "<arg name=\"value\" type=\"v\" direction=\"out\"/></method>"
    "<method name=\"GetAll\"><arg name=\"interface\" type=\"s\" direction=\"in\"/>"
    "<arg name=\"properties\" type=\"a{sv}\" direction=\"out\"/></method>"
    "<method name=\"Set\"><arg name=\"interface\" type=\"s\" direction=\"in\"/>"
    "<arg name=\"name\" type=\"s\" direction=\"in\"/>"
    "<arg name=\"value\" type=\"v\" direction=\"in\"/></method>"
    "<signal name=\"PropertiesChanged\"><arg name=\"interface\" type=\"s\"/>"
    "<arg name=\"changed\" type=\"a{sv}\"/><arg name=\"invalidated\" type=\"as\"/></signal>"
    "</interface>"
    "<interface name=\"org.freedesktop.DBus.Introspectable\">"
    "<method name=\"Introspect\"><arg name=\"xml\" type=\"s\" direction=\"out\"/></method>"
    "</interface>";
  NSMutableString *xml = [NSMutableString stringWithString:
    @"<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\" "
    "\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n<node>"];
  NSEnumerator *e;
  id child;

  switch ([ref kind])
    {
      case KCObjectService:
        [xml appendString:
          @"<interface name=\"org.freedesktop.Secret.Service\">"
          "<method name=\"OpenSession\"><arg name=\"algorithm\" type=\"s\" direction=\"in\"/>"
          "<arg name=\"input\" type=\"v\" direction=\"in\"/>"
          "<arg name=\"output\" type=\"v\" direction=\"out\"/>"
          "<arg name=\"result\" type=\"o\" direction=\"out\"/></method>"
          "<method name=\"CreateCollection\"><arg name=\"properties\" type=\"a{sv}\" direction=\"in\"/>"
          "<arg name=\"alias\" type=\"s\" direction=\"in\"/>"
          "<arg name=\"collection\" type=\"o\" direction=\"out\"/>"
          "<arg name=\"prompt\" type=\"o\" direction=\"out\"/></method>"
          "<method name=\"SearchItems\"><arg name=\"attributes\" type=\"a{ss}\" direction=\"in\"/>"
          "<arg name=\"unlocked\" type=\"ao\" direction=\"out\"/>"
          "<arg name=\"locked\" type=\"ao\" direction=\"out\"/></method>"
          "<method name=\"Unlock\"><arg name=\"objects\" type=\"ao\" direction=\"in\"/>"
          "<arg name=\"unlocked\" type=\"ao\" direction=\"out\"/>"
          "<arg name=\"prompt\" type=\"o\" direction=\"out\"/></method>"
          "<method name=\"Lock\"><arg name=\"objects\" type=\"ao\" direction=\"in\"/>"
          "<arg name=\"locked\" type=\"ao\" direction=\"out\"/>"
          "<arg name=\"Prompt\" type=\"o\" direction=\"out\"/></method>"
          "<method name=\"GetSecrets\"><arg name=\"items\" type=\"ao\" direction=\"in\"/>"
          "<arg name=\"session\" type=\"o\" direction=\"in\"/>"
          "<arg name=\"secrets\" type=\"a{o(oayays)}\" direction=\"out\"/></method>"
          "<method name=\"ReadAlias\"><arg name=\"name\" type=\"s\" direction=\"in\"/>"
          "<arg name=\"collection\" type=\"o\" direction=\"out\"/></method>"
          "<method name=\"SetAlias\"><arg name=\"name\" type=\"s\" direction=\"in\"/>"
          "<arg name=\"collection\" type=\"o\" direction=\"in\"/></method>"
          "<signal name=\"CollectionCreated\"><arg name=\"collection\" type=\"o\"/></signal>"
          "<signal name=\"CollectionDeleted\"><arg name=\"collection\" type=\"o\"/></signal>"
          "<signal name=\"CollectionChanged\"><arg name=\"collection\" type=\"o\"/></signal>"
          "<property name=\"Collections\" type=\"ao\" access=\"read\"/>"
          "</interface>"];
        [xml appendString: properties];
        [xml appendString: @"<node name=\"collection\"/><node name=\"aliases\"/>"];
        break;
      case KCObjectCollection:
        [xml appendString:
          @"<interface name=\"org.freedesktop.Secret.Collection\">"
          "<method name=\"Delete\"><arg name=\"prompt\" type=\"o\" direction=\"out\"/></method>"
          "<method name=\"SearchItems\"><arg name=\"attributes\" type=\"a{ss}\" direction=\"in\"/>"
          "<arg name=\"results\" type=\"ao\" direction=\"out\"/></method>"
          "<method name=\"CreateItem\"><arg name=\"properties\" type=\"a{sv}\" direction=\"in\"/>"
          "<arg name=\"secret\" type=\"(oayays)\" direction=\"in\"/>"
          "<arg name=\"replace\" type=\"b\" direction=\"in\"/>"
          "<arg name=\"item\" type=\"o\" direction=\"out\"/>"
          "<arg name=\"prompt\" type=\"o\" direction=\"out\"/></method>"
          "<signal name=\"ItemCreated\"><arg name=\"item\" type=\"o\"/></signal>"
          "<signal name=\"ItemDeleted\"><arg name=\"item\" type=\"o\"/></signal>"
          "<signal name=\"ItemChanged\"><arg name=\"item\" type=\"o\"/></signal>"
          "<property name=\"Items\" type=\"ao\" access=\"read\"/>"
          "<property name=\"Label\" type=\"s\" access=\"readwrite\"/>"
          "<property name=\"Locked\" type=\"b\" access=\"read\"/>"
          "<property name=\"Created\" type=\"t\" access=\"read\"/>"
          "<property name=\"Modified\" type=\"t\" access=\"read\"/>"
          "</interface>"];
        [xml appendString: properties];
        e = [[[ref collection] itemIdentifiers] objectEnumerator];
        while ((child = [e nextObject]) != nil)
          [xml appendFormat: @"<node name=\"%@\"/>", child];
        break;
      case KCObjectItem:
        [xml appendString:
          @"<interface name=\"org.freedesktop.Secret.Item\">"
          "<method name=\"Delete\"><arg name=\"Prompt\" type=\"o\" direction=\"out\"/></method>"
          "<method name=\"GetSecret\"><arg name=\"session\" type=\"o\" direction=\"in\"/>"
          "<arg name=\"secret\" type=\"(oayays)\" direction=\"out\"/></method>"
          "<method name=\"SetSecret\"><arg name=\"secret\" type=\"(oayays)\" direction=\"in\"/></method>"
          "<property name=\"Locked\" type=\"b\" access=\"read\"/>"
          "<property name=\"Attributes\" type=\"a{ss}\" access=\"readwrite\"/>"
          "<property name=\"Label\" type=\"s\" access=\"readwrite\"/>"
          "<property name=\"Created\" type=\"t\" access=\"read\"/>"
          "<property name=\"Modified\" type=\"t\" access=\"read\"/>"
          "</interface>"];
        [xml appendString: properties];
        break;
      case KCObjectSession:
        [xml appendString: @"<interface name=\"org.freedesktop.Secret.Session\">"
          "<method name=\"Close\"/></interface>"];
        [xml appendString: properties];
        break;
      case KCObjectPrompt:
        [xml appendString: @"<interface name=\"org.freedesktop.Secret.Prompt\">"
          "<method name=\"Prompt\"><arg name=\"window-id\" type=\"s\" direction=\"in\"/></method>"
          "<method name=\"Dismiss\"/>"
          "<signal name=\"Completed\"><arg name=\"dismissed\" type=\"b\"/>"
          "<arg name=\"result\" type=\"v\"/></signal></interface>"];
        [xml appendString: properties];
        break;
      default:
        if ([[ref path] hasSuffix: @"/collection"])
          {
            e = [[_keyring collections] objectEnumerator];
            while ((child = [e nextObject]) != nil)
              [xml appendFormat: @"<node name=\"%@\"/>", [child name]];
          }
        break;
    }
  [xml appendString: @"</node>\n"];
  return xml;
}

@end
