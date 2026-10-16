/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "TDURLConnectionTransport.h"

@implementation TDURLConnectionTransport

- (NSData *)sendSynchronousRequest: (NSURLRequest *)request
                  returningResponse: (NSHTTPURLResponse **)response
                              error: (NSError **)error
{
  return [NSURLConnection sendSynchronousRequest: request
                                returningResponse: response
                                            error: error];
}

@end
