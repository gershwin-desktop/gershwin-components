/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "AGLicenseFormatter.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* --- the mappings from the brief --- */
  PASS_EQUAL([AGLicenseFormatter displayStringForLicense: nil], @"Unknown license",
             "a missing license shows Unknown license");
  PASS_EQUAL([AGLicenseFormatter displayStringForLicense: @"NOASSERTION"], @"Unknown license",
             "NOASSERTION shows Unknown license");
  PASS_EQUAL([AGLicenseFormatter displayStringForLicense: @"LicenseRef-proprietary"],
             @"Proprietary",
             "the bare proprietary reference shows Proprietary");
  PASS_EQUAL([AGLicenseFormatter displayStringForLicense:
                @"LicenseRef-proprietary=https://example.com/LICENSE"],
             @"Proprietary",
             "a proprietary reference with a URL shows Proprietary");
  PASS_EQUAL([AGLicenseFormatter displayStringForLicense: @"GPL-3.0+"],
             @"GPL-3.0 or later",
             "the short or-later spelling normalizes");
  PASS_EQUAL([AGLicenseFormatter displayStringForLicense: @"GPL-3.0-or-later"],
             @"GPL-3.0 or later",
             "the long or-later spelling normalizes to the same string");

  /* --- everything else stays verbatim --- */
  PASS_EQUAL([AGLicenseFormatter displayStringForLicense: @"MIT"], @"MIT",
             "a plain license is shown verbatim");
  PASS_EQUAL([AGLicenseFormatter displayStringForLicense: @"Apache-2.0"], @"Apache-2.0",
             "a versioned license is shown verbatim");
  PASS_EQUAL([AGLicenseFormatter displayStringForLicense: @"GPL-2.0+"], @"GPL-2.0+",
             "only the GPL-3.0 or-later spellings normalize");

  /* --- the optional license link --- */
  PASS_EQUAL([[AGLicenseFormatter licenseURLForLicense:
                 @"LicenseRef-proprietary=https://example.com/LICENSE"] absoluteString],
             @"https://example.com/LICENSE",
             "the URL after the '=' is the license link");
  PASS([AGLicenseFormatter licenseURLForLicense: @"LicenseRef-proprietary"] == nil,
       "a proprietary reference without a URL has no link");
  PASS([AGLicenseFormatter licenseURLForLicense: @"MIT"] == nil,
       "a plain license has no link");
  PASS([AGLicenseFormatter licenseURLForLicense: nil] == nil,
       "a missing license has no link");

  [arp release];
  return 0;
}
