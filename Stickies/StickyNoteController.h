/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

@class StickyNoteWindow;
@class StickyNoteView;
@class StickyNoteDocument;

@interface StickyNoteController : NSWindowController
{
    StickyNoteWindow *noteWindow;
    StickyNoteView *noteView;
    StickyNoteDocument *document;
    NSColor *noteColor;
    NSFont *noteFont;
    NSRect noteFrame;
    BOOL floatOnTop;
    BOOL translucent;
    BOOL collapsed;
    NSRect collapsedFrame;
    NSDate *creationDate;
    NSDate *modificationDate;
    BOOL useAsDefault;
}

@property (nonatomic, retain) StickyNoteWindow *noteWindow;
@property (nonatomic, retain) StickyNoteView *noteView;
@property (nonatomic, retain) StickyNoteDocument *document;
@property (nonatomic, retain) NSColor *noteColor;
@property (nonatomic, retain) NSFont *noteFont;
@property (nonatomic, assign) NSRect noteFrame;
@property (nonatomic, assign) BOOL floatOnTop;
@property (nonatomic, assign) BOOL translucent;
@property (nonatomic, assign) BOOL collapsed;
@property (nonatomic, assign) NSRect collapsedFrame;
@property (nonatomic, retain) NSDate *creationDate;
@property (nonatomic, retain) NSDate *modificationDate;
@property (nonatomic, assign) BOOL useAsDefault;

- (id)initWithText:(NSString *)text color:(NSColor *)color frame:(NSRect)frame font:(NSFont *)font floatOnTop:(BOOL)floatOnTop translucent:(BOOL)translucent collapsed:(BOOL)collapsed creationDate:(NSDate *)creationDate modificationDate:(NSDate *)modificationDate;
- (void)loadWindow;
- (void)showWindow;
- (void)saveNote;
- (void)saveNow;
- (void)closeNote;
- (void)updateWindowAppearance;
- (void)updateWindowLevel;
- (void)updateTranslucency;
- (void)collapseWindow;
- (void)expandWindow;
- (void)toggleCollapse;
- (void)toggleFloatOnTop;
- (void)toggleTranslucent;
- (void)toggleUseAsDefault;
- (void)showNoteInfo;
- (void)setNoteColor:(NSColor *)color;
- (void)setNoteFont:(NSFont *)font;
- (void)textDidChange:(NSNotification *)notification;
- (void)windowDidResize:(NSNotification *)notification;
- (void)windowDidMove:(NSNotification *)notification;
- (void)windowDidBecomeKey:(NSNotification *)notification;
- (void)windowDidResignKey:(NSNotification *)notification;
- (BOOL)windowShouldClose:(id)sender;
- (void)windowWillClose:(NSNotification *)notification;
- (void)updateModificationDate;

@end