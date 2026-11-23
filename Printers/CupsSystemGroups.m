/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "CupsSystemGroups.h"

@implementation CupsSystemGroups

+ (NSArray *)systemGroupsInConfiguration:(NSString *)configuration
{
    NSMutableArray *groups = [NSMutableArray array];
    NSCharacterSet *blanks = [NSCharacterSet whitespaceCharacterSet];
    for (NSString *line in [configuration componentsSeparatedByCharactersInSet:
                            [NSCharacterSet newlineCharacterSet]]) {
        NSMutableArray *words = [NSMutableArray array];
        for (NSString *word in [line componentsSeparatedByCharactersInSet:blanks]) {
            if ([word length] > 0) {
                [words addObject:word];
            }
        }
        /* A directive name is not case sensitive; a comment starts with #. */
        if ([words count] < 2
            || [[words objectAtIndex:0] caseInsensitiveCompare:@"SystemGroup"] != NSOrderedSame) {
            continue;
        }
        for (NSUInteger i = 1; i < [words count]; i++) {
            NSString *group = [words objectAtIndex:i];
            if (![group isEqualToString:@"root"] && ![groups containsObject:group]) {
                [groups addObject:group];
            }
        }
    }
    return groups;
}

+ (NSArray *)systemGroups
{
    for (NSString *path in @[@"/etc/cups/cups-files.conf", @"/usr/local/etc/cups/cups-files.conf"]) {
        NSString *text = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
        if (text != nil) {
            return [self systemGroupsInConfiguration:text];
        }
    }
    return nil;
}

@end
