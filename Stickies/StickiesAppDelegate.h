/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

@class StickyNoteController;

@interface StickiesAppDelegate : NSObject <NSApplicationDelegate>
{
    NSApplication *app;
    NSMutableArray *notes;
    NSUserDefaults *defaults;
    NSColor *defaultColor;
    NSFont *defaultFont;
    NSRect defaultFrame;
    BOOL defaultFloatOnTop;
    BOOL defaultTranslucent;
    NSRect defaultCollapsedFrame;
    BOOL defaultCollapsed;
    NSFont *copiedFont;
}

@property (nonatomic, retain) NSApplication *app;
@property (nonatomic, retain) NSMutableArray *notes;
@property (nonatomic, retain) NSUserDefaults *defaults;
@property (nonatomic, retain) NSColor *defaultColor;
@property (nonatomic, retain) NSFont *defaultFont;
@property (nonatomic, assign) NSRect defaultFrame;
@property (nonatomic, assign) BOOL defaultFloatOnTop;
@property (nonatomic, assign) BOOL defaultTranslucent;
@property (nonatomic, assign) NSRect defaultCollapsedFrame;
@property (nonatomic, assign) BOOL defaultCollapsed;
@property (nonatomic, retain) NSFont *copiedFont;

- (void)loadDefaults;
- (void)saveDefaults;
- (void)saveNotes;
- (StickyNoteController *)createNewNoteWithText:(NSString *)text color:(NSColor *)color frame:(NSRect)frame font:(NSFont *)font floatOnTop:(BOOL)floatOnTop translucent:(BOOL)translucent collapsed:(BOOL)collapsed creationDate:(NSDate *)creationDate modificationDate:(NSDate *)modificationDate;
- (void)newNote:(id)sender;
- (void)closeNote:(id)sender;
- (void)printNote:(id)sender;
- (void)showNoteInfo:(id)sender;
- (void)makeNewStickyFromService:(id)sender userData:(NSString *)string;
- (void)useAsDefault:(id)sender;
- (void)showColorPanel:(id)sender;
- (void)showFontPanel:(id)sender;
- (void)makeFloatOnTop:(id)sender;
- (void)makeTranslucent:(id)sender;
- (void)collapseWindow:(id)sender;
- (void)expandWindow:(id)sender;
- (void)zoomWindow:(id)sender;
- (void)arrangeInFront:(id)sender;
- (void)copyFont:(id)sender;
- (void)pasteFont:(id)sender;
- (void)setNoteColor:(id)sender;
- (void)find:(id)sender;
- (void)findNext:(id)sender;
- (void)findPrevious:(id)sender;
- (void)selectAll:(id)sender;
- (void)copy:(id)sender;
- (void)paste:(id)sender;
- (void)cut:(id)sender;
- (void)delete:(id)sender;
- (void)undo:(id)sender;
- (void)redo:(id)sender;
- (void)checkSpelling:(id)sender;

@end