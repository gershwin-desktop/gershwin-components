/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "RadioBrowser.h"
#import "PlayerAsync.h"
#import "RadioStation.h"

@interface RadioBrowser ()
{
@private
    NSString *_baseURL;
}
@end

@implementation RadioBrowser

+ (instancetype)sharedBrowser
{
    static RadioBrowser *shared = nil;
    @synchronized(self) {
        if (shared == nil) {
            shared = [[self alloc] init];
        }
    }
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _baseURL = [@"https://opml.radiotime.com" retain];
    }
    return self;
}

- (void)dealloc
{
    [_baseURL release];
    [super dealloc];
}

#pragma mark - Status

- (void)checkStatusWithCompletion:(void(^)(BOOL available))completion
{
    [self performRequest:@"Browse.ashx"
              parameters:nil
              completion:^(id result, NSError *error) {
        if (completion) {
            completion(error == nil);
        }
    }];
}

#pragma mark - Station Browsing

- (void)localStationsWithCompletion:(void(^)(NSArray *stations, NSError *error))completion
{
    // First attempt: simple local browse (uses client IP for geolocation)
    [self performRequest:@"Browse.ashx"
              parameters:@{ @"c": @"local", @"render": @"json" }
              completion:^(id result, NSError *error) {
        if (error) {
            NSLog(@"[RadioBrowser] localStations direct error: %@", error);
        } else {
            NSArray *stations = [self parseStationsFromResult:result];
            if ([stations count] > 0) {
                NSLog(@"[RadioBrowser] Found %tu local stations (direct)", [stations count]);
                if (completion) completion(stations, nil);
                return;
            }
        }

        // Fallback: find location by country
        NSString *countryCode = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
        NSString *countryName = nil;
        if (countryCode) {
            countryName = [[NSLocale currentLocale] displayNameForKey:NSLocaleCountryCode
                                                                value:countryCode];
        }
        if (!countryName) countryName = countryCode ?: @"";

        NSLog(@"[RadioBrowser] Falling back to country search: %@ (%@)", countryName, countryCode);
        [self findLocationIdForCountryName:countryName
                               completion:^(NSString *locationId) {
            if (locationId) {
                NSLog(@"[RadioBrowser] Found location id %@ for %@", locationId, countryName);
                [self topStationsForLocationId:locationId completion:completion];
            } else {
                NSLog(@"[RadioBrowser] No location id for %@, trying search", countryName);
                [self searchStations:countryName completion:completion];
            }
        }];
    }];
}

- (void)searchStations:(NSString *)query
           completion:(void(^)(NSArray *stations, NSError *error))completion
{
    [self performRequest:@"Search.ashx"
              parameters:@{ @"query": query, @"render": @"json" }
              completion:^(id result, NSError *error) {
        if (error) {
            if (completion) completion(nil, error);
            return;
        }
        NSArray *stations = [self parseStationsFromResult:result];
        if (completion) completion(stations, nil);
    }];
}

#pragma mark - Result Parsing

- (NSArray *)parseStationsFromResult:(id)result
{
    NSArray *body = nil;
    if ([result isKindOfClass:[NSDictionary class]]) {
        body = [result objectForKey:@"body"];
    } else if ([result isKindOfClass:[NSArray class]]) {
        body = result;
    }

    NSMutableArray *stations = [NSMutableArray array];
    if ([body isKindOfClass:[NSArray class]]) {
        for (NSDictionary *item in body) {
            NSString *type = [item objectForKey:@"type"];
            NSString *itemType = [item objectForKey:@"item"];
            if ([type isEqualToString:@"audio"] || [itemType isEqualToString:@"station"]) {
                RadioStation *s = [[RadioStation alloc] initWithDictionary:item];
                [stations addObject:s];
                [s release];
            }
            // Check nested 'outline' with children
            if ([[item objectForKey:@"element"] isEqualToString:@"outline"]) {
                NSArray *children = [item objectForKey:@"children"];
                if ([children isKindOfClass:[NSArray class]]) {
                    for (NSDictionary *child in children) {
                        NSString *ctype = [child objectForKey:@"type"];
                        NSString *citemType = [child objectForKey:@"item"];
                        if ([ctype isEqualToString:@"audio"] || [citemType isEqualToString:@"station"]) {
                            RadioStation *s = [[RadioStation alloc] initWithDictionary:child];
                            [stations addObject:s];
                            [s release];
                        }
                    }
                }
            }
        }
    }
    return stations;
}

#pragma mark - HTTP Request

- (void)performRequest:(NSString *)endpoint
            parameters:(NSDictionary *)params
            completion:(void(^)(id result, NSError *error))completion
{
    NSMutableString *urlString = [NSMutableString stringWithFormat:@"%@/%@", _baseURL, endpoint];

    if (params) {
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *key in params) {
            id obj = [params objectForKey:key];
            NSString *val = [obj stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet URLQueryAllowedCharacterSet]];
            [parts addObject:[NSString stringWithFormat:@"%@=%@", key, val]];
        }
        [urlString appendFormat:@"?%@", [parts componentsJoinedByString:@"&"]];
    }

    NSURL *url = [NSURL URLWithString:urlString];
    NSLog(@"[RadioBrowser] Request: %@", url);

    // In MRC: copy the completion block; it is released once it has run
    __block void(^savedCompletion)(id, NSError*) = [completion copy];

    PlayerRunInBackground(^{
        @autoreleasepool {
            NSURLRequest *request = [NSURLRequest requestWithURL:url
                                                     cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                 timeoutInterval:15.0];
            NSURLResponse *response = nil;
            NSError *connectionError = nil;
            NSData *data = [NSURLConnection sendSynchronousRequest:request
                                                 returningResponse:&response
                                                             error:&connectionError];

            PlayerRunOnMainThread(^{
                @autoreleasepool {
                    if (connectionError) {
                        if (savedCompletion) {
                            savedCompletion(nil, connectionError);
                            [savedCompletion release];
                            savedCompletion = nil;
                        }
                        return;
                    }

                    NSError *jsonError = nil;
                    id json = nil;
                    if (data) {
                        json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                    }

                    if (jsonError) {
                        if (savedCompletion) {
                            savedCompletion(nil, jsonError);
                            [savedCompletion release];
                            savedCompletion = nil;
                        }
                    } else {
                        if (savedCompletion) {
                            savedCompletion(json ?: [NSNull null], nil);
                            [savedCompletion release];
                            savedCompletion = nil;
                        }
                    }
                }
            });
        }
    });
}

#pragma mark - Location Helpers

- (void)findLocationIdForCountryName:(NSString *)countryName
                          completion:(void(^)(NSString *locationId))completion
{
    [self performRequest:@"Browse.ashx"
              parameters:@{ @"id": @"r0", @"render": @"json" }
              completion:^(id result, NSError *error) {
        if (error) {
            NSLog(@"[RadioBrowser] findLocationId error: %@", error);
            if (completion) completion(nil);
            return;
        }

        NSArray *body = nil;
        if ([result isKindOfClass:[NSDictionary class]]) {
            body = [result objectForKey:@"body"];
        } else if ([result isKindOfClass:[NSArray class]]) {
            body = result;
        }

        __block NSString *foundId = nil;
        if ([body isKindOfClass:[NSArray class]]) {
            foundId = [self scanForLocationIdInArray:body matchingName:countryName];
        }

        if (foundId) {
            if (completion) completion(foundId);
            return;
        }

        // Not found at top-level, try each top-level id's children
        for (NSDictionary *item in body) {
            NSString *maybeId = [self extractLocationIdFromItem:item];
            if (maybeId) {
                [self performRequest:@"Browse.ashx"
                          parameters:@{ @"id": maybeId, @"render": @"json" }
                          completion:^(id subres, NSError *err) {
                    if (err) return;
                    NSArray *subbody = nil;
                    if ([subres isKindOfClass:[NSDictionary class]]) {
                        subbody = [subres objectForKey:@"body"];
                    }
                    if ([subbody isKindOfClass:[NSArray class]] && !foundId) {
                        NSString *s = [self scanForLocationIdInArray:subbody
                                                        matchingName:countryName];
                        if (s) foundId = [s retain];
                    }
                }];
            }
            if (foundId) break;
        }

        // Wait for subrequests, then return foundId
        PlayerRunOnMainThreadAfter(1.5, ^{
            if (completion) completion(foundId);
            [foundId release];
        });
    }];
}

- (NSString *)scanForLocationIdInArray:(NSArray *)arr matchingName:(NSString *)name
{
    for (NSDictionary *item in arr) {
        NSString *text = [item objectForKey:@"text"];
        if (!text) text = [item objectForKey:@"title"];
        if (text && [[text lowercaseString] isEqualToString:[name lowercaseString]]) {
            NSString *rid = [self extractLocationIdFromItem:item];
            if (rid) return rid;
        }
        // Inspect children
        NSArray *children = [item objectForKey:@"children"];
        if ([children isKindOfClass:[NSArray class]]) {
            NSString *r = [self scanForLocationIdInArray:children matchingName:name];
            if (r) return r;
        }
    }
    return nil;
}

- (NSString *)extractLocationIdFromItem:(NSDictionary *)item
{
    NSString *key = [item objectForKey:@"key"];
    if (key && [key hasPrefix:@"r"]) {
        return [[key retain] autorelease];
    }

    NSString *url = [item objectForKey:@"URL"];
    if (!url) url = [item objectForKey:@"url"];
    if (url) {
        NSRange r = [url rangeOfString:@"id="];
        if (r.location != NSNotFound) {
            NSString *sub = [url substringFromIndex:(r.location + r.length)];
            NSRange amp = [sub rangeOfString:@"&"];
            if (amp.location != NSNotFound) {
                sub = [sub substringToIndex:amp.location];
            }
            return [[sub retain] autorelease];
        }
    }
    return nil;
}

- (void)topStationsForLocationId:(NSString *)locationId
                      completion:(void(^)(NSArray *stations, NSError *error))completion
{
    [self performRequest:@"Browse.ashx"
              parameters:@{ @"id": locationId, @"render": @"json" }
              completion:^(id result, NSError *error) {
        if (error) {
            if (completion) completion(nil, error);
            return;
        }
        NSArray *stations = [self parseStationsFromResult:result];
        NSLog(@"[RadioBrowser] Found %tu stations for location %@", [stations count], locationId);
        if (completion) completion(stations, nil);
    }];
}

@end
