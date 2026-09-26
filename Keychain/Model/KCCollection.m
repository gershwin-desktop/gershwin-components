/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "KCCollection.h"
#import "KCItem.h"
#import "KCCrypto.h"

NSString * const KCKeyringErrorDomain = @"io.github.gershwin-desktop.Keychain";
NSString * const KCCollectionDidChangeNotification = @"KCCollectionDidChangeNotification";
NSString * const KCChangeKindKey = @"KCChangeKind";
NSString * const KCChangedItemKey = @"KCChangedItem";
NSString * const KCChangeItemCreated = @"ItemCreated";
NSString * const KCChangeItemDeleted = @"ItemDeleted";
NSString * const KCChangeItemChanged = @"ItemChanged";
NSString * const KCChangeCollection = @"CollectionChanged";

const unsigned KCDefaultKDFIterations = 600000;

static NSString * const KCFileFormat = @"io.github.gershwin-desktop.keyring";
static const unsigned KCFileVersion = 1;
static NSString * const KCKDFName = @"PBKDF2-HMAC-SHA256";
static NSString * const KCCipherName = @"AES-256-GCM";

static NSError *KCError(KCKeyringError code, NSString *message)
{
  return [NSError errorWithDomain: KCKeyringErrorDomain code: code
    userInfo: [NSDictionary dictionaryWithObject: message
                                          forKey: NSLocalizedDescriptionKey]];
}

@implementation KCCollection
{
  NSMutableArray *_items;
  NSData *_key;
  NSData *_salt;
  unsigned _iterations;
  /* What was last read or written: needed to unlock, and to verify a
   * password, without the plaintext. */
  NSDictionary *_envelope;
  NSDictionary *_index;
}

@synthesize name = _name;
@synthesize label = _label;
@synthesize created = _created;
@synthesize modified = _modified;
@synthesize locked = _locked;
@synthesize kdfIterations = _kdfIterations;

- (instancetype) initWithName: (NSString *)name
                        label: (NSString *)label
                     password: (NSString *)password
{
  if ((self = [super init]) != nil)
    {
      _name = [name copy];
      _label = [label copy];
      _created = [NSDate date];
      _modified = _created;
      _items = [NSMutableArray new];
      _index = [NSDictionary dictionary];
      _kdfIterations = KCDefaultKDFIterations;
      [self changePassword: password];
    }
  return self;
}

+ (instancetype) collectionWithName: (NSString *)name
                           fileData: (NSData *)data
                              error: (NSError **)error
{
  NSDictionary *plist = nil;
  KCCollection *c;

  @try
    {
      plist = [NSPropertyListSerialization propertyListWithData: data
        options: NSPropertyListImmutable format: NULL error: NULL];
    }
  @catch (NSException *e)
    {
      plist = nil;
    }
  if (![plist isKindOfClass: [NSDictionary class]])
    {
      if (error != NULL)
        *error = KCError(KCKeyringErrorCorruptFile,
          [NSString stringWithFormat: @"Keyring \"%@\" is not readable.", name]);
      return nil;
    }
  if (![[plist objectForKey: @"Format"] isEqual: KCFileFormat]
    || [[plist objectForKey: @"Version"] unsignedIntValue] != KCFileVersion
    || ![[plist objectForKey: @"KDF"] isEqual: KCKDFName]
    || ![[plist objectForKey: @"Cipher"] isEqual: KCCipherName])
    {
      if (error != NULL)
        *error = KCError(KCKeyringErrorUnsupportedFormat,
          [NSString stringWithFormat:
            @"Keyring \"%@\" has a format this version cannot read.", name]);
      return nil;
    }
  if (![[plist objectForKey: @"Salt"] isKindOfClass: [NSData class]]
    || ![[plist objectForKey: @"Nonce"] isKindOfClass: [NSData class]]
    || ![[plist objectForKey: @"Tag"] isKindOfClass: [NSData class]]
    || ![[plist objectForKey: @"Ciphertext"] isKindOfClass: [NSData class]]
    || ![[plist objectForKey: @"Index"] isKindOfClass: [NSDictionary class]]
    || ![[plist objectForKey: @"Label"] isKindOfClass: [NSString class]]
    || ![[plist objectForKey: @"Created"] isKindOfClass: [NSDate class]]
    || ![[plist objectForKey: @"Modified"] isKindOfClass: [NSDate class]]
    || [[plist objectForKey: @"Iterations"] unsignedIntValue] == 0)
    {
      if (error != NULL)
        *error = KCError(KCKeyringErrorCorruptFile,
          [NSString stringWithFormat: @"Keyring \"%@\" is incomplete.", name]);
      return nil;
    }

  c = [self new];
  c->_name = [name copy];
  c->_label = [[plist objectForKey: @"Label"] copy];
  c->_created = [plist objectForKey: @"Created"];
  c->_modified = [plist objectForKey: @"Modified"];
  c->_salt = [plist objectForKey: @"Salt"];
  c->_iterations = [[plist objectForKey: @"Iterations"] unsignedIntValue];
  c->_kdfIterations = c->_iterations;
  c->_envelope = plist;
  c->_index = [plist objectForKey: @"Index"];
  c->_items = [NSMutableArray new];
  c->_locked = YES;
  return c;
}

/* Everything shown or trusted while locked is bound to the ciphertext, so a
 * file edited to show another label or cost no longer unlocks. */
- (NSData *) additionalDataForLabel: (NSString *)label
                               salt: (NSData *)salt
                         iterations: (unsigned)iterations
{
  NSString *s = [NSString stringWithFormat: @"%@\n%u\n%@\n%u\n%@\n%@\n%@",
    KCFileFormat, KCFileVersion, KCKDFName, iterations,
    [salt base64EncodedStringWithOptions: 0], KCCipherName, label];
  return [s dataUsingEncoding: NSUTF8StringEncoding];
}

- (NSData *) deriveKey: (NSString *)password
{
  return [KCCrypto PBKDF2SHA256WithPassword: password salt: _salt
                                 iterations: _iterations length: 32];
}

- (NSData *) decryptEnvelopeWithKey: (NSData *)key
{
  return [KCCrypto AES256GCMDecrypt: [_envelope objectForKey: @"Ciphertext"]
    key: key nonce: [_envelope objectForKey: @"Nonce"]
    additionalData: [self additionalDataForLabel: [_envelope objectForKey: @"Label"]
                                            salt: _salt iterations: _iterations]
    tag: [_envelope objectForKey: @"Tag"]];
}

- (void) postChange: (NSString *)kind item: (KCItem *)item
{
  NSDictionary *info = item != nil
    ? [NSDictionary dictionaryWithObjectsAndKeys: kind, KCChangeKindKey,
        item, KCChangedItemKey, nil]
    : [NSDictionary dictionaryWithObject: kind forKey: KCChangeKindKey];
  [[NSNotificationCenter defaultCenter]
    postNotificationName: KCCollectionDidChangeNotification
                  object: self userInfo: info];
}

- (BOOL) unlockWithPassword: (NSString *)password error: (NSError **)error
{
  NSData *key;
  NSData *plain;
  id items = nil;

  if (!_locked)
    return YES;
  key = [self deriveKey: password];
  plain = [self decryptEnvelopeWithKey: key];
  if (plain == nil)
    {
      if (error != NULL)
        *error = KCError(KCKeyringErrorWrongPassword,
          @"The password is not correct, or the keyring file was modified.");
      return NO;
    }
  @try
    {
      items = [NSKeyedUnarchiver unarchiveObjectWithData: plain];
    }
  @catch (NSException *e)
    {
      items = nil;
    }
  if (![items isKindOfClass: [NSArray class]])
    {
      if (error != NULL)
        *error = KCError(KCKeyringErrorCorruptFile,
          @"The keyring decrypted but its contents are damaged.");
      return NO;
    }
  _items = [items mutableCopy];
  _key = key;
  _locked = NO;
  [self postChange: KCChangeCollection item: nil];
  return YES;
}

- (BOOL) verifyPassword: (NSString *)password
{
  NSData *key = [self deriveKey: password];

  if (!_locked)
    return [key isEqualToData: _key];
  return [self decryptEnvelopeWithKey: key] != nil;
}

- (void) lock
{
  if (_locked)
    return;
  /* The envelope has to describe the current items, or the next unlock
   * would bring back an older state. */
  _envelope = [self envelope];
  _index = [_envelope objectForKey: @"Index"];
  [_items removeAllObjects];
  _key = nil;
  _locked = YES;
  [self postChange: KCChangeCollection item: nil];
}

- (void) changePassword: (NSString *)password
{
  if (_locked)
    [NSException raise: NSInternalInconsistencyException
                format: @"changing the password of a locked keyring"];
  _salt = [KCCrypto randomBytes: 16];
  _iterations = _kdfIterations;
  _key = [self deriveKey: password];
}

- (NSData *) hashForAttribute: (NSString *)attrName value: (NSString *)value
{
  NSMutableData *d = [NSMutableData dataWithData: _salt];
  uint8_t zero = 0;

  [d appendData: [attrName dataUsingEncoding: NSUTF8StringEncoding]];
  [d appendBytes: &zero length: 1];
  [d appendData: [value dataUsingEncoding: NSUTF8StringEncoding]];
  return [KCCrypto SHA256: d];
}

- (NSArray *) hashesForAttributes: (NSDictionary *)attributes
{
  NSMutableArray *hashes = [NSMutableArray array];
  NSEnumerator *e = [attributes keyEnumerator];
  NSString *key;

  while ((key = [e nextObject]) != nil)
    [hashes addObject: [self hashForAttribute: key
                                        value: [attributes objectForKey: key]]];
  return hashes;
}

- (NSDictionary *) envelope
{
  NSMutableDictionary *index = [NSMutableDictionary dictionary];
  NSEnumerator *e = [_items objectEnumerator];
  NSData *nonce = [KCCrypto randomBytes: 12];
  NSData *tag = nil;
  NSData *plain;
  NSData *cipher;
  KCItem *item;

  while ((item = [e nextObject]) != nil)
    [index setObject: [self hashesForAttributes: [item attributes]]
              forKey: [item identifier]];

  plain = [NSKeyedArchiver archivedDataWithRootObject: [NSArray arrayWithArray: _items]];
  cipher = [KCCrypto AES256GCMEncrypt: plain key: _key nonce: nonce
    additionalData: [self additionalDataForLabel: _label salt: _salt
                                      iterations: _iterations]
    tag: &tag];

  return [NSDictionary dictionaryWithObjectsAndKeys:
    KCFileFormat, @"Format",
    [NSNumber numberWithUnsignedInt: KCFileVersion], @"Version",
    _label, @"Label",
    _created, @"Created",
    _modified, @"Modified",
    KCKDFName, @"KDF",
    [NSNumber numberWithUnsignedInt: _iterations], @"Iterations",
    _salt, @"Salt",
    KCCipherName, @"Cipher",
    nonce, @"Nonce",
    tag, @"Tag",
    cipher, @"Ciphertext",
    index, @"Index",
    nil];
}

- (NSData *) fileData
{
  NSError *error = nil;
  NSData *data;

  if (_locked)
    [NSException raise: NSInternalInconsistencyException
                format: @"writing locked keyring %@", _name];
  _envelope = [self envelope];
  _index = [_envelope objectForKey: @"Index"];
  data = [NSPropertyListSerialization dataWithPropertyList: _envelope
    format: NSPropertyListBinaryFormat_v1_0 options: 0 error: &error];
  if (data == nil)
    [NSException raise: NSInternalInconsistencyException
                format: @"serializing keyring %@: %@", _name, error];
  return data;
}

- (void) setLabel: (NSString *)label
{
  if (_locked)
    [NSException raise: NSInternalInconsistencyException
                format: @"renaming locked keyring %@", _name];
  _label = [label copy];
  _modified = [NSDate date];
  [self postChange: KCChangeCollection item: nil];
}

- (NSArray *) items
{
  return [NSArray arrayWithArray: _items];
}

- (KCItem *) itemWithIdentifier: (NSString *)identifier
{
  NSEnumerator *e = [_items objectEnumerator];
  KCItem *item;

  while ((item = [e nextObject]) != nil)
    {
      if ([[item identifier] isEqualToString: identifier])
        return item;
    }
  return nil;
}

- (NSArray *) itemIdentifiers
{
  if (_locked)
    return [[_index allKeys] sortedArrayUsingSelector: @selector(compare:)];
  return [_items valueForKey: @"identifier"];
}

- (NSArray *) itemIdentifiersMatchingAttributes: (NSDictionary *)query
{
  NSMutableArray *result = [NSMutableArray array];

  if (_locked)
    {
      NSSet *wanted = [NSSet setWithArray: [self hashesForAttributes: query]];
      NSEnumerator *e = [[self itemIdentifiers] objectEnumerator];
      NSString *identifier;

      while ((identifier = [e nextObject]) != nil)
        {
          NSSet *have = [NSSet setWithArray: [_index objectForKey: identifier]];
          if ([wanted isSubsetOfSet: have])
            [result addObject: identifier];
        }
    }
  else
    {
      NSEnumerator *e = [_items objectEnumerator];
      KCItem *item;

      while ((item = [e nextObject]) != nil)
        {
          if ([item matchesAttributes: query])
            [result addObject: [item identifier]];
        }
    }
  return result;
}

- (void) requireUnlocked
{
  if (_locked)
    [NSException raise: NSInternalInconsistencyException
                format: @"changing locked keyring %@", _name];
}

- (NSString *) nextIdentifier
{
  NSEnumerator *e = [_items objectEnumerator];
  KCItem *item;
  long long highest = 0;

  while ((item = [e nextObject]) != nil)
    highest = MAX(highest, [[item identifier] longLongValue]);
  return [NSString stringWithFormat: @"%lld", highest + 1];
}

- (KCItem *) createItemWithLabel: (NSString *)label
                      attributes: (NSDictionary *)attributes
                          secret: (NSData *)secret
                     contentType: (NSString *)contentType
                         replace: (BOOL)replace
{
  KCItem *item = nil;

  [self requireUnlocked];
  if (replace)
    {
      NSEnumerator *e = [_items objectEnumerator];
      KCItem *candidate;

      while ((candidate = [e nextObject]) != nil)
        {
          if ([[candidate attributes] isEqualToDictionary: attributes])
            {
              item = candidate;
              break;
            }
        }
    }

  if (item != nil)
    {
      [item setLabel: label];
      [item setSecret: secret];
      [item setContentType: contentType];
      [self itemDidChange: item];
      return item;
    }

  item = [[KCItem alloc] initWithIdentifier: [self nextIdentifier]];
  [item setLabel: label];
  [item setAttributes: attributes];
  [item setSecret: secret];
  [item setContentType: contentType];
  [_items addObject: item];
  _modified = [NSDate date];
  [self postChange: KCChangeItemCreated item: item];
  return item;
}

- (void) deleteItem: (KCItem *)item
{
  [self requireUnlocked];
  [_items removeObjectIdenticalTo: item];
  _modified = [NSDate date];
  [self postChange: KCChangeItemDeleted item: item];
}

- (void) itemDidChange: (KCItem *)item
{
  [self requireUnlocked];
  [item setModified: [NSDate date]];
  _modified = [item modified];
  [self postChange: KCChangeItemChanged item: item];
}

@end
