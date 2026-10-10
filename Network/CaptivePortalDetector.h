/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@interface CaptivePortalDetector : NSObject

+ (void)checkForCaptivePortalWithCompletion:(void (^)(BOOL isCaptive, NSString *redirectURL))completion;
+ (void)checkForCaptivePortalForceWithCompletion:(void (^)(BOOL isCaptive, NSString *redirectURL))completion;

/* The decisions behind the check, without any network, so they can be tested.
   The probe is made without following redirects blindly: a redirect to
   another host or a WISPr message is the portal itself. */

/* The WISPr redirect message (MessageType 100, ResponseCode 0) found anywhere
   in a response body, usually inside an HTML comment.  Keys, each only when
   present: LoginURL, AbortLoginURL, LocationName, AccessLocation.  nil when
   the body holds no such message (other message types and error codes are
   not redirects).  Reads at most the first 64 KiB. */
+ (NSDictionary *)wisprRedirectInResponseBody:(NSString *)body;

/* Verdict for one response.  location is the raw Location header (relative
   ones are resolved against currentURL), probeURL the URL the check started
   with.  Returns YES for captive; *redirectURL is then the http(s) URL to open
   in a browser, or nil when the portal gave none.  Returns NO with *followURL
   set for a redirect that stays on the probe host and has to be followed to
   decide; NO with both nil means the internet is reachable. */
+ (BOOL)captiveVerdictForStatus:(long)status
                       location:(NSString *)location
                           body:(NSString *)body
                       probeURL:(NSString *)probeURL
                     currentURL:(NSString *)currentURL
                    redirectURL:(NSString **)redirectURL
                      followURL:(NSString **)followURL;

@end
