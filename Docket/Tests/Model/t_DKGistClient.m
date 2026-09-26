/* t_DKGistClient.m - ObjectTesting coverage for DKGistClient's request
 * construction, against a fake transport. Never touches the network.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "../../DKGistTransport.h"
#include "../../DKGistClient.m"

@interface DKFakeTransport : NSObject <DKGistTransport>
{
@public
  NSURLRequest *lastRequest;
  NSData *cannedData;
  NSInteger cannedStatus;
}
@end

@implementation DKFakeTransport

- (instancetype)init
{
  self = [super init];
  if (self)
    {
      cannedStatus = 200;
    }
  return self;
}

- (NSData *)sendSynchronousRequest: (NSURLRequest *)request
                  returningResponse: (NSHTTPURLResponse **)response
                              error: (NSError **)error
{
  [lastRequest release];
  lastRequest = [request retain];
  if (response != NULL)
    {
      *response = [[[NSHTTPURLResponse alloc] initWithURL: [request URL]
                                                  statusCode: cannedStatus
                                                 HTTPVersion: @"HTTP/1.1"
                                                headerFields: nil] autorelease];
    }
  return cannedData;
}

- (void)dealloc
{
  [lastRequest release];
  [cannedData release];
  [super dealloc];
}

@end

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* --- fetch: request construction --- */
  {
    DKFakeTransport *fake = [[DKFakeTransport alloc] init];
    NSString *json = @"{\"updated_at\": \"2026-09-25T12:00:00Z\", "
      @"\"files\": {\"Groceries.md\": {\"content\": \"- [ ] Buy milk\\n\"}}}";
    fake->cannedData = [[json dataUsingEncoding: NSUTF8StringEncoding] retain];

    DKGistClient *client = [[DKGistClient alloc] initWithGistId: @"abc123"
                                                            token: @"ghp_secret"
                                                        transport: fake];
    NSError *error = nil;
    NSDictionary *result = [client fetchGistWithError: &error];

    PASS(fake->lastRequest != nil, "fetch sends a request through the transport");
    PASS_EQUAL([[fake->lastRequest URL] absoluteString], @"https://api.github.com/gists/abc123",
               "fetch targets the gist's own endpoint");
    PASS_EQUAL([fake->lastRequest HTTPMethod], @"GET", "fetch uses GET");
    PASS_EQUAL([fake->lastRequest valueForHTTPHeaderField: @"Authorization"], @"token ghp_secret",
               "the token is sent as a bearer/token Authorization header");

    PASS(result != nil, "fetch parses a 200 response");
    PASS_EQUAL([result objectForKey: @"updated_at"], @"2026-09-25T12:00:00Z", "updated_at is exposed for conflict detection");
    NSDictionary *files = [result objectForKey: @"files"];
    PASS_EQUAL([files objectForKey: @"Groceries.md"], @"- [ ] Buy milk\n", "file content is extracted from the GitHub response shape");

    [client release];
    [fake release];
  }

  /* --- fetch: non-200 is reported as an error, not silently empty --- */
  {
    DKFakeTransport *fake = [[DKFakeTransport alloc] init];
    fake->cannedStatus = 404;
    fake->cannedData = [[@"{\"message\": \"Not Found\"}" dataUsingEncoding: NSUTF8StringEncoding] retain];

    DKGistClient *client = [[DKGistClient alloc] initWithGistId: @"missing"
                                                            token: @"t"
                                                        transport: fake];
    NSError *error = nil;
    NSDictionary *result = [client fetchGistWithError: &error];

    PASS(result == nil, "a 404 yields no result");
    PASS(error != nil, "a 404 is reported as an error");

    [client release];
    [fake release];
  }

  /* --- update: request construction --- */
  {
    DKFakeTransport *fake = [[DKFakeTransport alloc] init];
    fake->cannedData = [[@"{\"updated_at\": \"2026-09-25T13:00:00Z\"}" dataUsingEncoding: NSUTF8StringEncoding] retain];

    DKGistClient *client = [[DKGistClient alloc] initWithGistId: @"abc123"
                                                            token: @"ghp_secret"
                                                        transport: fake];
    NSError *error = nil;
    NSDictionary *files = [NSDictionary dictionaryWithObject: @"- [x] Buy milk\n" forKey: @"Groceries.md"];
    BOOL ok = [client updateGistFiles: files error: &error];

    PASS(ok == YES, "update reports success on a 200 response");
    PASS_EQUAL([fake->lastRequest HTTPMethod], @"PATCH", "update uses PATCH");
    PASS_EQUAL([[fake->lastRequest URL] absoluteString], @"https://api.github.com/gists/abc123",
               "update targets the same gist endpoint");

    NSError *jsonError = nil;
    id body = [NSJSONSerialization JSONObjectWithData: [fake->lastRequest HTTPBody]
                                               options: 0
                                                 error: &jsonError];
    PASS(jsonError == nil, "the request body is valid JSON");
    NSDictionary *sentFiles = [body objectForKey: @"files"];
    NSDictionary *groceries = [sentFiles objectForKey: @"Groceries.md"];
    PASS_EQUAL([groceries objectForKey: @"content"], @"- [x] Buy milk\n",
               "the body carries exactly the file content that was asked to be written");

    [client release];
    [fake release];
  }

  [arp release];
  return 0;
}
