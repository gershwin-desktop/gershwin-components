/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Which groups may manage printers is whatever the CUPS configuration of the
 * system says (SystemGroup in cups-files.conf), not a name the pane guesses:
 * lpadmin on Debian, sys on Arch, wheel on the BSDs.  Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "CupsSystemGroups.h"

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    START_SET("the groups come from the SystemGroup line")
    {
        PASS_EQUAL([CupsSystemGroups systemGroupsInConfiguration:
                    @"# c\nLogLevel warn\nSystemGroup root lpadmin\nUser lp\n"],
                   (@[@"lpadmin"]), "Debian: lpadmin, root is not a group to join");
        PASS_EQUAL([CupsSystemGroups systemGroupsInConfiguration:@"SystemGroup sys root wheel\n"],
                   (@[@"sys", @"wheel"]), "Arch: the order of the line");
        PASS_EQUAL([CupsSystemGroups systemGroupsInConfiguration:@"SystemGroup wheel\n"],
                   (@[@"wheel"]), "FreeBSD");
    }
    END_SET("the groups come from the SystemGroup line")

    START_SET("the directive is read the way CUPS reads it")
    {
        PASS_EQUAL([CupsSystemGroups systemGroupsInConfiguration:@"  systemgroup\troot   lpadmin  admin \n"],
                   (@[@"lpadmin", @"admin"]), "any case, tabs and spaces");
        PASS_EQUAL([CupsSystemGroups systemGroupsInConfiguration:
                    @"SystemGroup lpadmin\nSystemGroup admin lpadmin\n"],
                   (@[@"lpadmin", @"admin"]), "several lines add up, no duplicates");
        PASS_EQUAL([CupsSystemGroups systemGroupsInConfiguration:
                    @"#SystemGroup nobody\nSystemGroupX nobody\nLogLevel SystemGroup\n"],
                   (@[]), "comments and other directives are not it");
        PASS_EQUAL([CupsSystemGroups systemGroupsInConfiguration:@""], (@[]), "empty");
        PASS_EQUAL([CupsSystemGroups systemGroupsInConfiguration:nil], (@[]), "nothing");
    }
    END_SET("the directive is read the way CUPS reads it")

    [arp release];
    return 0;
}
