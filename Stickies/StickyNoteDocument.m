/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "StickyNoteDocument.h"
#import "StickyNoteColors.h"

@implementation StickyNoteDocument

@synthesize text;
@synthesize rtfData;
@synthesize color;
@synthesize font;
@synthesize frame;
@synthesize floatOnTop;
@synthesize translucent;
@synthesize collapsed;
@synthesize collapsedFrame;
@synthesize creationDate;
@synthesize modificationDate;
@synthesize useAsDefault;
@synthesize scrollPosition;

- (id)initWithText:(NSString *)aText color:(NSColor *)aColor frame:(NSRect)aFrame font:(NSFont *)aFont floatOnTop:(BOOL)aFloatOnTop translucent:(BOOL)aTranslucent collapsed:(BOOL)aCollapsed creationDate:(NSDate *)aCreationDate modificationDate:(NSDate *)aModificationDate
{
    self = [super init];
    if (self) {
        self.text = aText ? aText : @"";
        self.color = aColor ? aColor : [StickyNoteColors colorWithName:@"yellow"];
        self.frame = aFrame;
        self.font = aFont ? aFont : [NSFont fontWithName:@"Helvetica" size:14.0];
        self.floatOnTop = aFloatOnTop;
        self.translucent = aTranslucent;
        self.collapsed = aCollapsed;
        self.collapsedFrame = aFrame;
        NSRect cf = self.collapsedFrame;
        cf.size.height = 24;
        self.collapsedFrame = cf;
        self.creationDate = aCreationDate ? aCreationDate : [NSDate date];
        self.modificationDate = aModificationDate ? aModificationDate : [NSDate date];
        self.useAsDefault = NO;
        self.scrollPosition = NSZeroPoint;
    }
    return self;
}

- (NSDictionary *)dictionaryRepresentation
{
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (rtfData) {
        [dict setObject:rtfData forKey:@"rtfData"];
    }
    if (text) {
        [dict setObject:text forKey:@"text"];
    }
    NSString *colorName = [StickyNoteColors nameForColor:color];
    if (colorName) {
        [dict setObject:colorName forKey:@"color"];
    }
    if (font) {
        [dict setObject:[font fontName] forKey:@"fontName"];
        [dict setObject:[NSNumber numberWithFloat:[font pointSize]] forKey:@"fontSize"];
    }
    [dict setObject:[NSNumber numberWithFloat:frame.origin.x] forKey:@"frameX"];
    [dict setObject:[NSNumber numberWithFloat:frame.origin.y] forKey:@"frameY"];
    [dict setObject:[NSNumber numberWithFloat:frame.size.width] forKey:@"frameWidth"];
    [dict setObject:[NSNumber numberWithFloat:frame.size.height] forKey:@"frameHeight"];
    [dict setObject:[NSNumber numberWithBool:floatOnTop] forKey:@"floatOnTop"];
    [dict setObject:[NSNumber numberWithBool:translucent] forKey:@"translucent"];
    [dict setObject:[NSNumber numberWithBool:collapsed] forKey:@"collapsed"];
    [dict setObject:[NSNumber numberWithFloat:scrollPosition.x] forKey:@"scrollX"];
    [dict setObject:[NSNumber numberWithFloat:scrollPosition.y] forKey:@"scrollY"];
    if (creationDate) {
        [dict setObject:creationDate forKey:@"creationDate"];
    }
    if (modificationDate) {
        [dict setObject:modificationDate forKey:@"modificationDate"];
    }
    return dict;
}

- (id)initWithDictionary:(NSDictionary *)dict
{
    if (![dict isKindOfClass:[NSDictionary class]]) {
        [self release];
        return nil;
    }
    self = [super init];
    if (self) {
        rtfData = [[dict objectForKey:@"rtfData"] copy];
        text = [[dict objectForKey:@"text"] copy];
        if (![text isKindOfClass:[NSString class]]) {
            [text release];
            text = @"";
        }
        id colorName = [dict objectForKey:@"color"];
        if ([colorName isKindOfClass:[NSString class]]) {
            self.color = [StickyNoteColors colorWithName:colorName];
        } else {
            self.color = [StickyNoteColors colorWithName:@"yellow"];
        }
        NSString *fontName = nil;
        NSNumber *fontSize = nil;
        id obj = [dict objectForKey:@"fontName"];
        if ([obj isKindOfClass:[NSString class]]) fontName = obj;
        obj = [dict objectForKey:@"fontSize"];
        if ([obj isKindOfClass:[NSNumber class]]) fontSize = obj;
        if (fontName && fontSize) {
            self.font = [NSFont fontWithName:fontName size:[fontSize floatValue]];
        }
        if (!font) {
            self.font = [NSFont fontWithName:@"Helvetica" size:14.0];
        }
        frame.origin.x = [[dict objectForKey:@"frameX"] floatValue];
        frame.origin.y = [[dict objectForKey:@"frameY"] floatValue];
        frame.size.width = [[dict objectForKey:@"frameWidth"] floatValue];
        frame.size.height = [[dict objectForKey:@"frameHeight"] floatValue];
        floatOnTop = [[dict objectForKey:@"floatOnTop"] boolValue];
        translucent = [[dict objectForKey:@"translucent"] boolValue];
        collapsed = [[dict objectForKey:@"collapsed"] boolValue];
        // Missing in a database written before scroll position was tracked;
        // NSNumber's floatValue on a nil key is 0, matching the top of the note.
        scrollPosition.x = [[dict objectForKey:@"scrollX"] floatValue];
        scrollPosition.y = [[dict objectForKey:@"scrollY"] floatValue];
        id dateObj = [dict objectForKey:@"creationDate"];
        if ([dateObj isKindOfClass:[NSDate class]]) {
            creationDate = [dateObj copy];
        }
        if (!creationDate) creationDate = [[NSDate date] retain];
        dateObj = [dict objectForKey:@"modificationDate"];
        if ([dateObj isKindOfClass:[NSDate class]]) {
            modificationDate = [dateObj copy];
        }
        if (!modificationDate) modificationDate = [[NSDate date] retain];
    }
    return self;
}

- (void)dealloc
{
    [text release];
    [rtfData release];
    [color release];
    [font release];
    [creationDate release];
    [modificationDate release];
    [super dealloc];
}

@end