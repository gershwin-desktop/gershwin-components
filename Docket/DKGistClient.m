/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DKGistClient.h"

NSString * const DKGistClientErrorDomain = @"DKGistClientErrorDomain";

static NSError *
DKError(NSInteger code, NSString *message)
{
  return [NSError errorWithDomain: DKGistClientErrorDomain
                              code: code
                          userInfo: [NSDictionary dictionaryWithObject: message
                                                                 forKey: NSLocalizedDescriptionKey]];
}

@implementation DKGistClient

- (instancetype)initWithGistId: (NSString *)gistId
                          token: (NSString *)token
                      transport: (id <DKGistTransport>)transport
{
  self = [super init];
  if (self)
    {
      _gistId = [gistId copy];
      _token = [token copy];
      _transport = [transport retain];
    }
  return self;
}

- (void)dealloc
{
  [_gistId release];
  [_token release];
  [_transport release];
  [super dealloc];
}

- (NSMutableURLRequest *)requestForMethod: (NSString *)method
{
  NSString *urlString = [NSString stringWithFormat: @"https://api.github.com/gists/%@", _gistId];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL: [NSURL URLWithString: urlString]];

  [request setHTTPMethod: method];
  [request setValue: @"application/vnd.github+json" forHTTPHeaderField: @"Accept"];
  [request setValue: [NSString stringWithFormat: @"token %@", _token] forHTTPHeaderField: @"Authorization"];
  [request setValue: @"Docket/1.0" forHTTPHeaderField: @"User-Agent"];
  [request setValue: @"2022-11-28" forHTTPHeaderField: @"X-GitHub-Api-Version"];
  [request setTimeoutInterval: 30.0];
  return request;
}

- (NSDictionary *)fetchGistWithError: (NSError **)error
{
  NSMutableURLRequest *request = [self requestForMethod: @"GET"];
  NSHTTPURLResponse *response = nil;
  NSError *connError = nil;
  NSData *data = [_transport sendSynchronousRequest: request
                                   returningResponse: &response
                                               error: &connError];
  id json;
  NSDictionary *rawFiles;
  NSMutableDictionary *files;
  NSString *updatedAt;

  if (data == nil)
    {
      if (error != NULL)
        {
          *error = (connError != nil) ? connError : DKError(-1, @"No response fetching the gist");
        }
      return nil;
    }

  if ([response statusCode] != 200)
    {
      if (error != NULL)
        {
          NSString *msg = [NSString stringWithFormat:
            @"GitHub returned HTTP %ld fetching the gist", (long)[response statusCode]];
          *error = DKError([response statusCode], msg);
        }
      return nil;
    }

  json = [NSJSONSerialization JSONObjectWithData: data options: 0 error: error];
  if (![json isKindOfClass: [NSDictionary class]])
    {
      if (error != NULL && *error == nil)
        {
          *error = DKError(-2, @"Gist response was not a JSON object");
        }
      return nil;
    }

  rawFiles = [(NSDictionary *)json objectForKey: @"files"];
  files = [NSMutableDictionary dictionary];
  for (NSString *filename in rawFiles)
    {
      NSDictionary *fileInfo = [rawFiles objectForKey: filename];
      NSString *content = [fileInfo objectForKey: @"content"];

      if (content != nil)
        {
          [files setObject: content forKey: filename];
        }
    }

  updatedAt = [(NSDictionary *)json objectForKey: @"updated_at"];
  return [NSDictionary dictionaryWithObjectsAndKeys:
            files, @"files",
            (updatedAt != nil ? updatedAt : @""), @"updated_at",
            nil];
}

- (BOOL)updateGistFiles: (NSDictionary *)filenameToContent
                   error: (NSError **)error
{
  NSMutableDictionary *filesPayload = [NSMutableDictionary dictionary];
  NSDictionary *payload;
  NSData *body;
  NSMutableURLRequest *request;
  NSHTTPURLResponse *response = nil;
  NSError *connError = nil;
  NSData *data;

  for (NSString *filename in filenameToContent)
    {
      NSDictionary *contentDict = [NSDictionary dictionaryWithObject: [filenameToContent objectForKey: filename]
                                                                forKey: @"content"];
      [filesPayload setObject: contentDict forKey: filename];
    }
  payload = [NSDictionary dictionaryWithObject: filesPayload forKey: @"files"];
  body = [NSJSONSerialization dataWithJSONObject: payload options: 0 error: error];
  if (body == nil)
    {
      return NO;
    }

  request = [self requestForMethod: @"PATCH"];
  [request setValue: @"application/json" forHTTPHeaderField: @"Content-Type"];
  [request setHTTPBody: body];

  data = [_transport sendSynchronousRequest: request
                          returningResponse: &response
                                      error: &connError];

  if (data == nil || [response statusCode] != 200)
    {
      if (error != NULL)
        {
          NSString *msg = [NSString stringWithFormat:
            @"GitHub returned HTTP %ld updating the gist", (long)[response statusCode]];
          *error = (connError != nil) ? connError : DKError([response statusCode], msg);
        }
      return NO;
    }

  return YES;
}

@end
