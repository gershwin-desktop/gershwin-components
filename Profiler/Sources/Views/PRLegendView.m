/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRLegendView.h"

static const CGFloat kSwatchSize = 10.0;
static const CGFloat kSwatchTextGap = 5.0;
static const CGFloat kEntrySpacing = 16.0;
static const CGFloat kRowHeight = 15.0;

@implementation PRLegendEntry

@synthesize label = _label;
@synthesize color = _color;

+ (PRLegendEntry *)entryWithLabel:(NSString *)label color:(NSColor *)color
{
    PRLegendEntry *entry = [[PRLegendEntry alloc] init];
    [entry setLabel:label];
    [entry setColor:color];
    return entry;
}

@end

@implementation PRLegendView

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self == nil)
        return nil;
    _entries = [NSArray array];
    return self;
}

/* The keys read from the top left down, like the text around them. */
- (BOOL)isFlipped
{
    return YES;
}

- (void)setEntries:(NSArray *)entries
{
    _entries = [entries copy];
    [self setNeedsDisplay:YES];
}

- (NSDictionary *)textAttributes
{
    return @{
        NSFontAttributeName: [NSFont systemFontOfSize:10],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.25
                                                                    alpha:1.0]
    };
}

- (CGFloat)widthOfEntry:(PRLegendEntry *)entry
{
    CGFloat width = [[entry label] sizeWithAttributes:[self textAttributes]].width;
    if ([entry color] != nil)
        width += kSwatchSize + kSwatchTextGap;
    return width;
}

/* Fills origins with the top left corner of every entry, or returns NO when
   they do not all fit into the rows the view is tall enough for. */
- (BOOL)layoutEntries:(NSArray *)entries origins:(NSMutableArray *)origins
{
    CGFloat available = NSWidth([self bounds]);
    NSUInteger rows = (NSUInteger)(NSHeight([self bounds]) / kRowHeight);
    CGFloat x = 0;
    NSUInteger row = 0;

    [origins removeAllObjects];
    if (rows == 0)
        return [entries count] == 0;

    for (PRLegendEntry *entry in entries) {
        CGFloat width = [self widthOfEntry:entry];
        if (x > 0 && x + width > available) {
            row++;
            x = 0;
        }
        if (row >= rows)
            return NO;
        [origins addObject:[NSValue valueWithPoint:
                            NSMakePoint(x, (CGFloat)row * kRowHeight)]];
        x += width + kEntrySpacing;
    }
    return YES;
}

/* Drops keys from the end until the rest fits, and says how many were left
   out in their place. */
- (NSArray *)entriesThatFitWithOrigins:(NSMutableArray *)origins
{
    NSUInteger count = [_entries count];
    for (NSUInteger shown = count; shown > 0; shown--) {
        NSMutableArray *candidate =
            [[_entries subarrayWithRange:NSMakeRange(0, shown)] mutableCopy];
        if (shown < count) {
            unsigned long left = (unsigned long)(count - shown);
            [candidate addObject:
             [PRLegendEntry entryWithLabel:
              [NSString stringWithFormat:@"and %lu more", left] color:nil]];
        }
        if ([self layoutEntries:candidate origins:origins])
            return candidate;
    }

    [origins removeAllObjects];
    return [NSArray array];
}

- (void)drawRect:(NSRect)dirtyRect
{
    (void)dirtyRect;

    NSMutableArray *origins = [NSMutableArray array];
    NSArray *entries = [self entriesThatFitWithOrigins:origins];
    NSDictionary *attributes = [self textAttributes];
    NSUInteger index = 0;

    for (PRLegendEntry *entry in entries) {
        NSPoint origin = [[origins objectAtIndex:index++] pointValue];
        CGFloat textX = origin.x;

        if ([entry color] != nil) {
            NSRect swatch = NSMakeRect(origin.x, origin.y + 2,
                                       kSwatchSize, kSwatchSize);
            [[entry color] set];
            NSRectFill(swatch);
            [[NSColor colorWithCalibratedWhite:0.55 alpha:1.0] set];
            NSFrameRectWithWidth(swatch, 0.5);
            textX += kSwatchSize + kSwatchTextGap;
        }

        [[entry label] drawAtPoint:NSMakePoint(textX, origin.y)
                    withAttributes:attributes];
    }
}

@end
