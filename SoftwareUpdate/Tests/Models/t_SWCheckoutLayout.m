/* t_SWCheckoutLayout.m - ObjectTesting coverage for SWCheckoutLayout.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SWCheckoutLayout.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  SWCheckoutLayout *layout = [SWCheckoutLayout systemLayout];
  PASS_EQUAL([layout pathForRepositoryNamed:@"gershwin-developer"], @"/Developer",
             "gershwin-developer is the /Developer checkout, not a copy in Library/Sources");
  PASS_EQUAL([layout pathForRepositoryNamed:@"gershwin-components"],
             @"/Developer/Library/Sources/gershwin-components",
             "every other repository lives in Library/Sources");
  PASS_EQUAL([layout repositoriesCSVPath], @"/Developer/Library/Repositories.csv",
             "Repositories.csv is read from the checkout that gets updated");
  PASS_EQUAL([layout installScriptPath], @"/Developer/Library/Scripts/install-system-domain.sh",
             "the install script is read from the checkout that gets updated");
  PASS_EQUAL([layout osSupportDirectory], @"/Developer/Library/OSSupport",
             "the package lists are read from the checkout that gets updated");
  PASS_EQUAL([layout patchesDirectory], @"/Developer/Library/Patches",
             "the patch sets are read from the checkout that gets updated");
  PASS_EQUAL([SWCheckoutLayout packageListPathForOSIdentifier:@"nextbsd"],
             @"Library/OSSupport/nextbsd.txt",
             "the package list path is relative to the checkout, as git show wants it");

  SWCheckoutLayout *custom = [[[SWCheckoutLayout alloc] initWithDeveloperDirectory:@"/x/Dev"
                                                                   sourcesDirectory:@"/y/Src"] autorelease];
  PASS_EQUAL([custom pathForRepositoryNamed:@"gershwin-developer"], @"/x/Dev",
             "an injected developer directory is honored");
  PASS_EQUAL([custom pathForRepositoryNamed:@"libs-base"], @"/y/Src/libs-base",
             "an injected sources directory is honored");

  [arp release];
  return 0;
}
