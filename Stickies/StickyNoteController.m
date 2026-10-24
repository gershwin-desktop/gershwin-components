/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "StickyNoteController.h"
#import "StickyNoteWindow.h"
#import "StickyNoteView.h"
#import "StickyNoteDocument.h"
#import "StickyNoteColors.h"
#import "StickyNoteDatabase.h"
#import "StickiesAppDelegate.h"

#define TITLE_BAR_HEIGHT 22.0

@implementation StickyNoteController

@synthesize noteWindow;
@synthesize noteView;
@synthesize document;
@synthesize noteColor;
@synthesize noteFont;
@synthesize noteFrame;
@synthesize floatOnTop;
@synthesize translucent;
@synthesize collapsed;
@synthesize collapsedFrame;
@synthesize creationDate;
@synthesize modificationDate;
@synthesize useAsDefault;

- (id)initWithText:(NSString *)aText color:(NSColor *)aColor frame:(NSRect)aFrame font:(NSFont *)aFont floatOnTop:(BOOL)aFloatOnTop translucent:(BOOL)aTranslucent collapsed:(BOOL)aCollapsed creationDate:(NSDate *)aCreationDate modificationDate:(NSDate *)aModificationDate
{
    self = [super init];
    if (self) {
        self.noteColor = aColor ? aColor : [NSColor yellowColor];
        self.noteFont = aFont ? aFont : [NSFont fontWithName:@"Helvetica" size:14.0];
        self.noteFrame = aFrame;
        self.floatOnTop = aFloatOnTop;
        self.translucent = aTranslucent;
        self.collapsed = aCollapsed;
        self.creationDate = aCreationDate ? aCreationDate : [NSDate date];
        self.modificationDate = aModificationDate ? aModificationDate : [NSDate date];
        StickyNoteDocument *doc = [[StickyNoteDocument alloc]
            initWithText:aText
                   color:aColor
                   frame:aFrame
                    font:aFont
              floatOnTop:aFloatOnTop
            translucent:aTranslucent
               collapsed:aCollapsed
          creationDate:self.creationDate
        modificationDate:self.modificationDate];
        self.document = doc;
        [doc release];

        [self loadWindow];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(autoSave) object:nil];
    [noteWindow setDelegate:nil];
    [noteWindow release];
    [noteView release];
    [document release];
    [noteColor release];
    [noteFont release];
    [creationDate release];
    [modificationDate release];
    [super dealloc];
}

- (void)loadWindow
{
    if (noteWindow) return;
    NSRect winRect = noteFrame;
    if (winRect.size.width < 100) winRect.size.width = 200;
    if (winRect.size.height < 100) winRect.size.height = 200;

    noteWindow = [[StickyNoteWindow alloc]
        initWithContentRect:winRect
                  styleMask:NSBorderlessWindowMask
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [noteWindow setDelegate:self];
    [noteWindow setTitle:@"Sticky Note"];

    noteView = [[StickyNoteView alloc] initWithFrame:NSMakeRect(0, 0, winRect.size.width, winRect.size.height)];
    [noteView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [noteView setNoteColor:noteColor];

    [[noteView textView] setDelegate:self];
    [[noteView textView] setFont:noteFont];

    NSString *noteText = document.text;
    if ([noteText length] > 0) {
        if (document.rtfData) {
            [[noteView textView] replaceCharactersInRange:NSMakeRange(0, 0) withRTF:document.rtfData];
        } else {
            [[noteView textView] insertText:noteText];
        }
    }

    // The text just went in, so the layout manager already knows the
    // document's full height; restore where the note was scrolled to before
    // the scroll view's own frame is possibly still its initial size.
    NSScrollView *restoredScrollView = [[noteView textView] enclosingScrollView];
    [[restoredScrollView contentView] scrollToPoint:document.scrollPosition];
    [restoredScrollView reflectScrolledClipView:[restoredScrollView contentView]];

    [noteWindow setContentView:noteView];

    // A saved note may lie under the menu bar or off a screen that has
    // since shrunk; NSWindow only constrains titled windows by itself.
    [noteWindow setFrame:[noteWindow frameFittingScreen:[noteWindow frame]]
                 display:NO];

    if (collapsed) {
        [noteWindow collapse];
    }

    [self updateWindowAppearance];
}

- (void)showWindow
{
    [noteWindow makeKeyAndOrderFront:self];
    [[noteView window] makeFirstResponder:[noteView textView]];
}

- (void)saveNote
{
    NSString *currentText = [[noteView textView] string];
    document.text = currentText;
    document.rtfData = [[noteView textView] RTFFromRange:NSMakeRange(0, [currentText length])];
    document.color = noteColor;
    document.font = noteFont;
    document.frame = [noteWindow uncollapsedFrame];
    document.floatOnTop = floatOnTop;
    document.translucent = translucent;
    document.collapsed = collapsed;
    document.modificationDate = modificationDate;
    document.scrollPosition = [[[[noteView textView] enclosingScrollView] contentView] bounds].origin;
}

// A manual save (Cmd-S) writes everything now instead of waiting for the
// delayed auto-save, and drops that pending auto-save: it would only rewrite
// what was just written.
- (void)saveNow
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(autoSave)
                                               object:nil];
    StickiesAppDelegate *delegate = (StickiesAppDelegate *)[NSApp delegate];
    if (delegate) {
        [delegate saveNotes];
    } else {
        [self saveNote];
        [[StickyNoteDatabase sharedDatabase] save];
    }
}

- (void)closeNote
{
    NSString *currentText = [[noteView textView] string];
    if ([currentText length] == 0) {
        [[[StickyNoteDatabase sharedDatabase] notes] removeObject:document];
    } else {
        [self saveNote];
    }
    [[StickyNoteDatabase sharedDatabase] save];
    [noteWindow makeFirstResponder:nil];
    [noteWindow close];
}

- (void)windowWillClose:(NSNotification *)notification
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [noteWindow setDelegate:nil];

    StickiesAppDelegate *delegate = (StickiesAppDelegate *)[NSApp delegate];
    if (delegate) {
        [[self retain] autorelease];
        [delegate.notes removeObject:self];
    }
}

- (BOOL)windowShouldClose:(id)sender
{
    [self saveNote];
    return YES;
}

- (NSString *)firstLineOfText
{
    NSString *text = [[noteView textView] string];
    if ([text length] == 0) return nil;
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    return [lines count] > 0 ? [lines objectAtIndex:0] : nil;
}

- (void)updateWindowAppearance
{
    [noteView setNoteColor:noteColor];
    [self updateWindowLevel];
    [self updateTranslucency];
}

- (void)updateWindowLevel
{
    if (floatOnTop) {
        [noteWindow setLevel:NSStatusWindowLevel];
    } else {
        [noteWindow setLevel:NSFloatingWindowLevel];
    }
}

- (void)updateTranslucency
{
    if (translucent) {
        [noteWindow setAlphaValue:0.7];
    } else {
        [noteWindow setAlphaValue:1.0];
    }
}

- (void)collapseWindow
{
    [noteWindow collapse];
}

- (void)expandWindow
{
    [noteWindow expand];
}

- (void)toggleCollapse
{
    [noteWindow toggleCollapse];
}

- (void)toggleFloatOnTop
{
    self.floatOnTop = !floatOnTop;
    [self updateWindowLevel];
}

- (void)toggleTranslucent
{
    self.translucent = !translucent;
    [self updateTranslucency];
}

- (void)toggleUseAsDefault
{
    self.useAsDefault = !useAsDefault;
}

- (void)showNoteInfo
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateStyle:NSDateFormatterMediumStyle];
    [formatter setTimeStyle:NSDateFormatterShortStyle];

    NSString *created = [formatter stringFromDate:creationDate];
    NSString *modified = [formatter stringFromDate:modificationDate];

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Note Info"];
    [alert setInformativeText:[NSString stringWithFormat:
        @"Created: %@\nModified: %@\nColor: %@\nCharacters: %lu",
        created, modified,
        [StickyNoteColors nameForColor:noteColor],
        (unsigned long)[[[noteView textView] string] length]]];
    [alert runModal];
    [alert release];
    [formatter release];
}

- (void)setNoteColor:(NSColor *)color
{
    [color retain];
    [noteColor release];
    noteColor = color;
    [noteView setNoteColor:color];
    [self updateModificationDate];
}

- (void)setNoteFont:(NSFont *)font
{
    [font retain];
    [noteFont release];
    noteFont = font;
    [[noteView textView] setFont:font];
    [self updateModificationDate];
}

- (void)textDidChange:(NSNotification *)notification
{
    [self updateModificationDate];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(autoSave) object:nil];
    [self performSelector:@selector(autoSave) withObject:nil afterDelay:5.0];
}

- (void)autoSave
{
    [self saveNote];
    [[StickyNoteDatabase sharedDatabase] save];
}

- (void)windowDidResize:(NSNotification *)notification
{
    if (!collapsed) {
        noteFrame = [noteWindow frame];
    }
}

- (void)windowDidMove:(NSNotification *)notification
{
    noteFrame = [noteWindow frame];
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
    [noteView setNeedsDisplay:YES];
}

- (void)windowDidResignKey:(NSNotification *)notification
{
    [noteView setNeedsDisplay:YES];
}

- (void)updateModificationDate
{
    self.modificationDate = [NSDate date];
}

@end