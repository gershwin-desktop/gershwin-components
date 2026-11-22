/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCPanelScanning.h"
#import "SCWSDClient.h"
#import "SCWSDEventListener.h"
#import "SCFax.h"
#import "SCImageBuilder.h"

/* Registrations last this long and are renewed well before they run out */
static const NSTimeInterval SCRegistrationDuration = 3600;
static const NSTimeInterval SCRenewalInterval = 3000;

@implementation SCPanelScanning
{
  NSString *_host;
  NSString *_name;
  /* Told apart from other computers' registrations on the same printer */
  NSString *_context;
  SCWSDClient *_client;
  SCWSDEventListener *_listener;
  SCWSDSubscription *_subscription;
  NSTimer *_renewal;
  BOOL _stopped;
}

+ (NSString *) defaultDisplayName
{
  NSString *host = [[[NSProcessInfo processInfo] hostName]
                     componentsSeparatedByString: @"."][0];

  /* Samsung panels take 31 characters; others more, none less */
  return [host length] > 31 ? [host substringToIndex: 31] : host;
}

- (instancetype) initWithHost: (NSString *)host displayName: (NSString *)name
{
  self = [super init];
  if (self)
    {
      _host = [host copy];
      _name = [name copy];
      _context = [@"Scanner-" stringByAppendingString:
                   [[NSProcessInfo processInfo] globallyUniqueString]];
    }
  return self;
}

- (void) start
{
  /* Lets airscan finish looking the device up first; the printer is busy meanwhile */
  [self performSelector: @selector(startDiscovery) withObject: nil afterDelay: 5];
}

- (void) startDiscovery
{
  if (!_stopped)
    {
      [NSThread detachNewThreadSelector: @selector(discover:) toTarget: self withObject: nil];
    }
}

/* Off the main thread: WS-Discovery waits for answers */
- (void) discover: (id)unused
{
  @autoreleasepool
    {
      NSString *address = nil;
      NSUInteger attempt;

      /*
       * Right after airscan opened the device, printers answer discovery
       * late or not at all (measured with a Samsung C48x), so a few tries
       */
      for (attempt = 0; attempt < 3 && address == nil && !_stopped; attempt++)
        {
          address = [SCWSDClient scanServiceAddressForHost: _host timeout: 6];
        }
      [self performSelectorOnMainThread: @selector(discovered:) withObject: address
                          waitUntilDone: NO];
    }
}

- (void) discovered: (NSString *)address
{
  __weak SCPanelScanning *weakSelf = self;

  if (_stopped)
    {
      return;
    }
  /*
   * No WSD scanner, or one that is asleep or busy: ask again later, it costs
   * one small network message a minute while Scanner is open
   */
  if (address == nil)
    {
      [self performSelector: @selector(start) withObject: nil afterDelay: 60];
      return;
    }
  _client = [[SCWSDClient alloc] initWithScanServiceAddress: address];
  _listener = [[SCWSDEventListener alloc]
                initWithPrinterHost: _host
                            handler: ^(SCWSDScanEvent *event) {
                                [weakSelf handleEvent: event];
                              }];
  if (![_listener start])
    {
      _listener = nil;
      return;
    }
  [NSThread detachNewThreadSelector: @selector(subscribe:) toTarget: self withObject: nil];
}

- (void) subscribe: (id)unused
{
  @autoreleasepool
    {
      SCWSDSubscription *s = [_client subscribeWithDisplayName: _name
                                                       context: _context
                                                     notifyURL: [_listener notifyURL]
                                                      duration: SCRegistrationDuration
                                                         error: NULL];

      [self performSelectorOnMainThread: @selector(subscribed:) withObject: s
                          waitUntilDone: NO];
    }
}

- (void) subscribed: (SCWSDSubscription *)s
{
  if (_stopped)
    {
      if (s != nil)
        {
          [_client unsubscribe: s error: NULL];
        }
      return;
    }
  if (s == nil)
    {
      /* Refused or not answered: start over a minute later */
      [_listener stop];
      _listener = nil;
      [self performSelector: @selector(start) withObject: nil afterDelay: 60];
      return;
    }
  _subscription = s;
  [_renewal invalidate];
  _renewal = [NSTimer scheduledTimerWithTimeInterval: SCRenewalInterval
                                              target: self selector: @selector(renew:)
                                            userInfo: nil repeats: YES];
  [_delegate panelScanningDidChangeStatus: _name];
}

- (void) renew: (NSTimer *)timer
{
  [NSThread detachNewThreadSelector: @selector(renewInBackground:) toTarget: self
                         withObject: _subscription];
}

- (void) renewInBackground: (SCWSDSubscription *)s
{
  @autoreleasepool
    {
      /* A printer that was switched off meanwhile forgot us: register anew */
      if (s != nil && ![_client renew: s error: NULL] && !_stopped)
        {
          [self subscribe: nil];
        }
    }
}

- (void) handleEvent: (SCWSDScanEvent *)event
{
  SCWSDScanTicket *ticket;

  /* Another computer's destination, or a scan still running here */
  if (![[event clientContext] isEqualToString: _context] || _busy || _subscription == nil)
    {
      return;
    }
  ticket = [_delegate panelScanTicketForSource: [event inputSource]];
  if (ticket == nil)
    {
      return;
    }
  _busy = YES;
  [_delegate panelScanDidStart];
  [NSThread detachNewThreadSelector: @selector(scan:) toTarget: self
                         withObject: @[event, ticket, [_subscription destinationToken]]];
}

/* The printer waits only a few seconds for the answer, so this starts right away */
- (void) scan: (NSArray *)args
{
  @autoreleasepool
    {
      NSError *error = nil;
      NSDictionary *job = [_client createScanJobForEvent: args[0]
                                        destinationToken: args[2]
                                                  ticket: args[1]
                                                   error: &error];

      while (job != nil)
        {
          @autoreleasepool
            {
              NSData *data = [_client retrieveImageForJob: job error: &error];
              SCImage *page = data ? SCImageFromTIFFData(data, &error) : nil;

              if (page == nil)
                {
                  break;
                }
              [self performSelectorOnMainThread: @selector(deliverPage:) withObject: page
                                  waitUntilDone: NO];
            }
        }
      /* Running out of pages is how a job ends */
      if ([error code] == SCWSDNoMoreImages)
        {
          error = nil;
        }
      [self performSelectorOnMainThread: @selector(finish:)
                             withObject: error ? @[error] : @[]
                          waitUntilDone: NO];
    }
}

- (void) deliverPage: (SCImage *)page
{
  [_delegate panelScanDidDeliverPage: page];
}

- (void) finish: (NSArray *)result
{
  _busy = NO;
  [_delegate panelScanDidFinishWithError: [result firstObject]];
}

- (void) stop
{
  SCWSDSubscription *s = _subscription;

  _stopped = YES;
  [NSObject cancelPreviousPerformRequestsWithTarget: self];
  [_renewal invalidate];
  _renewal = nil;
  [_listener stop];
  _listener = nil;
  _subscription = nil;
  if (s != nil)
    {
      /* So the panel stops listing a computer that would not answer */
      [_client setTimeout: 3];
      [_client unsubscribe: s error: NULL];
    }
}

@end
