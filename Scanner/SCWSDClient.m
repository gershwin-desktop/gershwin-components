/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCWSDClient.h"
#import "SCHTTPPost.h"
#import "SCImageBuilder.h"
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>

static NSString * const SCAddressingNS = @"http://schemas.xmlsoap.org/ws/2004/08/addressing";
static NSString * const SCAnonymous
  = @"http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous";
static NSString * const SCScanNS = @"http://schemas.microsoft.com/windows/2006/08/wdp/scan";

@implementation SCWSDScanEvent
@end

@implementation SCWSDSubscription
@end

@implementation SCWSDScanTicket
@end

static NSError *
SCWSDError(NSInteger code, NSString *reason)
{
  return [NSError errorWithDomain: SCScannerErrorDomain code: code
                         userInfo: @{NSLocalizedDescriptionKey:
                                       [NSString stringWithFormat:
                                         @"Scanning from the printer's panel failed: %@",
                                         reason]}];
}

static NSString *
SCEscape(NSString *s)
{
  NSMutableString *m = [[s ? s : @"" description] mutableCopy];

  [m replaceOccurrencesOfString: @"&" withString: @"&amp;" options: 0
                          range: NSMakeRange(0, [m length])];
  [m replaceOccurrencesOfString: @"<" withString: @"&lt;" options: 0
                          range: NSMakeRange(0, [m length])];
  [m replaceOccurrencesOfString: @">" withString: @"&gt;" options: 0
                          range: NSMakeRange(0, [m length])];
  return m;
}

static NSString *
SCNewMessageID(void)
{
  return [@"urn:uuid:" stringByAppendingString:
           [[[NSProcessInfo processInfo] globallyUniqueString] lowercaseString]];
}

/* A SOAP 1.2 envelope with WS-Addressing headers, as every WSD message is */
static NSString *
SCEnvelope(NSString *to, NSString *action, NSString *extraHeaders, NSString *body)
{
  return [NSString stringWithFormat:
    @"<?xml version=\"1.0\" encoding=\"utf-8\"?>"
    @"<soap:Envelope xmlns:soap=\"http://www.w3.org/2003/05/soap-envelope\" "
    @"xmlns:wsa=\"%@\" xmlns:wse=\"http://schemas.xmlsoap.org/ws/2004/08/eventing\" "
    @"xmlns:wscn=\"%@\"><soap:Header><wsa:To>%@</wsa:To><wsa:Action>%@</wsa:Action>"
    @"<wsa:MessageID>%@</wsa:MessageID><wsa:ReplyTo><wsa:Address>%@</wsa:Address>"
    @"</wsa:ReplyTo>%@</soap:Header><soap:Body>%@</soap:Body></soap:Envelope>",
    SCAddressingNS, SCScanNS, SCEscape(to), action, SCNewMessageID(), SCAnonymous,
    extraHeaders ? extraHeaders : @"", body];
}

@implementation SCWSDClient
{
  NSString *_address;
  NSTimeInterval _timeout;
}

- (void) setTimeout: (NSTimeInterval)seconds
{
  _timeout = seconds;
}

#pragma mark Reading what the printer sent

+ (NSArray *) valuesOfElement: (NSString *)localName inXML: (NSString *)xml
{
  NSString *pattern = [NSString stringWithFormat:
    @"<(?:[A-Za-z0-9_.-]+:)?%@(?:\\s[^>]*)?>([^<]*)<", localName];
  NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern: pattern
                                                                      options: 0
                                                                        error: NULL];
  NSMutableArray *values = [NSMutableArray array];

  if (xml == nil)
    {
      return values;
    }
  for (NSTextCheckingResult *m in [re matchesInString: xml options: 0
                                                range: NSMakeRange(0, [xml length])])
    {
      [values addObject: [[xml substringWithRange: [m rangeAtIndex: 1]]
                           stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    }
  return values;
}

+ (NSString *) valueOfElement: (NSString *)localName inXML: (NSString *)xml
{
  NSArray *values = [self valuesOfElement: localName inXML: xml];

  return [values count] ? [values objectAtIndex: 0] : nil;
}

+ (NSString *) faultInResponse: (NSData *)data
{
  NSString *text = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];

  /*
   * An image answer is binary and no valid text; asking nil for "Fault"
   * would claim it was found (location 0), and the image would be lost
   */
  if (text == nil || [text rangeOfString: @"Fault"].location == NSNotFound
      || [text rangeOfString: @"Envelope"].location == NSNotFound)
    {
      return nil;
    }
  return text;
}

+ (NSString *) scanServiceAddressInMetadata: (NSString *)metadata
{
  /* Each hosted service lists its address, then its types */
  NSArray *hosted = [metadata componentsSeparatedByString: @"Hosted>"];

  for (NSString *part in hosted)
    {
      if ([part rangeOfString: @"ScannerServiceType"].location != NSNotFound)
        {
          return [self valueOfElement: @"Address" inXML: part];
        }
    }
  return nil;
}

+ (SCWSDScanEvent *) scanEventFromXML: (NSString *)xml
{
  SCWSDScanEvent *event;

  if ([xml rangeOfString: @"ScanAvailableEvent"].location == NSNotFound)
    {
      return nil;
    }
  event = [SCWSDScanEvent new];
  [event setScanIdentifier: [self valueOfElement: @"ScanIdentifier" inXML: xml]];
  [event setInputSource: [self valueOfElement: @"InputSource" inXML: xml]];
  [event setClientContext: [self valueOfElement: @"ClientContext" inXML: xml]];
  return [[event scanIdentifier] length] ? event : nil;
}

+ (SCWSDSubscription *) subscriptionFromResponse: (NSString *)xml
{
  SCWSDSubscription *s;
  NSRange manager = [xml rangeOfString: @"SubscriptionManager>"];

  if (manager.location == NSNotFound)
    {
      return nil;
    }
  s = [SCWSDSubscription new];
  [s setManagerAddress: [self valueOfElement: @"Address"
                                       inXML: [xml substringFromIndex: manager.location]]];
  [s setIdentifier: [self valueOfElement: @"Identifier" inXML: xml]];
  [s setDestinationToken: [self valueOfElement: @"DestinationToken" inXML: xml]];
  return ([[s managerAddress] length] && [[s identifier] length]) ? s : nil;
}

/* Position of a byte sequence in data, from start; NSNotFound when absent */
static NSUInteger
SCFind(NSData *data, NSData *needle, NSUInteger start)
{
  NSRange r = [data rangeOfData: needle options: 0
                          range: NSMakeRange(start, [data length] - start)];

  return r.location;
}

+ (NSData *) imageFromMTOMBody: (NSData *)body contentType: (NSString *)contentType
{
  NSRange b = [contentType rangeOfString: @"boundary="];
  NSString *boundary;
  NSData *delimiter, *headerEnd = [@"\r\n\r\n" dataUsingEncoding: NSASCIIStringEncoding];
  NSUInteger pos;

  if (b.location == NSNotFound)
    {
      return nil;
    }
  boundary = [contentType substringFromIndex: NSMaxRange(b)];
  boundary = [[boundary componentsSeparatedByString: @";"] objectAtIndex: 0];
  boundary = [boundary stringByTrimmingCharactersInSet:
               [NSCharacterSet characterSetWithCharactersInString: @"\" "]];
  delimiter = [[@"--" stringByAppendingString: boundary]
                dataUsingEncoding: NSASCIIStringEncoding];

  pos = SCFind(body, delimiter, 0);
  while (pos != NSNotFound)
    {
      NSUInteger partStart = pos + [delimiter length];
      NSUInteger headersEnd = SCFind(body, headerEnd, partStart);
      NSUInteger next;
      NSString *headers;
      NSUInteger end;

      if (headersEnd == NSNotFound)
        {
          break;
        }
      next = SCFind(body, delimiter, headersEnd);
      if (next == NSNotFound)
        {
          break;
        }
      headers = [[[NSString alloc] initWithData:
                    [body subdataWithRange: NSMakeRange(partStart, headersEnd - partStart)]
                                       encoding: NSISOLatin1StringEncoding]
                  lowercaseString];
      /* The XML part describes, the other one is the image itself */
      if ([headers rangeOfString: @"application/xop+xml"].location == NSNotFound
          && [headers rangeOfString: @"content-type"].location != NSNotFound)
        {
          end = next;
          /* The line break before the next delimiter belongs to the framing */
          if (end >= 2 && ((const char *)[body bytes])[end - 2] == '\r')
            {
              end -= 2;
            }
          return [body subdataWithRange: NSMakeRange(headersEnd + 4,
                                                     end - headersEnd - 4)];
        }
      pos = next;
    }
  return nil;
}

#pragma mark Talking to the printer

/* POSTs a SOAP message; returns the body, and the content type for MTOM answers */
- (NSData *) post: (NSString *)envelope to: (NSString *)address
      contentType: (NSString **)contentType error: (NSError **)error
{
  NSError *httpError = nil;
  SCHTTPResponse *response = [SCHTTPPost post: [envelope dataUsingEncoding: NSUTF8StringEncoding]
                                  contentType: @"application/soap+xml; charset=utf-8"
                                           to: [NSURL URLWithString: address]
                                      timeout: _timeout > 0 ? _timeout : 30
                                        error: &httpError];
  NSData *data = [response body];
  NSString *text;

  if (contentType)
    {
      *contentType = [[response headers] objectForKey: @"content-type"];
    }
  if (data == nil)
    {
      if (error)
        {
          *error = SCWSDError(SCWSDProtocolError,
                              httpError ? [httpError localizedDescription]
                                        : @"the printer did not answer.");
        }
      return nil;
    }
  text = [SCWSDClient faultInResponse: data];
  if (text != nil)
    {
      NSArray *codes = [SCWSDClient valuesOfElement: @"Value" inXML: text];
      NSString *code = [codes lastObject];
      NSString *reason = [SCWSDClient valueOfElement: @"Text" inXML: text];
      NSString *action = [[[SCWSDClient valueOfElement: @"Action" inXML: envelope]
                            componentsSeparatedByString: @"/"] lastObject];

      if (![code hasSuffix: @"ClientErrorNoImagesAvailable"])
        {
          /* What the printer objected to, for finding out why */
          NSLog(@"WSD %@ refused by %@ (HTTP %ld): %@", action, address,
                (long)[response statusCode],
                [text length] > 4000 ? [text substringToIndex: 4000] : text);
        }
      if (error)
        {
          *error = SCWSDError([code hasSuffix: @"ClientErrorNoImagesAvailable"]
                              ? SCWSDNoMoreImages : SCWSDProtocolError,
                              [NSString stringWithFormat: @"%@ was refused (%@%@).",
                                        action ? action : @"a request",
                                        code ? code : @"no reason given",
                                        reason ? [@": " stringByAppendingString: reason] : @""]);
        }
      return nil;
    }
  if ([response statusCode] >= 400)
    {
      NSLog(@"WSD request to %@ failed with HTTP %ld", address, (long)[response statusCode]);
      if (error)
        {
          *error = SCWSDError(SCWSDProtocolError, [NSString stringWithFormat:
            @"the printer answered with HTTP error %ld.", (long)[response statusCode]]);
        }
      return nil;
    }
  return data;
}

- (NSString *) postText: (NSString *)envelope to: (NSString *)address
                  error: (NSError **)error
{
  NSData *data = [self post: envelope to: address contentType: NULL error: error];

  return data ? [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding] : nil;
}

+ (NSString *) scanServiceAddressForHost: (NSString *)host
                                 timeout: (NSTimeInterval)timeout
{
  NSString *probe = [NSString stringWithFormat:
    @"<?xml version=\"1.0\" encoding=\"utf-8\"?>"
    @"<soap:Envelope xmlns:soap=\"http://www.w3.org/2003/05/soap-envelope\" "
    @"xmlns:wsa=\"%@\" xmlns:wsd=\"http://schemas.xmlsoap.org/ws/2005/04/discovery\" "
    @"xmlns:wscn=\"%@\"><soap:Header>"
    @"<wsa:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</wsa:To>"
    @"<wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</wsa:Action>"
    @"<wsa:MessageID>%@</wsa:MessageID></soap:Header><soap:Body><wsd:Probe>"
    @"<wsd:Types>wscn:ScanDeviceType</wsd:Types></wsd:Probe></soap:Body></soap:Envelope>",
    SCAddressingNS, SCScanNS, SCNewMessageID()];
  NSData *probeData = [probe dataUsingEncoding: NSUTF8StringEncoding];
  struct sockaddr_in group;
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: timeout];
  NSString *endpoint = nil, *xaddr = nil, *metadata;
  int s = socket(AF_INET, SOCK_DGRAM, 0);
  unsigned char ttl = 1;

  if (s < 0)
    {
      return nil;
    }
  /* WS-Discovery: everyone on the local network answers a multicast probe */
  setsockopt(s, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl));
  memset(&group, 0, sizeof(group));
  group.sin_family = AF_INET;
  group.sin_port = htons(3702);
  group.sin_addr.s_addr = inet_addr("239.255.255.250");
  sendto(s, [probeData bytes], [probeData length], 0,
         (struct sockaddr *)&group, sizeof(group));
  /*
   * Also straight to the printer: while airscan talks to it, a Samsung C48x
   * ignored the multicast probe but always answered a directed one
   */
  {
    struct sockaddr_in direct = group;

    if (inet_pton(AF_INET, [host UTF8String], &direct.sin_addr) == 1)
      {
        sendto(s, [probeData bytes], [probeData length], 0,
               (struct sockaddr *)&direct, sizeof(direct));
      }
  }

  while (xaddr == nil && [deadline timeIntervalSinceNow] > 0)
    {
      char buffer[65536];
      struct sockaddr_in from;
      socklen_t fromLength = sizeof(from);
      struct timeval tv;
      fd_set fds;
      ssize_t n;
      NSString *answer;
      char ip[INET_ADDRSTRLEN];

      FD_ZERO(&fds);
      FD_SET(s, &fds);
      tv.tv_sec = 0;
      tv.tv_usec = 250000;
      if (select(s + 1, &fds, NULL, NULL, &tv) <= 0)
        {
          continue;
        }
      n = recvfrom(s, buffer, sizeof(buffer) - 1, 0,
                   (struct sockaddr *)&from, &fromLength);
      if (n <= 0)
        {
          continue;
        }
      inet_ntop(AF_INET, &from.sin_addr, ip, sizeof(ip));
      if (![[NSString stringWithUTF8String: ip] isEqualToString: host])
        {
          continue;
        }
      answer = [[NSString alloc] initWithBytes: buffer length: n
                                      encoding: NSUTF8StringEncoding];
      endpoint = [self valueOfElement: @"Address" inXML: answer];
      xaddr = [[[self valueOfElement: @"XAddrs" inXML: answer]
                 componentsSeparatedByString: @" "] objectAtIndex: 0];
    }
  close(s);
  if (xaddr == nil || endpoint == nil)
    {
      return nil;
    }

  /* The device's metadata names its services and their addresses */
  metadata = [[SCWSDClient new] postText:
                SCEnvelope(endpoint, @"http://schemas.xmlsoap.org/ws/2004/09/transfer/Get",
                           nil, @"")
                                       to: xaddr error: NULL];
  return [self scanServiceAddressInMetadata: metadata];
}

- (instancetype) initWithScanServiceAddress: (NSString *)address
{
  self = [super init];
  if (self)
    {
      _address = [address copy];
    }
  return self;
}

- (NSString *) scanServiceAddress
{
  return _address;
}

static NSString *
SCDuration(NSTimeInterval seconds)
{
  return [NSString stringWithFormat: @"PT%luS", (unsigned long)seconds];
}

- (SCWSDSubscription *) subscribeWithDisplayName: (NSString *)name
                                         context: (NSString *)context
                                       notifyURL: (NSString *)notifyURL
                                        duration: (NSTimeInterval)duration
                                           error: (NSError **)error
{
  NSString *body = [NSString stringWithFormat:
    @"<wse:Subscribe><wse:EndTo><wsa:Address>%@</wsa:Address></wse:EndTo>"
    @"<wse:Delivery Mode=\"http://schemas.xmlsoap.org/ws/2004/08/eventing/DeliveryModes/Push\">"
    @"<wse:NotifyTo><wsa:Address>%@</wsa:Address></wse:NotifyTo></wse:Delivery>"
    @"<wse:Expires>%@</wse:Expires>"
    @"<wse:Filter Dialect=\"http://schemas.xmlsoap.org/ws/2006/02/devprof/Action\">"
    @"%@/ScanAvailableEvent</wse:Filter><wscn:ScanDestinations><wscn:ScanDestination>"
    @"<wscn:ClientDisplayName>%@</wscn:ClientDisplayName>"
    @"<wscn:ClientContext>%@</wscn:ClientContext></wscn:ScanDestination>"
    @"</wscn:ScanDestinations></wse:Subscribe>",
    SCEscape(notifyURL), SCEscape(notifyURL), SCDuration(duration), SCScanNS,
    SCEscape(name), SCEscape(context)];
  NSString *answer = [self postText:
                         SCEnvelope(_address,
                                    @"http://schemas.xmlsoap.org/ws/2004/08/eventing/Subscribe",
                                    nil, body)
                                 to: _address error: error];
  SCWSDSubscription *s = answer ? [SCWSDClient subscriptionFromResponse: answer] : nil;

  if (answer != nil && s == nil && error)
    {
      *error = SCWSDError(SCWSDProtocolError, @"the printer did not accept Scanner.");
    }
  [s setDuration: duration];
  return s;
}

- (NSString *) managedEnvelope: (SCWSDSubscription *)s action: (NSString *)action
                          body: (NSString *)body
{
  return SCEnvelope([s managerAddress],
                    [@"http://schemas.xmlsoap.org/ws/2004/08/eventing/"
                      stringByAppendingString: action],
                    [NSString stringWithFormat: @"<wse:Identifier>%@</wse:Identifier>",
                              SCEscape([s identifier])],
                    body);
}

- (BOOL) renew: (SCWSDSubscription *)s error: (NSError **)error
{
  NSString *body = [NSString stringWithFormat:
    @"<wse:Renew><wse:Expires>%@</wse:Expires></wse:Renew>", SCDuration([s duration])];

  return [self postText: [self managedEnvelope: s action: @"Renew" body: body]
                     to: [s managerAddress] error: error] != nil;
}

- (BOOL) unsubscribe: (SCWSDSubscription *)s error: (NSError **)error
{
  return [self postText: [self managedEnvelope: s action: @"Unsubscribe"
                                          body: @"<wse:Unsubscribe/>"]
                     to: [s managerAddress] error: error] != nil;
}

+ (NSString *) createScanJobBodyForEvent: (SCWSDScanEvent *)event
                        destinationToken: (NSString *)token
                                  ticket: (SCWSDScanTicket *)ticket
                                      to: (NSString *)address
{
  NSRect r = [ticket region];
  BOOL feeder = ![[ticket inputSource] isEqualToString: @"Platen"];
  NSString *body = [NSString stringWithFormat:
    @"<wscn:CreateScanJobRequest><wscn:ScanIdentifier>%@</wscn:ScanIdentifier>"
    @"<wscn:DestinationToken>%@</wscn:DestinationToken><wscn:ScanTicket>"
    @"<wscn:JobDescription><wscn:JobName>Scanner</wscn:JobName>"
    @"<wscn:JobOriginatingUserName>%@</wscn:JobOriginatingUserName>"
    @"</wscn:JobDescription><wscn:DocumentParameters>"
    /* Uncompressed TIFF: lossless, and the only other format offered is JPEG */
    @"<wscn:Format>tiff-single-uncompressed</wscn:Format>"
    /* 0 takes every sheet in the feeder, the flatbed holds one */
    @"<wscn:ImagesToTransfer>%d</wscn:ImagesToTransfer>"
    @"<wscn:InputSource>%@</wscn:InputSource>"
    @"<wscn:InputSize><wscn:InputMediaSize><wscn:Width>%d</wscn:Width>"
    @"<wscn:Height>%d</wscn:Height></wscn:InputMediaSize></wscn:InputSize>"
    @"<wscn:MediaSides><wscn:MediaFront><wscn:ScanRegion>"
    @"<wscn:ScanRegionXOffset>%d</wscn:ScanRegionXOffset>"
    @"<wscn:ScanRegionYOffset>%d</wscn:ScanRegionYOffset>"
    @"<wscn:ScanRegionWidth>%d</wscn:ScanRegionWidth>"
    @"<wscn:ScanRegionHeight>%d</wscn:ScanRegionHeight></wscn:ScanRegion>"
    @"<wscn:ColorProcessing>%@</wscn:ColorProcessing><wscn:Resolution>"
    @"<wscn:Width>%lu</wscn:Width><wscn:Height>%lu</wscn:Height></wscn:Resolution>"
    @"</wscn:MediaFront></wscn:MediaSides></wscn:DocumentParameters></wscn:ScanTicket>"
    @"</wscn:CreateScanJobRequest>",
    SCEscape([event scanIdentifier]), SCEscape(token), SCEscape(NSUserName()),
    feeder ? 0 : 1, SCEscape([ticket inputSource]),
    (int)NSWidth(r), (int)NSHeight(r), (int)NSMinX(r), (int)NSMinY(r),
    (int)NSWidth(r), (int)NSHeight(r), SCEscape([ticket colorProcessing]),
    (unsigned long)[ticket resolution], (unsigned long)[ticket resolution]];

  return SCEnvelope(address, [SCScanNS stringByAppendingString: @"/CreateScanJob"],
                    nil, body);
}

- (NSDictionary *) createScanJobForEvent: (SCWSDScanEvent *)event
                        destinationToken: (NSString *)token
                                  ticket: (SCWSDScanTicket *)ticket
                                   error: (NSError **)error
{
  NSString *answer = [self postText: [SCWSDClient createScanJobBodyForEvent: event
                                                            destinationToken: token
                                                                      ticket: ticket
                                                                          to: _address]
                                 to: _address error: error];
  NSString *jobId = [SCWSDClient valueOfElement: @"JobId" inXML: answer];
  NSString *jobToken = [SCWSDClient valueOfElement: @"JobToken" inXML: answer];

  if (answer == nil)
    {
      return nil;
    }
  if (jobId == nil || jobToken == nil)
    {
      if (error)
        {
          *error = SCWSDError(SCWSDProtocolError, @"the printer did not start the scan.");
        }
      return nil;
    }
  return @{@"JobId": jobId, @"JobToken": jobToken};
}

- (NSData *) retrieveImageForJob: (NSDictionary *)job error: (NSError **)error
{
  NSString *body = [NSString stringWithFormat:
    @"<wscn:RetrieveImageRequest><wscn:JobId>%@</wscn:JobId>"
    @"<wscn:JobToken>%@</wscn:JobToken><wscn:DocumentDescription>"
    @"<wscn:DocumentName>Scanner</wscn:DocumentName></wscn:DocumentDescription>"
    @"</wscn:RetrieveImageRequest>",
    SCEscape([job objectForKey: @"JobId"]), SCEscape([job objectForKey: @"JobToken"])];
  NSString *contentType = nil;
  NSData *answer = [self post: SCEnvelope(_address,
                                          [SCScanNS stringByAppendingString: @"/RetrieveImage"],
                                          nil, body)
                           to: _address contentType: &contentType error: error];
  NSData *image;

  if (answer == nil)
    {
      return nil;
    }
  image = [SCWSDClient imageFromMTOMBody: answer contentType: contentType];
  if (image == nil && error)
    {
      *error = SCWSDError(SCWSDProtocolError, @"the printer sent no image.");
    }
  return image;
}

@end
