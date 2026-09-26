/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DKURLConnectionTransport.h"

@implementation DKURLConnectionTransport

- (NSData *)sendSynchronousRequest: (NSURLRequest *)request
                  returningResponse: (NSHTTPURLResponse **)response
                              error: (NSError **)error
{
  return [NSURLConnection sendSynchronousRequest: request
                                returningResponse: response
                                            error: error];
}

@end
