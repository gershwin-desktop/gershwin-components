/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRStackParser.h"
#import "PRProfile.h"
#import "PRSymbol.h"

@implementation PRStackParser

@synthesize profile = _profile;

- (id)initWithProfile:(PRProfile *)profile
{
    self = [super init];
    if (self == nil)
        return nil;
    _profile = profile;
    return self;
}

- (void)parseLine:(NSString *)line
{
    (void)line;
}

- (void)finish
{
}

- (void)parseString:(NSString *)text
{
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    for (NSString *line in lines)
        [self parseLine:line];
    [self finish];
}

@end

@implementation PRPerfScriptParser
{
    NSMutableArray *_frames;   /* innermost first, as perf prints them */
    double _time;
    int32_t _thread;
    BOOL _inSample;
}

- (id)initWithProfile:(PRProfile *)profile
{
    self = [super initWithProfile:profile];
    if (self == nil)
        return nil;
    _frames = [[NSMutableArray alloc] init];
    return self;
}

- (void)flushSample
{
    if ([_frames count] > 0) {
        /* perf prints the innermost frame first; the profile stores stacks
           the other way round so that the call tree grows from main(). */
        NSArray *outermostFirst = [[_frames reverseObjectEnumerator] allObjects];
        [_profile addSampleWithSymbols:outermostFirst
                                weight:1.0
                                  time:_time
                                thread:_thread];
    }
    [_frames removeAllObjects];
    _inSample = NO;
}

/* "Workspace 8821/8821 43226.865133: cycles:P:" - the command name may
   contain spaces, so the pid/tid pair is located first and everything
   before it taken as the name. */
- (BOOL)parseHeader:(NSString *)line
{
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *field in [line componentsSeparatedByCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]])
        if ([field length] > 0)
            [fields addObject:field];
    NSUInteger idsIndex = NSNotFound;
    NSRange slash = NSMakeRange(NSNotFound, 0);

    for (NSUInteger i = 0; i < [fields count]; i++) {
        NSString *field = [fields objectAtIndex:i];
        slash = [field rangeOfString:@"/"];
        if (slash.location == NSNotFound || slash.location == 0)
            continue;
        unichar first = [field characterAtIndex:0];
        if (first < '0' || first > '9')
            continue;
        idsIndex = i;
        break;
    }
    if (idsIndex == NSNotFound || idsIndex + 1 >= [fields count])
        return NO;

    NSString *ids = [fields objectAtIndex:idsIndex];
    _thread = (int32_t)[[ids substringFromIndex:NSMaxRange(slash)] intValue];

    NSString *stamp = [fields objectAtIndex:idsIndex + 1];
    if ([stamp hasSuffix:@":"])
        stamp = [stamp substringToIndex:[stamp length] - 1];
    _time = [stamp doubleValue];

    NSMutableString *comm = [NSMutableString string];
    for (NSUInteger i = 0; i < idsIndex; i++) {
        if ([comm length])
            [comm appendString:@" "];
        [comm appendString:[fields objectAtIndex:i]];
    }
    if ([comm length])
        [_profile setName:comm forThread:_thread];

    return YES;
}

/* "    7f100fe2b90a objc_msgSend (/System/Library/Libraries/libobjc.so.4.6)"
   The symbol itself may contain spaces (C++ templates), so the binary is
   taken from the trailing parenthesis and the address from the front. */
- (void)parseFrame:(NSString *)line
{
    NSString *trimmed = [line stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceCharacterSet]];
    NSString *module = @"[unknown]";

    /* The binary is the last parenthesised group, and it may itself contain
       parentheses because perf marks a replaced file as "(deleted)", so the
       opening bracket is found by counting pairs from the end. */
    if ([trimmed hasSuffix:@")"]) {
        NSInteger depth = 0;
        NSInteger index = (NSInteger)[trimmed length] - 1;
        for (; index >= 0; index--) {
            unichar c = [trimmed characterAtIndex:index];
            if (c == ')')
                depth++;
            else if (c == '(') {
                depth--;
                if (depth == 0)
                    break;
            }
        }
        if (index > 0 && [trimmed characterAtIndex:index - 1] == ' ') {
            module = [trimmed substringWithRange:
                      NSMakeRange(index + 1,
                                  [trimmed length] - index - 2)];
            trimmed = [trimmed substringToIndex:index - 1];
        }
    }

    NSRange space = [trimmed rangeOfString:@" "];
    NSString *name = @"[unknown]";
    if (space.location != NSNotFound)
        name = [trimmed substringFromIndex:NSMaxRange(space)];
    else if ([trimmed length] > 0)
        name = trimmed;   /* address only, no symbol resolved */

    name = [name stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
    if ([name length] == 0)
        name = @"[unknown]";

    [_frames addObject:[_profile symbolWithName:name modulePath:module]];
}

- (void)parseLine:(NSString *)line
{
    if ([line length] == 0) {
        [self flushSample];
        return;
    }

    unichar first = [line characterAtIndex:0];
    if (first == ' ' || first == '\t') {
        if (_inSample)
            [self parseFrame:line];
        return;
    }

    if (first == '#')
        return;

    [self flushSample];
    _inSample = [self parseHeader:line];
}

- (void)finish
{
    [self flushSample];
}

@end

@implementation PRFoldedStackParser

/* "main (m.c);leaky (m.c); 5000000" - the weight is the last field, the
   frames before it are separated by semicolons. A frame's parenthesised
   suffix names the binary or source file it came from. */
- (void)parseLine:(NSString *)line
{
    NSString *trimmed = [line stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed length] == 0 || [trimmed hasPrefix:@"#"])
        return;

    NSRange space = [trimmed rangeOfString:@" " options:NSBackwardsSearch];
    if (space.location == NSNotFound)
        return;

    double weight = [[trimmed substringFromIndex:NSMaxRange(space)] doubleValue];
    if (weight <= 0)
        return;

    NSString *stack = [trimmed substringToIndex:space.location];
    while ([stack hasSuffix:@";"])
        stack = [stack substringToIndex:[stack length] - 1];

    NSMutableArray *symbols = [NSMutableArray array];
    for (NSString *frame in [stack componentsSeparatedByString:@";"]) {
        NSString *name = frame;
        NSString *module = @"[unknown]";
        if ([name hasSuffix:@")"]) {
            NSRange open = [name rangeOfString:@" (" options:NSBackwardsSearch];
            if (open.location != NSNotFound) {
                module = [name substringWithRange:
                          NSMakeRange(NSMaxRange(open),
                                      [name length] - NSMaxRange(open) - 1)];
                name = [name substringToIndex:open.location];
            }
        }
        if ([name length] == 0)
            name = @"[unknown]";
        [symbols addObject:[_profile symbolWithName:name modulePath:module]];
    }

    if ([symbols count] > 0)
        [_profile addSampleWithSymbols:symbols weight:weight time:NAN thread:0];
}

@end

@implementation PRDTraceStackParser
{
    NSMutableArray *_frames;
}

- (id)initWithProfile:(PRProfile *)profile
{
    self = [super initWithProfile:profile];
    if (self == nil)
        return nil;
    _frames = [[NSMutableArray alloc] init];
    return self;
}

/* DTrace prints an aggregation as the stack, innermost frame first and
   indented, followed by the aggregated value on a line of its own:

       libgnustep-base.so.1.31`_i_NSRunLoop__runMode_beforeDate_+0x2a
       Workspace`main+0x1f
               42
*/
- (void)parseLine:(NSString *)line
{
    NSString *trimmed = [line stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed length] == 0)
        return;

    BOOL isNumber = YES;
    for (NSUInteger i = 0; i < [trimmed length]; i++) {
        unichar c = [trimmed characterAtIndex:i];
        if (c < '0' || c > '9') {
            isNumber = NO;
            break;
        }
    }

    if (isNumber) {
        if ([_frames count] > 0) {
            NSArray *outermostFirst = [[_frames reverseObjectEnumerator] allObjects];
            [_profile addSampleWithSymbols:outermostFirst
                                    weight:[trimmed doubleValue]
                                      time:NAN
                                    thread:0];
        }
        [_frames removeAllObjects];
        return;
    }

    NSString *module = @"[unknown]";
    NSString *name = trimmed;
    NSRange tick = [trimmed rangeOfString:@"`"];
    if (tick.location != NSNotFound) {
        module = [trimmed substringToIndex:tick.location];
        name = [trimmed substringFromIndex:NSMaxRange(tick)];
    }
    NSRange plus = [name rangeOfString:@"+" options:NSBackwardsSearch];
    if (plus.location != NSNotFound)
        name = [name substringToIndex:plus.location];

    [_frames addObject:[_profile symbolWithName:name modulePath:module]];
}

- (void)finish
{
    [_frames removeAllObjects];
}

@end
