/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/*
 * Seam between DKGistClient and the network, so a test can supply a fake
 * that records the NSURLRequest it was asked to send and hands back a
 * canned response, without ever touching a real socket. The production
 * implementation (DKURLConnectionTransport) is a one-line wrapper around
 * +[NSURLConnection sendSynchronousRequest:returningResponse:error:].
 */
@protocol DKGistTransport <NSObject>

- (NSData *)sendSynchronousRequest: (NSURLRequest *)request
                  returningResponse: (NSHTTPURLResponse **)response
                              error: (NSError **)error;

@end
