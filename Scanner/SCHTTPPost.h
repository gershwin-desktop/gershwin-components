/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/*
 * A blocking HTTP/1.1 POST (RFC 9112) for talking SOAP to printers.
 * GNUstep's NSURLConnection leaves the chunk framing inside multipart
 * answers, and that is how printers send scanned pages. So the transfer is
 * done here, with the framing decoded as the standard says.
 */

@interface SCHTTPResponse : NSObject
@property (nonatomic) NSInteger statusCode;
/* Field names in lower case; repeated fields joined with ", " */
@property (nonatomic, copy) NSDictionary *headers;
@property (nonatomic, copy) NSData *body;

/*
 * The final response in raw, the bytes as received so far: nil while it is
 * incomplete, or when it is malformed (then *malformed is YES). At the end of
 * the stream, a body without a length ends there (RFC 9112 6.3).
 */
+ (SCHTTPResponse *) responseFromData: (NSData *)raw
                          endOfStream: (BOOL)eof
                            malformed: (BOOL *)malformed;
@end

@interface SCHTTPPost : NSObject

/*
 * The content of a chunked body (RFC 9112 7.1) starting at data's first
 * byte: nil while incomplete or when malformed (then *malformed is YES).
 * *consumed is set to the length of the whole chunked body including trailers.
 */
+ (NSData *) dataByDecodingChunks: (NSData *)data
                         consumed: (NSUInteger *)consumed
                        malformed: (BOOL *)malformed;

+ (SCHTTPResponse *) post: (NSData *)body
              contentType: (NSString *)contentType
                       to: (NSURL *)url
                  timeout: (NSTimeInterval)timeout
                    error: (NSError **)error;

@end
