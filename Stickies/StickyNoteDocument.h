/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface StickyNoteDocument : NSObject
{
    NSString *text;
    NSData *rtfData;
    NSColor *color;
    NSFont *font;
    NSRect frame;
    BOOL floatOnTop;
    BOOL translucent;
    BOOL collapsed;
    NSRect collapsedFrame;
    NSDate *creationDate;
    NSDate *modificationDate;
    BOOL useAsDefault;
    NSPoint scrollPosition;
}

@property (nonatomic, copy) NSString *text;
@property (nonatomic, retain) NSData *rtfData;
@property (nonatomic, retain) NSColor *color;
@property (nonatomic, retain) NSFont *font;
@property (nonatomic, assign) NSRect frame;
@property (nonatomic, assign) BOOL floatOnTop;
@property (nonatomic, assign) BOOL translucent;
@property (nonatomic, assign) BOOL collapsed;
@property (nonatomic, assign) NSRect collapsedFrame;
@property (nonatomic, retain) NSDate *creationDate;
@property (nonatomic, retain) NSDate *modificationDate;
@property (nonatomic, assign) BOOL useAsDefault;
// Where the note's text was scrolled to, so a long note reopens showing the
// same lines instead of snapping back to the top.
@property (nonatomic, assign) NSPoint scrollPosition;

- (id)initWithText:(NSString *)text color:(NSColor *)color frame:(NSRect)frame font:(NSFont *)font floatOnTop:(BOOL)floatOnTop translucent:(BOOL)translucent collapsed:(BOOL)collapsed creationDate:(NSDate *)creationDate modificationDate:(NSDate *)modificationDate;
- (NSDictionary *)dictionaryRepresentation;
- (id)initWithDictionary:(NSDictionary *)dict;

@end