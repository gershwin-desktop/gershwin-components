/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "CaptivePortalDetector.h"
#include <curl/curl.h>
#include <string.h>

#define CAPTIVE_PORTAL_PROBE_BASE_URL @"http://example.com"
#define CAPTIVE_PORTAL_MIN_INTERVAL 60.0
// example.com returns this string in the body on success
#define EXPECTED_PROBE_MARKER "Example Domain"

#define CAPTIVE_PORTAL_MAX_HOPS 5
// A portal page is small; this bounds memory and the work of the parser
#define CAPTIVE_PORTAL_MAX_BODY (64 * 1024)

struct CaptivePortalResponse {
    char *body;   // response body for content check, capped
    size_t bodyLen;
};

static size_t captivePortalWriteCallback(char *ptr, size_t size, size_t nmemb, void *userdata)
{
    size_t total = size * nmemb;
    struct CaptivePortalResponse *resp = (struct CaptivePortalResponse *)userdata;
    size_t keep = total;
    if (resp->bodyLen >= CAPTIVE_PORTAL_MAX_BODY) {
        keep = 0;
    } else if (keep > CAPTIVE_PORTAL_MAX_BODY - resp->bodyLen) {
        keep = CAPTIVE_PORTAL_MAX_BODY - resp->bodyLen;
    }
    if (keep > 0) {
        char *newBody = realloc(resp->body, resp->bodyLen + keep + 1);
        if (newBody) {
            memcpy(newBody + resp->bodyLen, ptr, keep);
            resp->bodyLen += keep;
            newBody[resp->bodyLen] = '\0';
            resp->body = newBody;
        }
    }
    // Report everything as consumed so curl does not abort the transfer
    return total;
}

/* Text between <tag ...> and </tag>, tags matched case-insensitively, or nil.
   Returns the range after the closing tag through *after when given. */
static NSString *captivePortalElement(NSString *s, NSString *tag, NSUInteger from, NSUInteger *after)
{
    NSString *open = [@"<" stringByAppendingString:tag];
    NSString *close = [@"</" stringByAppendingString:tag];
    NSUInteger len = [s length];
    NSUInteger pos = from;
    while (pos < len) {
        NSRange r = [s rangeOfString:open options:NSCaseInsensitiveSearch
                               range:NSMakeRange(pos, len - pos)];
        if (r.location == NSNotFound) return nil;
        NSUInteger n = NSMaxRange(r);
        // "<Redirect" must not match "<RedirectFoo"
        if (n < len) {
            unichar c = [s characterAtIndex:n];
            if (c != '>' && c != '/' && c != ' ' && c != '\t' && c != '\r' && c != '\n') {
                pos = n;
                continue;
            }
        }
        NSRange gt = [s rangeOfString:@">" options:0 range:NSMakeRange(n, len - n)];
        if (gt.location == NSNotFound) return nil;
        NSUInteger start = NSMaxRange(gt);
        NSRange e = [s rangeOfString:close options:NSCaseInsensitiveSearch
                               range:NSMakeRange(start, len - start)];
        if (e.location == NSNotFound) return nil;
        if (after) *after = e.location;
        return [s substringWithRange:NSMakeRange(start, e.location - start)];
    }
    return nil;
}

/* The text of an element: real CDATA is verbatim, the CDATA[[...]] spelling
   some gateways use is unwrapped, everything else has its entities resolved. */
static NSString *captivePortalText(NSString *raw)
{
    NSString *t = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([t hasPrefix:@"<![CDATA["]) {
        NSRange e = [t rangeOfString:@"]]>" options:NSBackwardsSearch];
        if (e.location == NSNotFound || e.location < 9) return nil;
        return [t substringWithRange:NSMakeRange(9, e.location - 9)];
    }
    if ([t hasPrefix:@"CDATA[["] && [t hasSuffix:@"]]"] && [t length] >= 9) {
        return [t substringWithRange:NSMakeRange(7, [t length] - 9)];
    }
    // &amp; last so that "&amp;lt;" stays "&lt;"
    t = [t stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"];
    t = [t stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];
    t = [t stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
    t = [t stringByReplacingOccurrencesOfString:@"&apos;" withString:@"'"];
    return [t stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
}

/* Absolute http or https URL for s resolved against base, else nil.  A
   portal controls these strings, and the result is opened in a browser, so
   no other scheme may come out. */
static NSString *captivePortalHTTPURL(NSString *s, NSString *base)
{
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([t length] == 0) return nil;
    NSURL *baseURL = base ? [NSURL URLWithString:base] : nil;
    NSURL *url = [NSURL URLWithString:t relativeToURL:baseURL];
    NSURL *abs = [url absoluteURL];
    NSString *scheme = [[abs scheme] lowercaseString];
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) return nil;
    if ([[abs host] length] == 0) return nil;
    return [abs absoluteString];
}

static NSString *captivePortalBodyString(const char *bytes, size_t len)
{
    if (!bytes) return nil;
    NSString *s = [[[NSString alloc] initWithBytes:bytes length:len
                                          encoding:NSUTF8StringEncoding] autorelease];
    // A page cut at the size cap may end inside a UTF-8 sequence
    if (!s) {
        s = [[[NSString alloc] initWithBytes:bytes length:len
                                    encoding:NSISOLatin1StringEncoding] autorelease];
    }
    return s;
}

static volatile int32_t _captivePortalCheckPending = 0;
static NSTimeInterval _lastCaptivePortalCheckTime = 0;

@interface CaptivePortalDetector (Private)
+ (void)_runCheckWithCompletion:(void (^)(BOOL, NSString *))completion;
+ (void)_callCompletionOnMainThread:(NSArray *)args;
@end

@implementation CaptivePortalDetector

+ (void)checkForCaptivePortalWithCompletion:(void (^)(BOOL isCaptive, NSString *redirectURL))completion
{
    if (!completion) return;

    @autoreleasepool {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - _lastCaptivePortalCheckTime < CAPTIVE_PORTAL_MIN_INTERVAL) {
            return;
        }
        _lastCaptivePortalCheckTime = now;

        if (__sync_lock_test_and_set(&_captivePortalCheckPending, 1)) {
            return;
        }

        /* This file is built without ARC: -copy returns an owned block, and
           performSelectorInBackground: retains its argument for the thread,
           so the copy must be balanced here or every check leaks a block. */
        [self performSelectorInBackground:@selector(_runCheckWithCompletion:)
                               withObject:[[completion copy] autorelease]];
    }
}

+ (void)checkForCaptivePortalForceWithCompletion:(void (^)(BOOL isCaptive, NSString *redirectURL))completion
{
    if (!completion) return;

    @autoreleasepool {
        if (__sync_lock_test_and_set(&_captivePortalCheckPending, 1)) {
            return;
        }

        _lastCaptivePortalCheckTime = [NSDate timeIntervalSinceReferenceDate];

        [self performSelectorInBackground:@selector(_runCheckWithCompletion:)
                               withObject:[[completion copy] autorelease]];
    }
}

+ (NSDictionary *)wisprRedirectInResponseBody:(NSString *)body
{
    if ([body length] == 0) return nil;
    if ([body length] > CAPTIVE_PORTAL_MAX_BODY) {
        body = [body substringToIndex:CAPTIVE_PORTAL_MAX_BODY];
    }

    NSUInteger paramStart = [body rangeOfString:@"<WISPAccessGatewayParam"
                                        options:NSCaseInsensitiveSearch].location;
    if (paramStart == NSNotFound) return nil;
    NSString *redirect = captivePortalElement(body, @"Redirect", paramStart, NULL);
    if (!redirect) return nil;

    // Only "redirect, no error" sends a client to a login page; the other
    // message types and the gateway's error codes do not.
    NSString *type = captivePortalText(captivePortalElement(redirect, @"MessageType", 0, NULL) ?: @"");
    NSString *code = captivePortalText(captivePortalElement(redirect, @"ResponseCode", 0, NULL) ?: @"");
    if (![type isEqualToString:@"100"] || ![code isEqualToString:@"0"]) return nil;

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSArray *keys = @[@"LoginURL", @"AbortLoginURL", @"LocationName", @"AccessLocation"];
    for (NSString *key in keys) {
        NSString *raw = captivePortalElement(redirect, key, 0, NULL);
        NSString *value = raw ? captivePortalText(raw) : nil;
        if (value) [result setObject:value forKey:key];
    }
    return result;
}

+ (BOOL)captiveVerdictForStatus:(long)status
                       location:(NSString *)location
                           body:(NSString *)body
                       probeURL:(NSString *)probeURL
                     currentURL:(NSString *)currentURL
                    redirectURL:(NSString **)redirectURL
                      followURL:(NSString **)followURL
{
    if (redirectURL) *redirectURL = nil;
    if (followURL) *followURL = nil;

    BOOL isRedirect = (status == 301 || status == 302 || status == 303
                       || status == 307 || status == 308);
    NSString *target = isRedirect ? captivePortalHTTPURL(location, currentURL) : nil;

    // WISPr wins: the gateway says outright that this is a portal.  The
    // redirect target is what a browser should open; the LoginURL is a
    // machine endpoint and only the fallback.
    NSDictionary *wispr = [self wisprRedirectInResponseBody:body];
    if (wispr) {
        if (redirectURL) {
            *redirectURL = target ?: captivePortalHTTPURL([wispr objectForKey:@"LoginURL"], currentURL);
        }
        return YES;
    }

    if (target) {
        NSString *probeHost = [[[NSURL URLWithString:probeURL] host] lowercaseString];
        NSString *targetHost = [[[NSURL URLWithString:target] host] lowercaseString];
        if (probeHost && [probeHost isEqualToString:targetHost]) {
            // http -> https upgrade, trailing slash: the probe host itself
            if (followURL) *followURL = target;
            return NO;
        }
        if (redirectURL) *redirectURL = target;
        return YES;
    }

    // Answered by the probe host itself: only the expected page proves the
    // internet is reachable.
    if (body && [body rangeOfString:@EXPECTED_PROBE_MARKER].location != NSNotFound) {
        return NO;
    }
    return YES;
}

+ (void)_runCheckWithCompletion:(void (^)(BOOL, NSString *))completion
{
    @autoreleasepool {
        CURL *curl = curl_easy_init();
        if (!curl) {
            __sync_lock_release(&_captivePortalCheckPending);
            return;
        }

        curl_easy_setopt(curl, CURLOPT_TIMEOUT, 10L);
        curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 5L);
        // Redirects are judged one by one: the portal's first answer is
        // the result, whether or not its login host can be reached.
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, captivePortalWriteCallback);
        curl_easy_setopt(curl, CURLOPT_USERAGENT, "CaptivePortalDetector/1.0");
        curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);

        // A portal usually intercepts only IPv4: example.com also has IPv6
        // addresses, and over those the probe reached the real internet past
        // a portal that was holding back every IPv4 page (hotel and train
        // networks), so no login page was offered.  The probe goes out over
        // IPv4; only when that cannot even be tried (an IPv6-only network)
        // the first hop is repeated over whichever family works.
        curl_easy_setopt(curl, CURLOPT_IPRESOLVE, (long)CURL_IPRESOLVE_V4);
        BOOL triedAnyFamily = NO;

        BOOL isCaptive = YES;   // stays so when the hops run out undecided
        NSString *redirectURL = nil;
        NSString *current = CAPTIVE_PORTAL_PROBE_BASE_URL;

        for (int hop = 0; hop < CAPTIVE_PORTAL_MAX_HOPS; hop++) {
            struct CaptivePortalResponse resp;
            memset(&resp, 0, sizeof(resp));
            curl_easy_setopt(curl, CURLOPT_URL, [current UTF8String]);
            curl_easy_setopt(curl, CURLOPT_WRITEDATA, &resp);

            CURLcode res = curl_easy_perform(curl);
            if (res != CURLE_OK && hop == 0 && !triedAnyFamily) {
                // No answer over IPv4 says nothing about a portal (there may
                // be no IPv4 at all); only an answer does.
                if (resp.body) free(resp.body);
                curl_easy_setopt(curl, CURLOPT_IPRESOLVE, (long)CURL_IPRESOLVE_WHATEVER);
                triedAnyFamily = YES;
                hop = -1;
                continue;
            }
            if (res != CURLE_OK) {
                // These failures are common behind a captive portal that
                // intercepts DNS, drops connections, or times out.
                isCaptive = (res == CURLE_GOT_NOTHING
                             || res == CURLE_COULDNT_RESOLVE_HOST
                             || res == CURLE_COULDNT_CONNECT
                             || res == CURLE_OPERATION_TIMEDOUT);
                if (resp.body) free(resp.body);
                break;
            }

            long status = 0;
            char *locationC = NULL;
            curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
            curl_easy_getinfo(curl, CURLINFO_REDIRECT_URL, &locationC);
            NSString *location = locationC ? [NSString stringWithUTF8String:locationC] : nil;
            NSString *body = captivePortalBodyString(resp.body, resp.bodyLen);
            if (resp.body) free(resp.body);

            NSString *follow = nil;
            isCaptive = [self captiveVerdictForStatus:status
                                             location:location
                                                 body:body
                                             probeURL:CAPTIVE_PORTAL_PROBE_BASE_URL
                                           currentURL:current
                                          redirectURL:&redirectURL
                                            followURL:&follow];
            if (!follow) break;
            current = follow;
            isCaptive = YES;
        }

        curl_easy_cleanup(curl);

        [self performSelectorOnMainThread:@selector(_callCompletionOnMainThread:)
                               withObject:@[redirectURL ?: (id)[NSNull null],
                                            [NSNumber numberWithBool:isCaptive],
                                            completion]
                            waitUntilDone:NO];

        __sync_lock_release(&_captivePortalCheckPending);
    }
}

+ (void)_callCompletionOnMainThread:(NSArray *)args
{
    id urlOrNull = [args objectAtIndex:0];
    BOOL isCaptive = [[args objectAtIndex:1] boolValue];
    void (^completion)(BOOL, NSString *) = [args objectAtIndex:2];

    // A portal that names no login page is still a portal, so the callers
    // do not mistake it for working internet.
    NSString *redirectURL = ([urlOrNull isKindOfClass:[NSString class]]) ? urlOrNull : nil;
    completion(isCaptive, redirectURL);
}

@end
