/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The captive portal verdict is decided from the portal's first answer:
   a redirect to another host, or a WISPr redirect message hidden in the body
   (usually inside an HTML comment).  Both decisions are pure functions, so
   they are tested here without any network.

   Choice for ResponseCode: a Redirect message with a ResponseCode other than
   0 is an error report from the gateway, not a redirect to a login page, so
   it is ignored like the other message types. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "CaptivePortalDetector.h"

static NSString *const kProbe = @"http://example.com";

static NSString *wispr(NSString *messageType, NSString *responseCode,
                       NSString *loginURL, NSString *extra)
{
  return [NSString stringWithFormat:
    @"<WISPAccessGatewayParam xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n"
    @"<Redirect>\n<MessageType>%@</MessageType>\n<ResponseCode>%@</ResponseCode>\n"
    @"%@<LoginURL>%@</LoginURL>\n<AbortLoginURL>http://192.168.44.1:80/abort</AbortLoginURL>\n"
    @"</Redirect>\n</WISPAccessGatewayParam>\n", messageType, responseCode, extra, loginURL];
}

static BOOL verdict(long status, NSString *location, NSString *body,
                    NSString **url, NSString **follow)
{
  NSString *u = nil;
  NSString *f = nil;
  BOOL captive = [CaptivePortalDetector captiveVerdictForStatus: status
                                                       location: location
                                                           body: body
                                                       probeURL: kProbe
                                                     currentURL: kProbe
                                                    redirectURL: &u
                                                      followURL: &f];
  if (url) *url = u;
  if (follow) *follow = f;
  return captive;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSString *url = nil;
  NSString *follow = nil;

  /* The real example: hotsplots.de, 302 with the XML in an HTML comment. */
  NSString *hotLocation = @"https://www.hotsplots.de/auth/login.php?res=notyet&uamip=192.168.44.1&uamport=80&challenge=74072102cca7fc9d899b04b224d7aeb9&called=00-C0-3A-C9-08-F3&mac=DE-95-F9-65-69-48&ip=192.168.45.11&nasid=colibri-00c03ac988f3&sessionid=6ac8a1a800000007&userurl=http%3a%2f%2ftest.de%2f";
  NSString *hotBody = @"<HTML><BODY><H2>Browser error!</H2>Browser does not support redirects!</BODY>\n<!--\n"
    @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    @"<WISPAccessGatewayParam xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:noNamespaceSchemaLocation=\"http://www.wballiance.net/wispr_2_0.xsd\">\n"
    @"<Redirect>\n<MessageType>100</MessageType>\n<ResponseCode>0</ResponseCode>\n"
    @"<VersionHigh>2.0</VersionHigh>\n<VersionLow>1.0</VersionLow>\n<AccessProcedure>1.0</AccessProcedure>\n"
    @"<AccessLocation>CDATA[[isocc=,cc=,ac=,network=HOTSPLOTS,]]</AccessLocation>\n"
    @"<LocationName>CDATA[[colibri-00c03ac988f3]]</LocationName>\n"
    @"<LoginURL>https://www.hotsplots.de/auth/login.php?res=wispr&amp;uamip=192.168.44.1&amp;uamport=80&amp;challenge=74072102cca7fc9d899b04b224d7aeb9</LoginURL>\n"
    @"<AbortLoginURL>http://192.168.44.1:80/abort</AbortLoginURL>\n<EAPMsg>AQEABQE=</EAPMsg>\n"
    @"</Redirect>\n</WISPAccessGatewayParam>\n-->\n</HTML>";

  PASS(verdict(302, hotLocation, hotBody, &url, &follow), "hotsplots 302 is captive");
  PASS_EQUAL(url, hotLocation, "the redirect Location is the URL to open, not the WISPr LoginURL");
  PASS(follow == nil, "a portal redirect is not followed");

  NSDictionary *w = [CaptivePortalDetector wisprRedirectInResponseBody: hotBody];
  PASS(w != nil, "the WISPr message inside the HTML comment is found");
  PASS_EQUAL([w objectForKey: @"LoginURL"],
    @"https://www.hotsplots.de/auth/login.php?res=wispr&uamip=192.168.44.1&uamport=80&challenge=74072102cca7fc9d899b04b224d7aeb9",
    "&amp; in the LoginURL is unescaped");
  PASS_EQUAL([w objectForKey: @"AbortLoginURL"], @"http://192.168.44.1:80/abort", "AbortLoginURL");
  PASS_EQUAL([w objectForKey: @"LocationName"], @"colibri-00c03ac988f3", "CDATA[[...]] LocationName is unwrapped");
  PASS_EQUAL([w objectForKey: @"AccessLocation"], @"isocc=,cc=,ac=,network=HOTSPLOTS,", "CDATA[[...]] AccessLocation is unwrapped");

  /* WISPr in a plain 200 page, no Location: the LoginURL is the fallback. */
  PASS(verdict(200, nil, [@"<html>" stringByAppendingString:
        wispr(@"100", @"0", @"https://login.example.net/wispr?a=1&amp;b=2", @"")],
        &url, &follow), "WISPr in a 200 body is captive");
  PASS_EQUAL(url, @"https://login.example.net/wispr?a=1&b=2", "LoginURL used when there is no Location");

  /* Real CDATA and upper case tags. */
  w = [CaptivePortalDetector wisprRedirectInResponseBody:
    @"<wispaccessgatewayparam><REDIRECT><MESSAGETYPE>100</MESSAGETYPE><responsecode>0</responsecode>"
    @"<LOGINURL><![CDATA[https://l.example.net/x?a=1&b=2]]></LOGINURL>"
    @"<locationname><![CDATA[Cafe Nero]]></locationname></redirect></WISPACCESSGATEWAYPARAM>"];
  PASS_EQUAL([w objectForKey: @"LoginURL"], @"https://l.example.net/x?a=1&b=2", "real CDATA is kept verbatim");
  PASS_EQUAL([w objectForKey: @"LocationName"], @"Cafe Nero", "tags are case insensitive");

  /* Other message types and error codes are not redirects. */
  PASS([CaptivePortalDetector wisprRedirectInResponseBody: wispr(@"110", @"50", @"https://l.example.net/", @"")] == nil, "MessageType 110 ignored");
  PASS([CaptivePortalDetector wisprRedirectInResponseBody: wispr(@"120", @"50", @"https://l.example.net/", @"")] == nil, "MessageType 120 ignored");
  PASS([CaptivePortalDetector wisprRedirectInResponseBody: wispr(@"100", @"102", @"https://l.example.net/", @"")] == nil, "ResponseCode other than 0 ignored");
  PASS([CaptivePortalDetector wisprRedirectInResponseBody: @"<WISPAccessGatewayParam><Redirect><MessageType>100</MessageType><LoginURL>https://l.example.net/</LoginURL></Redirect></WISPAccessGatewayParam>"] == nil, "missing ResponseCode ignored");
  PASS(!verdict(200, nil, [@"Example Domain " stringByAppendingString:
        wispr(@"120", @"0", @"https://l.example.net/", @"")], &url, NULL) && url == nil,
        "an ignored WISPr message leaves the marker check in charge");

  /* Redirects. */
  PASS(!verdict(301, @"https://example.com/", nil, &url, &follow), "http -> https on the probe host is not decided yet");
  PASS_EQUAL(follow, @"https://example.com/", "and it is followed");
  PASS(url == nil, "no portal URL for it");
  PASS(!verdict(302, @"/index.html", nil, &url, &follow), "relative Location on the probe host");
  PASS_EQUAL(follow, @"http://example.com/index.html", "relative Location is resolved against the current URL");
  PASS(verdict(302, @"http://portal.example.net/login", nil, &url, &follow), "other host is the portal");
  PASS_EQUAL(url, @"http://portal.example.net/login", "its Location is the URL to open");
  PASS(follow == nil, "and is not followed");
  PASS(verdict(302, @"//portal.example.net/login", nil, &url, NULL), "scheme-relative Location to another host");
  PASS_EQUAL(url, @"http://portal.example.net/login", "is resolved with the current scheme");
  PASS(verdict(302, @"http://EXAMPLE.org/x", nil, &url, NULL) && url != nil, "a different domain is another host");
  PASS(!verdict(302, @"http://EXAMPLE.com/x", nil, &url, &follow), "host comparison ignores case");

  /* Only http and https ever come out. */
  PASS(verdict(302, @"javascript:alert(1)", nil, &url, NULL) && url == nil, "javascript: Location is not returned");
  PASS(verdict(302, @"file:///etc/passwd", nil, &url, NULL) && url == nil, "file: Location is not returned");
  PASS(verdict(302, @"file:///etc/passwd", wispr(@"100", @"0", @"https://l.example.net/w", @""), &url, NULL)
       && [url isEqual: @"https://l.example.net/w"], "bad Location with WISPr falls back to the LoginURL");
  PASS(verdict(200, nil, wispr(@"100", @"0", @"javascript:alert(1)", @""), &url, NULL) && url == nil,
       "javascript: LoginURL is not returned, still captive");
  PASS(verdict(200, nil, wispr(@"100", @"0", @"ftp://l.example.net/", @""), &url, NULL) && url == nil,
       "ftp: LoginURL is not returned");

  /* Plain 200 answers. */
  PASS(!verdict(200, nil, @"<html><title>Example Domain</title></html>", &url, &follow) && url == nil && follow == nil,
       "200 with the marker is the internet");
  PASS(verdict(200, nil, @"<html>Please sign in</html>", &url, &follow) && url == nil && follow == nil,
       "200 without marker and without WISPr is captive without URL");
  PASS(verdict(200, nil, nil, &url, NULL) && url == nil, "nil body is captive without URL");
  PASS(verdict(302, nil, @"Moved", &url, NULL) && url == nil, "302 without Location is captive without URL");

  /* Garbage and size. */
  PASS([CaptivePortalDetector wisprRedirectInResponseBody: nil] == nil, "nil body");
  PASS([CaptivePortalDetector wisprRedirectInResponseBody: @""] == nil, "empty body");
  PASS([CaptivePortalDetector wisprRedirectInResponseBody: @"<WISPAccessGatewayParam><Redirect><MessageType>100"] == nil, "truncated message");
  PASS([CaptivePortalDetector wisprRedirectInResponseBody: @"</Redirect><Redirect><WISPAccessGatewayParam>"] == nil, "tags out of order");
  w = [CaptivePortalDetector wisprRedirectInResponseBody: @"<WISPAccessGatewayParam><Redirect><MessageType>100</MessageType><ResponseCode>0</ResponseCode><LoginURL><![CDATA[unterminated"];
  PASS(w == nil, "unterminated message (and CDATA) is no message and does not crash");
  NSMutableString *huge = [NSMutableString string];
  for (int i = 0; i < 20000; i++) [huge appendString: @"<Redirect><MessageType>"];
  PASS([CaptivePortalDetector wisprRedirectInResponseBody: huge] == nil, "huge repetitive body does not crash or hang");
  PASS(verdict(200, nil, huge, &url, NULL) && url == nil, "huge body verdict");
  NSMutableData *junk = [NSMutableData dataWithLength: 70000];
  memset([junk mutableBytes], '<', 70000);
  NSString *junkString = [[NSString alloc] initWithData: junk encoding: NSISOLatin1StringEncoding];
  PASS(verdict(200, nil, junkString, &url, NULL) && url == nil, "body of angle brackets");
  [junkString release];

  [arp release];
  return 0;
}
