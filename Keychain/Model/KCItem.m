/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "KCItem.h"

/* Attribute names used for the list columns, most specific first:
 * libsecret's generic schema and keytar (service/account), git credential
 * helpers (server/user), and a few other common ones. */
static NSArray *KCServiceKeys(void)
{
  return [NSArray arrayWithObjects: @"service", @"server", @"host",
    @"domain", @"origin", nil];
}

static NSArray *KCAccountKeys(void)
{
  return [NSArray arrayWithObjects: @"account", @"user", @"username",
    @"login", nil];
}

@implementation KCItem

@synthesize identifier = _identifier;

+ (BOOL) supportsSecureCoding
{
  return YES;
}

- (instancetype) initWithIdentifier: (NSString *)identifier
{
  if ((self = [super init]) != nil)
    {
      NSDate *now = [NSDate date];
      _identifier = [identifier copy];
      _label = @"";
      _attributes = [NSDictionary dictionary];
      _secret = [NSData data];
      _contentType = @"text/plain";
      _created = now;
      _modified = now;
    }
  return self;
}

- (instancetype) initWithCoder: (NSCoder *)coder
{
  if ((self = [super init]) != nil)
    {
      _identifier = [coder decodeObjectForKey: @"Identifier"];
      _label = [coder decodeObjectForKey: @"Label"];
      _attributes = [coder decodeObjectForKey: @"Attributes"];
      _secret = [coder decodeObjectForKey: @"Secret"];
      _contentType = [coder decodeObjectForKey: @"ContentType"];
      _created = [coder decodeObjectForKey: @"Created"];
      _modified = [coder decodeObjectForKey: @"Modified"];
      if (![_identifier isKindOfClass: [NSString class]]
        || ![_attributes isKindOfClass: [NSDictionary class]]
        || ![_secret isKindOfClass: [NSData class]])
        return nil;
    }
  return self;
}

- (void) encodeWithCoder: (NSCoder *)coder
{
  [coder encodeObject: _identifier forKey: @"Identifier"];
  [coder encodeObject: _label forKey: @"Label"];
  [coder encodeObject: _attributes forKey: @"Attributes"];
  [coder encodeObject: _secret forKey: @"Secret"];
  [coder encodeObject: _contentType forKey: @"ContentType"];
  [coder encodeObject: _created forKey: @"Created"];
  [coder encodeObject: _modified forKey: @"Modified"];
}

- (BOOL) matchesAttributes: (NSDictionary *)query
{
  NSEnumerator *e = [query keyEnumerator];
  NSString *key;

  while ((key = [e nextObject]) != nil)
    {
      if (![[_attributes objectForKey: key] isEqual: [query objectForKey: key]])
        return NO;
    }
  return YES;
}

- (NSString *) firstAttributeOf: (NSArray *)keys
{
  NSEnumerator *e = [keys objectEnumerator];
  NSString *key;

  while ((key = [e nextObject]) != nil)
    {
      NSString *value = [_attributes objectForKey: key];
      if ([value length] > 0)
        return value;
    }
  return nil;
}

- (NSString *) displayService
{
  NSString *s = [self firstAttributeOf: KCServiceKeys()];
  return s != nil ? s : (_label != nil ? _label : @"");
}

- (NSString *) displayAccount
{
  NSString *a = [self firstAttributeOf: KCAccountKeys()];
  return a != nil ? a : @"";
}

@end
