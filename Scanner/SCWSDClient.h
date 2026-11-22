/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/*
 * Scanning started from a printer's own panel, through WSD (WS-Scan, the
 * standard behind "Scan to computer" on HP, Brother, Canon, Epson and
 * Samsung devices): Scanner registers as a destination, the printer lists
 * it on its panel, and when someone picks it and presses Start the printer
 * notifies Scanner, which then fetches the pages. All calls are blocking
 * SOAP requests; run them off the main thread.
 */

/* What a printer's notification says about a scan waiting at its panel */
@interface SCWSDScanEvent : NSObject
@property (nonatomic, copy) NSString *scanIdentifier;
@property (nonatomic, copy) NSString *inputSource;   /* "Platen", "ADF", ... */
@property (nonatomic, copy) NSString *clientContext;
@end

/* A registration as a scan destination; it expires unless renewed */
@interface SCWSDSubscription : NSObject
@property (nonatomic, copy) NSString *managerAddress;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *destinationToken;
@property (nonatomic) NSTimeInterval duration;
@end

/* How to scan a job: what the user set in Scanner */
@interface SCWSDScanTicket : NSObject
@property (nonatomic, copy) NSString *inputSource;
/* "RGB24", "Grayscale8" or "BlackAndWhite1" */
@property (nonatomic, copy) NSString *colorProcessing;
@property (nonatomic) NSUInteger resolution;
/* In thousandths of an inch, as WS-Scan measures; zero size means the whole area */
@property (nonatomic) NSRect region;
@end

/* Error codes beyond the HTTP ones */
enum
{
  SCWSDNoMoreImages = 200,  /* the job delivered all its pages */
  SCWSDProtocolError = 201
};

@interface SCWSDClient : NSObject

/* The scan service of a WSD device at host (an IP address), or nil; blocking for timeout */
+ (NSString *) scanServiceAddressForHost: (NSString *)host
                                 timeout: (NSTimeInterval)timeout;

- (instancetype) initWithScanServiceAddress: (NSString *)address;
- (NSString *) scanServiceAddress;

/* Seconds to wait for each answer; 30 unless set (shorter when quitting) */
- (void) setTimeout: (NSTimeInterval)seconds;

- (SCWSDSubscription *) subscribeWithDisplayName: (NSString *)name
                                         context: (NSString *)context
                                       notifyURL: (NSString *)notifyURL
                                        duration: (NSTimeInterval)duration
                                           error: (NSError **)error;
- (BOOL) renew: (SCWSDSubscription *)subscription error: (NSError **)error;
- (BOOL) unsubscribe: (SCWSDSubscription *)subscription error: (NSError **)error;

/* Answers a panel scan; returns @{@"JobId", @"JobToken"} */
- (NSDictionary *) createScanJobForEvent: (SCWSDScanEvent *)event
                        destinationToken: (NSString *)token
                                  ticket: (SCWSDScanTicket *)ticket
                                   error: (NSError **)error;

/* The next page of a job as image file data, nil with SCWSDNoMoreImages at the end */
- (NSData *) retrieveImageForJob: (NSDictionary *)job error: (NSError **)error;

/* The parts below work on text the printer sent, so they can be tested with it */

/* Text of the first element with this local name, whatever its namespace prefix */
+ (NSString *) valueOfElement: (NSString *)localName inXML: (NSString *)xml;
+ (NSString *) scanServiceAddressInMetadata: (NSString *)metadata;
+ (SCWSDScanEvent *) scanEventFromXML: (NSString *)xml;
+ (SCWSDSubscription *) subscriptionFromResponse: (NSString *)xml;
/* The SOAP fault in an answer, or nil; image answers are binary and never one */
+ (NSString *) faultInResponse: (NSData *)data;
/* The binary part of an MTOM (multipart/related) answer */
+ (NSData *) imageFromMTOMBody: (NSData *)body contentType: (NSString *)contentType;
+ (NSString *) createScanJobBodyForEvent: (SCWSDScanEvent *)event
                        destinationToken: (NSString *)token
                                  ticket: (SCWSDScanTicket *)ticket
                                      to: (NSString *)address;

@end
