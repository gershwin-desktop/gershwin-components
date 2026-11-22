/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCScanner.h"
#import "SCOption.h"
#import "SCImage.h"
#import "SCImageBuilder.h"
#import "SCSaneLibrary.h"
#import <GNUstepBase/NSData+GNUstepBase.h>
#include <sane/saneopts.h>
#include <string.h>

NSString * const SCScannerOptionsDidChangeNotification
  = @"SCScannerOptionsDidChangeNotification";

/* Set by +initializeSANEWithError:, before any other SANE call */
static const SCSaneFunctions *SANE;

static SCAuthenticationHandler authenticationHandler;
static BOOL saneInitialized;
static BOOL scanWasCancelled;

static NSError *
SCSaneError(SANE_Status status, NSString *context)
{
  NSString *reason = [NSString stringWithUTF8String: SANE->strstatus(status)];

  return [NSError errorWithDomain: SCScannerErrorDomain code: status
                         userInfo: @{NSLocalizedDescriptionKey:
                                       [NSString stringWithFormat: @"%@: %@",
                                                 context, reason]}];
}

static NSError *
SCPlainError(NSString *message)
{
  return [NSError errorWithDomain: SCScannerErrorDomain code: 1
                         userInfo: @{NSLocalizedDescriptionKey: message}];
}

static void
SCCopyField(SANE_Char *dst, NSString *src)
{
  const char *utf8 = [src UTF8String];

  /* SANE gives fixed-size fields; a longer secret could never authenticate */
  strncpy(dst, utf8, SANE_MAX_USERNAME_LEN - 1);
  dst[SANE_MAX_USERNAME_LEN - 1] = '\0';
}

static void
SCAuthCallback(SANE_String_Const resource, SANE_Char *username,
               SANE_Char *password)
{
  @autoreleasepool
    {
      NSString *res = [NSString stringWithUTF8String: resource];
      NSString *salt = nil;
      NSString *user = nil;
      NSString *pass = nil;
      NSRange md5 = [res rangeOfString: @"$MD5$"];

      username[0] = '\0';
      password[0] = '\0';

      /* The net backend appends a salt so the password never travels in clear */
      if (md5.location != NSNotFound)
        {
          salt = [res substringFromIndex: NSMaxRange(md5)];
          res = [res substringToIndex: md5.location];
        }

      if (authenticationHandler == nil
          || !authenticationHandler(res, &user, &pass))
        {
          return;
        }

      if (salt != nil)
        {
          NSData *digest = [[[salt stringByAppendingString: pass]
                              dataUsingEncoding: NSUTF8StringEncoding]
                             md5Digest];
          NSMutableString *hex = [NSMutableString stringWithString: @"$MD5$"];
          const uint8_t *b = [digest bytes];
          NSUInteger i;

          for (i = 0; i < [digest length]; i++)
            {
              [hex appendFormat: @"%02x", b[i]];
            }
          pass = hex;
        }
      SCCopyField(username, user);
      SCCopyField(password, pass);
    }
}

double
SCOptionValueForFraction(SCOption *option, double fraction)
{
  double v = [option minimum]
    + fraction * ([option maximum] - [option minimum]);

  return [option constrainedNumber: v];
}

double
SCFractionForOptionValue(SCOption *option, double value)
{
  double span = [option maximum] - [option minimum];

  if (span <= 0)
    {
      return 0;
    }
  return MIN(1.0, MAX(0.0, (value - [option minimum]) / span));
}

NSString *
SCPersistentDeviceIdentifier(NSString *deviceName)
{
  NSArray *parts = [deviceName componentsSeparatedByString: @":"];

  if ([parts count] >= 3 && [[parts objectAtIndex: 0] isEqualToString: @"airscan"])
    {
      NSRange r = NSMakeRange(2, [parts count] - 2);

      return [@"airscan:" stringByAppendingString:
               [[parts subarrayWithRange: r] componentsJoinedByString: @":"]];
    }
  return deviceName;
}

NSArray *
SCAirscanAlternativeNames(NSString *deviceName)
{
  NSMutableArray *names = [NSMutableArray array];
  NSArray *parts = [deviceName componentsSeparatedByString: @":"];
  NSString *tag, *rest, *own;
  NSUInteger i;

  if ([parts count] < 3 || ![[parts objectAtIndex: 0] isEqualToString: @"airscan"])
    {
      return names;
    }
  tag = [parts objectAtIndex: 1];
  if ([tag length] < 2)
    {
      return names;
    }
  own = [tag substringToIndex: 1];
  rest = [[parts subarrayWithRange: NSMakeRange(2, [parts count] - 2)]
           componentsJoinedByString: @":"];
  for (NSString *protocol in @[own, [own isEqualToString: @"w"] ? @"e" : @"w"])
    {
      /* More devices of one kind than this in one network are not expected */
      for (i = 0; i < 10; i++)
        {
          NSString *name = [NSString stringWithFormat: @"airscan:%@%lu:%@",
                                     protocol, (unsigned long)i, rest];

          if (![name isEqualToString: deviceName])
            {
              [names addObject: name];
            }
        }
    }
  return names;
}

@implementation SCDeviceInfo

- (instancetype) initWithName: (NSString *)name vendor: (NSString *)vendor
                        model: (NSString *)model kind: (NSString *)kind
{
  self = [super init];
  if (self)
    {
      _name = [name copy];
      _vendor = [vendor copy];
      _model = [model copy];
      _kind = [kind copy];
    }
  return self;
}

- (NSString *) persistentIdentifier
{
  return SCPersistentDeviceIdentifier(_name);
}

- (NSDictionary *) propertyList
{
  return @{@"Name": _name, @"Vendor": _vendor, @"Model": _model, @"Kind": _kind};
}

+ (instancetype) deviceWithPropertyList: (NSDictionary *)plist
{
  NSString *name = [plist objectForKey: @"Name"];

  if (![plist isKindOfClass: [NSDictionary class]]
      || ![name isKindOfClass: [NSString class]])
    {
      return nil;
    }
  return [[self alloc] initWithName: name
                             vendor: [plist objectForKey: @"Vendor"]
                              model: [plist objectForKey: @"Model"]
                               kind: [plist objectForKey: @"Kind"]];
}

- (NSString *) displayName
{
  /* Several drivers report "Noname" or repeat the vendor inside the model */
  if ([_vendor length] == 0 || [_vendor isEqualToString: @"Noname"]
      || [_model hasPrefix: _vendor])
    {
      return _model;
    }
  return [NSString stringWithFormat: @"%@ %@", _vendor, _model];
}

@end

@implementation SCScanner
{
  SANE_Handle _handle;
  NSDictionary *_optionsByName;
  volatile BOOL _cancelRequested;
  /* Orders the cancel thread against the end of the batch, after which the handle may close */
  NSLock *_cancelLock;
  BOOL _batchEnded;
}

+ (BOOL) initializeSANEWithError: (NSError **)error
{
  SANE_Int version;
  SANE_Status status;

  if (saneInitialized)
    {
      return YES;
    }
  SANE = SCSaneLoad(error);
  if (SANE == NULL)
    {
      return NO;
    }
  status = SANE->init(&version, SCAuthCallback);
  if (status != SANE_STATUS_GOOD)
    {
      if (error)
        {
          *error = SCSaneError(status, @"Could not initialize scanner support");
        }
      return NO;
    }
  saneInitialized = YES;
  return YES;
}

+ (void) exitSANE
{
  if (saneInitialized)
    {
      SANE->exit();
      saneInitialized = NO;
    }
}

+ (BOOL) mustSkipExitHandlers
{
  return scanWasCancelled;
}

+ (void) setAuthenticationHandler: (SCAuthenticationHandler)handler
{
  authenticationHandler = [handler copy];
}

+ (NSArray *) devicesWithError: (NSError **)error
{
  const SANE_Device **list = NULL;
  NSMutableArray *devices = [NSMutableArray array];
  SANE_Status status = SANE->get_devices(&list, SANE_FALSE);
  NSUInteger i;

  if (status != SANE_STATUS_GOOD)
    {
      if (error)
        {
          *error = SCSaneError(status, @"Could not look for scanners");
        }
      return nil;
    }
  for (i = 0; list[i] != NULL; i++)
    {
      const SANE_Device *d = list[i];

      [devices addObject:
        [[SCDeviceInfo alloc]
          initWithName: [NSString stringWithUTF8String: d->name]
                vendor: [NSString stringWithUTF8String: d->vendor]
                 model: [NSString stringWithUTF8String: d->model]
                  kind: [NSString stringWithUTF8String: d->type]]];
    }
  return devices;
}

- (instancetype) initWithDevice: (SCDeviceInfo *)device error: (NSError **)error
{
  self = [super init];
  if (self)
    {
      SANE_Status status = SANE->open([[device name] UTF8String], &_handle);

      if (status != SANE_STATUS_GOOD)
        {
          if (error)
            {
              *error = SCSaneError(status, [NSString stringWithFormat:
                @"Could not open %@", [device displayName]]);
            }
          return nil;
        }
      _device = device;
      [self loadOptions];
    }
  return self;
}

+ (instancetype) scannerOpeningDevice: (SCDeviceInfo *)device error: (NSError **)error
{
  SCScanner *scanner = [[self alloc] initWithDevice: device error: error];

  if (scanner != nil)
    {
      return scanner;
    }
  for (NSString *name in SCAirscanAlternativeNames([device name]))
    {
      SCDeviceInfo *renamed = [[SCDeviceInfo alloc] initWithName: name
                                                          vendor: [device vendor]
                                                           model: [device model]
                                                            kind: [device kind]];

      scanner = [[self alloc] initWithDevice: renamed error: NULL];
      if (scanner != nil)
        {
          return scanner;
        }
    }
  /* The error of the name that was asked for says the most */
  return nil;
}

- (void) dealloc
{
  [self close];
}

- (void) close
{
  if (_handle != NULL)
    {
      NSAssert(!_scanning, @"close while scanning");
      SANE->close(_handle);
      _handle = NULL;
    }
}

- (void) loadOptions
{
  const SANE_Option_Descriptor *d0 = SANE->get_option_descriptor(_handle, 0);
  NSMutableArray *options = [NSMutableArray array];
  NSMutableDictionary *byName = [NSMutableDictionary dictionary];
  NSString *group = @"";
  SANE_Int count = 0;
  SANE_Int i;

  /* Option 0 is always the option count */
  if (d0 != NULL)
    {
      SANE->control_option(_handle, 0, SANE_ACTION_GET_VALUE, &count, NULL);
    }

  for (i = 1; i < count; i++)
    {
      const SANE_Option_Descriptor *d = SANE->get_option_descriptor(_handle, i);
      SCOption *option;

      if (d == NULL)
        {
          continue;
        }
      option = [[SCOption alloc] initWithDescriptor: d index: i
                                         groupTitle: group];
      if ([option type] == SCOptionTypeGroup)
        {
          group = [option title];
          continue;
        }
      [self readValueOfOption: option];
      [options addObject: option];
      if ([[option name] length] > 0)
        {
          [byName setObject: option forKey: [option name]];
        }
    }
  _options = options;
  _optionsByName = byName;
}

- (void) readValueOfOption: (SCOption *)option
{
  NSMutableData *buffer;

  if (![option isActive] || [option type] == SCOptionTypeButton
      || [option bufferSize] == 0)
    {
      [option setValue: nil];
      return;
    }
  buffer = [NSMutableData dataWithLength: [option bufferSize] + 1];
  if (SANE->control_option(_handle, [option index], SANE_ACTION_GET_VALUE,
                          [buffer mutableBytes], NULL) == SANE_STATUS_GOOD)
    {
      [option setValue: [option valueFromBuffer: [buffer bytes]]];
    }
  else
    {
      [option setValue: nil];
    }
}

- (void) reloadOptions
{
  [self loadOptions];
  [[NSNotificationCenter defaultCenter]
    postNotificationName: SCScannerOptionsDidChangeNotification object: self];
}

- (SCOption *) optionNamed: (NSString *)name
{
  return [_optionsByName objectForKey: name];
}

- (BOOL) applyAction: (SANE_Action)action toOption: (SCOption *)option
              buffer: (void *)buffer error: (NSError **)error
{
  SANE_Int info = 0;
  SANE_Status status;

  NSAssert(!_scanning, @"option change while scanning");
  status = SANE->control_option(_handle, [option index], action, buffer, &info);
  if (status != SANE_STATUS_GOOD)
    {
      if (error)
        {
          *error = SCSaneError(status, [NSString stringWithFormat:
            @"Could not change \"%@\"", [option title]]);
        }
      return NO;
    }
  if (info & (SANE_INFO_RELOAD_OPTIONS | SANE_INFO_RELOAD_PARAMS))
    {
      [self reloadOptions];
    }
  else
    {
      /* SANE_INFO_INEXACT: the driver rounded, so show what it really uses */
      [self readValueOfOption: option];
    }
  return YES;
}

- (BOOL) setValue: (id)value forOption: (SCOption *)option error: (NSError **)error
{
  NSMutableData *buffer = [NSMutableData dataWithLength: [option bufferSize] + 1];

  if (![option fillBuffer: [buffer mutableBytes] fromValue: value])
    {
      if (error)
        {
          *error = SCPlainError([NSString stringWithFormat:
            @"\"%@\" is not a valid value for \"%@\".", value, [option title]]);
        }
      return NO;
    }
  return [self applyAction: SANE_ACTION_SET_VALUE toOption: option
                    buffer: [buffer mutableBytes] error: error];
}

- (BOOL) setAutomaticForOption: (SCOption *)option error: (NSError **)error
{
  return [self applyAction: SANE_ACTION_SET_AUTO toOption: option
                    buffer: NULL error: error];
}

- (BOOL) pressButton: (SCOption *)option error: (NSError **)error
{
  return [self applyAction: SANE_ACTION_SET_VALUE toOption: option
                    buffer: NULL error: error];
}

- (NSDictionary *) savedValues
{
  NSMutableDictionary *values = [NSMutableDictionary dictionary];

  for (SCOption *option in _options)
    {
      if ([option isActive] && [option isSettable] && [option value] != nil
          && ![[option name] isEqualToString: @SANE_NAME_PREVIEW])
        {
          [values setObject: [option value] forKey: [option name]];
        }
    }
  return values;
}

- (void) restoreValues: (NSDictionary *)values
{
  NSUInteger pass;

  /*
   * Options depend on each other (a mode enables a depth, a source changes
   * the area limits), so a value may only become settable after another
   * one was restored; two passes cover the dependencies drivers have.
   */
  for (pass = 0; pass < 2; pass++)
    {
      NSArray *names = [[values allKeys] copy];

      for (NSString *name in names)
        {
          SCOption *option = [self optionNamed: name];
          id value = [values objectForKey: name];

          if (option == nil || ![option isActive] || ![option isSettable]
              || [[option value] isEqual: value])
            {
              continue;
            }
          /* A device whose driver changed may reject old values; keep its own */
          [self setValue: value forOption: option error: NULL];
        }
    }
}

- (double) resolution
{
  SCOption *option = [self optionNamed: @SANE_NAME_SCAN_RESOLUTION];

  if (option == nil)
    {
      option = [self optionNamed: @SANE_NAME_SCAN_X_RESOLUTION];
    }
  if (option == nil || ![[option value] isKindOfClass: [NSNumber class]])
    {
      return 0;
    }
  return [[option value] doubleValue];
}

- (NSArray *) areaOptions
{
  SCOption *tlx = [self optionNamed: @SANE_NAME_SCAN_TL_X];
  SCOption *tly = [self optionNamed: @SANE_NAME_SCAN_TL_Y];
  SCOption *brx = [self optionNamed: @SANE_NAME_SCAN_BR_X];
  SCOption *bry = [self optionNamed: @SANE_NAME_SCAN_BR_Y];

  if (tlx == nil || tly == nil || brx == nil || bry == nil)
    {
      return nil;
    }
  for (SCOption *o in @[tlx, tly, brx, bry])
    {
      if (![o isActive] || ![o isSettable]
          || [o constraint] != SCOptionConstraintRange)
        {
          return nil;
        }
    }
  return @[tlx, tly, brx, bry];
}

static inline SCOption *
SCAt(NSArray *a, NSUInteger i)
{
  return [a objectAtIndex: i];
}

- (BOOL) hasScanArea
{
  return [self areaOptions] != nil;
}

- (NSRect) normalizedScanArea
{
  NSArray *a = [self areaOptions];
  double x0, y0, x1, y1;

  if (a == nil)
    {
      return NSMakeRect(0, 0, 1, 1);
    }
  x0 = SCFractionForOptionValue(SCAt(a, 0), [[SCAt(a, 0) value] doubleValue]);
  y0 = SCFractionForOptionValue(SCAt(a, 1), [[SCAt(a, 1) value] doubleValue]);
  x1 = SCFractionForOptionValue(SCAt(a, 2), [[SCAt(a, 2) value] doubleValue]);
  y1 = SCFractionForOptionValue(SCAt(a, 3), [[SCAt(a, 3) value] doubleValue]);
  return NSMakeRect(x0, y0, MAX(0, x1 - x0), MAX(0, y1 - y0));
}

- (BOOL) setNormalizedScanArea: (NSRect)area error: (NSError **)error
{
  NSArray *a = [self areaOptions];
  double values[4];
  NSUInteger i;

  if (a == nil)
    {
      if (error)
        {
          *error = SCPlainError(@"This scanner does not support selecting an area.");
        }
      return NO;
    }
  values[0] = SCOptionValueForFraction(SCAt(a, 0), NSMinX(area));
  values[1] = SCOptionValueForFraction(SCAt(a, 1), NSMinY(area));
  values[2] = SCOptionValueForFraction(SCAt(a, 2), NSMaxX(area));
  values[3] = SCOptionValueForFraction(SCAt(a, 3), NSMaxY(area));

  /* Setting tl before br could be refused when the new tl lies past the old br */
  for (i = 0; i < 2; i++)
    {
      NSUInteger order[4] = {2, 3, 0, 1};
      NSUInteger k;

      for (k = 0; k < 4; k++)
        {
          NSUInteger j = order[k];
          SCOption *o = SCAt([self areaOptions], j);
          NSNumber *n = ([o type] == SCOptionTypeInt)
            ? [NSNumber numberWithInt: (int)values[j]]
            : [NSNumber numberWithDouble: values[j]];

          if (i == 1 && [[o value] isEqual: n])
            {
              continue;
            }
          if (![self setValue: n forOption: o error: error])
            {
              return NO;
            }
        }
    }
  return YES;
}

- (NSSize) scanAreaSizeInMillimeters
{
  NSArray *a = [self areaOptions];

  if (a == nil || [SCAt(a, 2) unit] != SANE_UNIT_MM || [SCAt(a, 3) unit] != SANE_UNIT_MM)
    {
      return NSZeroSize;
    }
  return NSMakeSize([SCAt(a, 2) maximum] - [SCAt(a, 0) minimum],
                    [SCAt(a, 3) maximum] - [SCAt(a, 1) minimum]);
}

- (BOOL) sourceFeedsMultiplePages
{
  SCOption *source = [self optionNamed: @SANE_NAME_SCAN_SOURCE];
  NSString *value = [[source value] lowercaseString];

  if (![value isKindOfClass: [NSString class]])
    {
      return NO;
    }
  return [value rangeOfString: @"adf"].location != NSNotFound
    || [value rangeOfString: @"feeder"].location != NSNotFound
    || [value rangeOfString: @"duplex"].location != NSNotFound;
}

- (void) startScanAllowingMultiplePages: (BOOL)multiplePages
{
  NSAssert(!_scanning, @"scan already running");
  _scanning = YES;
  _cancelRequested = NO;
  _batchEnded = NO;
  if (_cancelLock == nil)
    {
      _cancelLock = [NSLock new];
    }
  [NSThread detachNewThreadSelector: @selector(scanThread:)
                           toTarget: self
                         withObject: @{@"multi": @(multiplePages),
                                       @"dpi": @([self resolution])}];
}

- (void) cancel
{
  if (_scanning)
    {
      _cancelRequested = YES;
      scanWasCancelled = YES;
      /*
       * sane_cancel is the one call SANE allows from another thread. It
       * gets a thread of its own because drivers built on sanei_thread can
       * block in it (see +mustSkipExitHandlers), and the window must stay
       * responsive even then.
       */
      [NSThread detachNewThreadSelector: @selector(cancelThread:)
                               toTarget: self withObject: nil];
    }
}

- (void) cancelThread: (id)unused
{
  [_cancelLock lock];
  if (!_batchEnded)
    {
      SANE->cancel(_handle);
    }
  [_cancelLock unlock];
}

- (void) deliverImage: (SCImage *)image
{
  [_delegate scanner: self didScanImage: image];
}

- (void) deliverProgress: (NSNumber *)fraction
{
  [_delegate scanner: self progress: [fraction doubleValue]];
}

- (void) deliverFinish: (NSDictionary *)result
{
  _scanning = NO;
  [_delegate scannerDidFinish: self
                    cancelled: [[result objectForKey: @"cancelled"] boolValue]
                        error: [result objectForKey: @"error"]];
}

/* Returns nil at the end of a batch, with *error set on failure */
- (SCImage *) scanPage: (NSUInteger)page resolution: (double)dpi
             cancelled: (BOOL *)cancelled error: (NSError **)error
{
  SCImageBuilder *builder = [SCImageBuilder new];
  static const NSUInteger chunk = 128 * 1024;
  uint8_t *buffer = malloc(chunk);
  NSDate *lastProgress = [NSDate distantPast];
  SCImage *image = nil;

  *cancelled = NO;
  for (;;)
    {
      SANE_Parameters params;
      SANE_Status status = SANE->start(_handle);

      if (status == SANE_STATUS_NO_DOCS && page > 0)
        {
          break;
        }
      if (status == SANE_STATUS_CANCELLED || _cancelRequested)
        {
          *cancelled = YES;
          break;
        }
      if (status != SANE_STATUS_GOOD)
        {
          *error = SCSaneError(status, @"Could not start scanning");
          break;
        }
      status = SANE->get_parameters(_handle, &params);
      if (status != SANE_STATUS_GOOD)
        {
          *error = SCSaneError(status, @"Could not read the image format");
          break;
        }
      if (![builder beginFrameWithParameters: &params error: error])
        {
          break;
        }

      for (;;)
        {
          SANE_Int len = 0;

          status = SANE->read(_handle, buffer, chunk, &len);
          if (status != SANE_STATUS_GOOD)
            {
              break;
            }
          [builder appendBytes: buffer length: len];
          /* Throttled so a fast scanner does not flood the main thread */
          if ([lastProgress timeIntervalSinceNow] < -0.1)
            {
              lastProgress = [NSDate date];
              [self performSelectorOnMainThread: @selector(deliverProgress:)
                                     withObject: @([builder frameProgress])
                                  waitUntilDone: NO];
            }
        }
      [builder endFrame];

      if (status == SANE_STATUS_CANCELLED || _cancelRequested)
        {
          *cancelled = YES;
          break;
        }
      if (status != SANE_STATUS_EOF)
        {
          *error = SCSaneError(status, @"Scanning failed");
          break;
        }
      if ([builder isComplete])
        {
          image = [builder imageWithResolution: dpi error: error];
          break;
        }
    }
  free(buffer);
  return image;
}

- (void) scanThread: (NSDictionary *)args
{
  @autoreleasepool
    {
      BOOL multi = [[args objectForKey: @"multi"] boolValue];
      double dpi = [[args objectForKey: @"dpi"] doubleValue];
      BOOL cancelled = NO;
      NSError *error = nil;
      NSUInteger page = 0;
      NSMutableDictionary *result = [NSMutableDictionary dictionary];

      for (;;)
        {
          @autoreleasepool
            {
              SCImage *image = [self scanPage: page resolution: dpi
                                    cancelled: &cancelled error: &error];

              if (image == nil)
                {
                  break;
                }
              [self performSelectorOnMainThread: @selector(deliverImage:)
                                     withObject: image waitUntilDone: NO];
              page++;
              if (!multi)
                {
                  break;
                }
            }
        }
      /* Ends the batch; required after the last page even when it succeeded */
      [_cancelLock lock];
      SANE->cancel(_handle);
      _batchEnded = YES;
      [_cancelLock unlock];

      [result setObject: @(cancelled) forKey: @"cancelled"];
      if (error != nil && !cancelled)
        {
          [result setObject: error forKey: @"error"];
        }
      [self performSelectorOnMainThread: @selector(deliverFinish:)
                             withObject: result waitUntilDone: NO];
    }
}

@end
