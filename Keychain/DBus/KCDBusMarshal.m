/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "KCDBusMarshal.h"

@implementation KCDBusObjectPath

@synthesize string = _string;

+ (instancetype) pathWithString: (NSString *)string
{
  KCDBusObjectPath *p = [self new];
  p->_string = [string copy];
  return p;
}

- (id) copyWithZone: (NSZone *)zone
{
  return self;
}

- (BOOL) isEqual: (id)other
{
  return [other isKindOfClass: [KCDBusObjectPath class]]
    && [_string isEqualToString: [other string]];
}

- (NSUInteger) hash
{
  return [_string hash];
}

- (NSString *) description
{
  return _string;
}

- (NSComparisonResult) compare: (KCDBusObjectPath *)other
{
  return [_string compare: [other string]];
}

@end

@implementation KCDBusVariant

@synthesize signature = _signature;
@synthesize value = _value;

+ (instancetype) variantWithSignature: (NSString *)signature value: (id)value
{
  KCDBusVariant *v = [self new];
  v->_signature = [signature copy];
  v->_value = value;
  return v;
}

- (NSString *) description
{
  return [NSString stringWithFormat: @"<%@ %@>", _signature, _value];
}

@end

static void KCTypeError(const char *expected, id value)
{
  [NSException raise: NSInvalidArgumentException
              format: @"D-Bus type %s cannot hold %@ (%@)", expected,
                      value, NSStringFromClass([value class])];
}

static void KCOOM(void)
{
  [NSException raise: NSMallocException format: @"libdbus out of memory"];
}

static void KCAppendValue(DBusMessageIter *iter, DBusSignatureIter *sig, id value);

static void KCAppendBasic(DBusMessageIter *iter, int type, id value)
{
  union {
    unsigned char y; dbus_bool_t b; dbus_int16_t n; dbus_uint16_t q;
    dbus_int32_t i; dbus_uint32_t u; dbus_int64_t x; dbus_uint64_t t;
    double d; const char *s;
  } v;

  switch (type)
    {
      case DBUS_TYPE_STRING:
      case DBUS_TYPE_SIGNATURE:
        if (![value isKindOfClass: [NSString class]])
          KCTypeError("s", value);
        v.s = [value UTF8String];
        break;
      case DBUS_TYPE_OBJECT_PATH:
        if (![value isKindOfClass: [KCDBusObjectPath class]])
          KCTypeError("o", value);
        v.s = [[value string] UTF8String];
        if (!dbus_validate_path(v.s, NULL))
          KCTypeError("o", value);
        break;
      default:
        if (![value isKindOfClass: [NSNumber class]])
          KCTypeError("number", value);
        switch (type)
          {
            case DBUS_TYPE_BYTE: v.y = [value unsignedCharValue]; break;
            case DBUS_TYPE_BOOLEAN: v.b = [value boolValue] ? TRUE : FALSE; break;
            case DBUS_TYPE_INT16: v.n = [value shortValue]; break;
            case DBUS_TYPE_UINT16: v.q = [value unsignedShortValue]; break;
            case DBUS_TYPE_INT32: v.i = [value intValue]; break;
            case DBUS_TYPE_UINT32: v.u = [value unsignedIntValue]; break;
            case DBUS_TYPE_INT64: v.x = [value longLongValue]; break;
            case DBUS_TYPE_UINT64: v.t = [value unsignedLongLongValue]; break;
            case DBUS_TYPE_DOUBLE: v.d = [value doubleValue]; break;
            default: KCTypeError("unsupported", value);
          }
    }
  if (!dbus_message_iter_append_basic(iter, type, &v))
    KCOOM();
}

static void KCAppendArray(DBusMessageIter *iter, DBusSignatureIter *sig, id value)
{
  DBusSignatureIter elementSig;
  DBusMessageIter sub;
  char *elementSignature;
  int elementType;

  dbus_signature_iter_recurse(sig, &elementSig);
  elementType = dbus_signature_iter_get_current_type(&elementSig);
  elementSignature = dbus_signature_iter_get_signature(&elementSig);
  if (elementSignature == NULL)
    KCOOM();

  if (!dbus_message_iter_open_container(iter, DBUS_TYPE_ARRAY,
                                        elementSignature, &sub))
    KCOOM();
  dbus_free(elementSignature);

  if (elementType == DBUS_TYPE_BYTE)
    {
      const unsigned char *bytes;
      int length;

      if (![value isKindOfClass: [NSData class]])
        KCTypeError("ay", value);
      bytes = [value bytes];
      length = (int)[value length];
      if (!dbus_message_iter_append_fixed_array(&sub, DBUS_TYPE_BYTE,
                                                &bytes, length))
        KCOOM();
    }
  else if (elementType == DBUS_TYPE_DICT_ENTRY)
    {
      NSEnumerator *e;
      id key;

      if (![value isKindOfClass: [NSDictionary class]])
        KCTypeError("a{}", value);
      /* Sorted so replies are reproducible, which keeps tests and
       * busctl output stable. */
      e = [[[value allKeys] sortedArrayUsingSelector: @selector(compare:)]
            objectEnumerator];
      while ((key = [e nextObject]) != nil)
        {
          DBusMessageIter entry;
          DBusSignatureIter entrySig;

          dbus_signature_iter_recurse(&elementSig, &entrySig);
          if (!dbus_message_iter_open_container(&sub, DBUS_TYPE_DICT_ENTRY,
                                                NULL, &entry))
            KCOOM();
          KCAppendValue(&entry, &entrySig, key);
          dbus_signature_iter_next(&entrySig);
          KCAppendValue(&entry, &entrySig, [value objectForKey: key]);
          if (!dbus_message_iter_close_container(&sub, &entry))
            KCOOM();
        }
    }
  else
    {
      NSEnumerator *e;
      id element;

      if (![value isKindOfClass: [NSArray class]])
        KCTypeError("array", value);
      e = [value objectEnumerator];
      while ((element = [e nextObject]) != nil)
        {
          DBusSignatureIter each = elementSig;
          KCAppendValue(&sub, &each, element);
        }
    }

  if (!dbus_message_iter_close_container(iter, &sub))
    KCOOM();
}

static void KCAppendValue(DBusMessageIter *iter, DBusSignatureIter *sig, id value)
{
  int type = dbus_signature_iter_get_current_type(sig);

  if (value == nil)
    KCTypeError("non-nil", value);

  switch (type)
    {
      case DBUS_TYPE_ARRAY:
        KCAppendArray(iter, sig, value);
        break;

      case DBUS_TYPE_STRUCT:
        {
          DBusMessageIter sub;
          DBusSignatureIter member;
          NSUInteger i = 0;

          if (![value isKindOfClass: [NSArray class]])
            KCTypeError("struct", value);
          if (!dbus_message_iter_open_container(iter, DBUS_TYPE_STRUCT, NULL, &sub))
            KCOOM();
          dbus_signature_iter_recurse(sig, &member);
          do
            {
              if (i >= [value count])
                KCTypeError("struct member", value);
              KCAppendValue(&sub, &member, [value objectAtIndex: i++]);
            }
          while (dbus_signature_iter_next(&member));
          if (i != [value count])
            KCTypeError("struct (too many members)", value);
          if (!dbus_message_iter_close_container(iter, &sub))
            KCOOM();
        }
        break;

      case DBUS_TYPE_VARIANT:
        {
          DBusMessageIter sub;
          DBusSignatureIter inner;
          const char *innerSignature;

          if (![value isKindOfClass: [KCDBusVariant class]])
            KCTypeError("v", value);
          innerSignature = [[value signature] UTF8String];
          if (!dbus_signature_validate_single(innerSignature, NULL))
            KCTypeError("v signature", value);
          if (!dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT,
                                                innerSignature, &sub))
            KCOOM();
          dbus_signature_iter_init(&inner, innerSignature);
          KCAppendValue(&sub, &inner, [value value]);
          if (!dbus_message_iter_close_container(iter, &sub))
            KCOOM();
        }
        break;

      default:
        KCAppendBasic(iter, type, value);
    }
}

void KCDBusAppendArguments(DBusMessage *message, NSString *signature, NSArray *values)
{
  DBusMessageIter iter;
  DBusSignatureIter sig;
  const char *s = [signature UTF8String];
  NSUInteger i = 0;

  if (!dbus_signature_validate(s, NULL))
    [NSException raise: NSInvalidArgumentException
                format: @"invalid D-Bus signature %@", signature];
  dbus_message_iter_init_append(message, &iter);
  if (*s == '\0')
    {
      if ([values count] != 0)
        KCTypeError("no arguments", values);
      return;
    }
  dbus_signature_iter_init(&sig, s);
  do
    {
      if (i >= [values count])
        KCTypeError("more arguments", values);
      KCAppendValue(&iter, &sig, [values objectAtIndex: i++]);
    }
  while (dbus_signature_iter_next(&sig));
  if (i != [values count])
    KCTypeError("fewer arguments", values);
}

static id KCReadValue(DBusMessageIter *iter)
{
  int type = dbus_message_iter_get_arg_type(iter);

  switch (type)
    {
      case DBUS_TYPE_STRING:
      case DBUS_TYPE_SIGNATURE:
      case DBUS_TYPE_OBJECT_PATH:
        {
          const char *s = NULL;
          NSString *str;

          dbus_message_iter_get_basic(iter, &s);
          str = [NSString stringWithUTF8String: s];
          return type == DBUS_TYPE_OBJECT_PATH
            ? (id)[KCDBusObjectPath pathWithString: str] : (id)str;
        }
      case DBUS_TYPE_BOOLEAN:
        {
          dbus_bool_t b = FALSE;
          dbus_message_iter_get_basic(iter, &b);
          return [NSNumber numberWithBool: b ? YES : NO];
        }
      case DBUS_TYPE_BYTE:
        {
          unsigned char y = 0;
          dbus_message_iter_get_basic(iter, &y);
          return [NSNumber numberWithUnsignedChar: y];
        }
      case DBUS_TYPE_INT16:
      case DBUS_TYPE_INT32:
      case DBUS_TYPE_INT64:
        {
          DBusBasicValue v;
          dbus_message_iter_get_basic(iter, &v);
          return [NSNumber numberWithLongLong: type == DBUS_TYPE_INT16 ? v.i16
            : type == DBUS_TYPE_INT32 ? v.i32 : v.i64];
        }
      case DBUS_TYPE_UINT16:
      case DBUS_TYPE_UINT32:
      case DBUS_TYPE_UINT64:
        {
          DBusBasicValue v;
          dbus_message_iter_get_basic(iter, &v);
          return [NSNumber numberWithUnsignedLongLong: type == DBUS_TYPE_UINT16
            ? v.u16 : type == DBUS_TYPE_UINT32 ? v.u32 : v.u64];
        }
      case DBUS_TYPE_DOUBLE:
        {
          double d = 0;
          dbus_message_iter_get_basic(iter, &d);
          return [NSNumber numberWithDouble: d];
        }
      case DBUS_TYPE_VARIANT:
        {
          DBusMessageIter sub;
          char *signature;
          KCDBusVariant *v;

          dbus_message_iter_recurse(iter, &sub);
          signature = dbus_message_iter_get_signature(&sub);
          v = [KCDBusVariant variantWithSignature:
                [NSString stringWithUTF8String: signature]
                                            value: KCReadValue(&sub)];
          dbus_free(signature);
          return v;
        }
      case DBUS_TYPE_STRUCT:
        {
          DBusMessageIter sub;
          NSMutableArray *members = [NSMutableArray array];

          dbus_message_iter_recurse(iter, &sub);
          while (dbus_message_iter_get_arg_type(&sub) != DBUS_TYPE_INVALID)
            {
              [members addObject: KCReadValue(&sub)];
              dbus_message_iter_next(&sub);
            }
          return members;
        }
      case DBUS_TYPE_ARRAY:
        {
          DBusMessageIter sub;
          int elementType = dbus_message_iter_get_element_type(iter);

          dbus_message_iter_recurse(iter, &sub);
          if (elementType == DBUS_TYPE_BYTE)
            {
              const unsigned char *bytes = NULL;
              int length = 0;
              dbus_message_iter_get_fixed_array(&sub, &bytes, &length);
              return [NSData dataWithBytes: bytes length: length];
            }
          if (elementType == DBUS_TYPE_DICT_ENTRY)
            {
              NSMutableDictionary *dict = [NSMutableDictionary dictionary];
              while (dbus_message_iter_get_arg_type(&sub) == DBUS_TYPE_DICT_ENTRY)
                {
                  DBusMessageIter entry;
                  id key;

                  dbus_message_iter_recurse(&sub, &entry);
                  key = KCReadValue(&entry);
                  dbus_message_iter_next(&entry);
                  [dict setObject: KCReadValue(&entry) forKey: key];
                  dbus_message_iter_next(&sub);
                }
              return dict;
            }
          NSMutableArray *elements = [NSMutableArray array];
          while (dbus_message_iter_get_arg_type(&sub) != DBUS_TYPE_INVALID)
            {
              [elements addObject: KCReadValue(&sub)];
              dbus_message_iter_next(&sub);
            }
          return elements;
        }
      default:
        /* Unix fds and future types: never part of the Secret Service API. */
        return [NSNull null];
    }
}

NSArray *KCDBusReadArguments(DBusMessage *message)
{
  DBusMessageIter iter;
  NSMutableArray *args = [NSMutableArray array];

  if (!dbus_message_iter_init(message, &iter))
    return args;
  while (dbus_message_iter_get_arg_type(&iter) != DBUS_TYPE_INVALID)
    {
      [args addObject: KCReadValue(&iter)];
      dbus_message_iter_next(&iter);
    }
  return args;
}
