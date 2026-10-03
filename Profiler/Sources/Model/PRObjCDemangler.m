/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRObjCDemangler.h"

@implementation PRObjCDemangler

/* The mangling replaces every colon of the selector with an underscore, so a
   selector that took arguments always ends in one. Leading underscores are
   part of the selector name itself and are kept. */
+ (NSString *)selectorFromMangled:(NSString *)mangled
{
    if (![mangled hasSuffix:@"_"])
        return mangled;

    NSUInteger leading = 0;
    while (leading < [mangled length] &&
           [mangled characterAtIndex:leading] == '_')
        leading++;
    if (leading == [mangled length])
        return mangled;

    NSString *prefix = [mangled substringToIndex:leading];
    NSString *body = [mangled substringFromIndex:leading];
    body = [body stringByReplacingOccurrencesOfString:@"_" withString:@":"];
    return [prefix stringByAppendingString:body];
}

+ (NSString *)demangle:(NSString *)rawName
             className:(NSString **)classNameOut
{
    if (classNameOut)
        *classNameOut = nil;
    if ([rawName length] < 5)
        return rawName;

    BOOL instanceMethod = [rawName hasPrefix:@"_i_"];
    if (!instanceMethod && ![rawName hasPrefix:@"_c_"])
        return rawName;

    NSString *rest = [rawName substringFromIndex:3];
    NSRange sep = [rest rangeOfString:@"_"];
    if (sep.location == NSNotFound || sep.location == 0)
        return rawName;

    NSString *className = [rest substringToIndex:sep.location];
    NSString *afterClass = [rest substringFromIndex:NSMaxRange(sep)];
    NSRange sep2 = [afterClass rangeOfString:@"_"];
    if (sep2.location == NSNotFound)
        return rawName;

    NSString *category = [afterClass substringToIndex:sep2.location];
    NSString *selector = [afterClass substringFromIndex:NSMaxRange(sep2)];
    if ([selector length] == 0)
        return rawName;

    selector = [self selectorFromMangled:selector];
    if (classNameOut)
        *classNameOut = className;

    if ([category length] > 0)
        return [NSString stringWithFormat:@"%@[%@(%@) %@]",
                instanceMethod ? @"-" : @"+", className, category, selector];
    return [NSString stringWithFormat:@"%@[%@ %@]",
            instanceMethod ? @"-" : @"+", className, selector];
}

@end
