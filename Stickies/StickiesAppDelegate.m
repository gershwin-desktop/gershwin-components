/**
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "StickiesAppDelegate.h"
#import "StickyNoteController.h"
#import "StickyNoteWindow.h"
#import "StickyNoteView.h"
#import "StickyNoteDocument.h"
#import "StickyNoteColors.h"
#import "StickyNoteDatabase.h"

@interface StickiesAppDelegate ()
- (StickyNoteController *)activeNoteController;
- (StickyNoteController *)createNewNoteWithDefaults;
@end

@implementation StickiesAppDelegate

@synthesize app;
@synthesize notes;
@synthesize defaults;
@synthesize defaultColor;
@synthesize defaultFont;
@synthesize defaultFrame;
@synthesize defaultFloatOnTop;
@synthesize defaultTranslucent;
@synthesize defaultCollapsedFrame;
@synthesize defaultCollapsed;
@synthesize copiedFont;

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    self.app = [NSApplication sharedApplication];
    self.notes = [NSMutableArray array];

    [[StickyNoteDatabase sharedDatabase] load];
    self.defaults = [NSUserDefaults standardUserDefaults];
    [self loadDefaults];

    [self setupMenu];

    // Clear stale database notes - controllers will register fresh documents
    NSMutableArray *dbNotes = [[StickyNoteDatabase sharedDatabase] notes];
    NSArray *savedNotes = [[dbNotes copy] autorelease];
    [dbNotes removeAllObjects];

    if ([savedNotes count] > 0) {
        for (StickyNoteDocument *doc in savedNotes) {
            StickyNoteController *controller = [self createNewNoteWithText:doc.text
                                                                     color:doc.color
                                                                     frame:doc.frame
                                                                      font:doc.font
                                                               floatOnTop:doc.floatOnTop
                                                              translucent:doc.translucent
                                                                collapsed:doc.collapsed
                                                             creationDate:doc.creationDate
                                                       modificationDate:doc.modificationDate];
            [controller showWindow];
        }
    } else {
        [self newNote:nil];
    }

    [self registerServices];
}

- (void)loadDefaults
{
    NSString *colorName = [defaults objectForKey:@"defaultColor"];
    self.defaultColor = colorName ? [StickyNoteColors colorWithName:colorName] : [StickyNoteColors colorWithName:@"yellow"];
    NSString *fontName = [defaults objectForKey:@"defaultFontName"];
    NSNumber *fontSize = [defaults objectForKey:@"defaultFontSize"];
    if (fontName && fontSize) {
        self.defaultFont = [NSFont fontWithName:fontName size:[fontSize floatValue]];
    }
    if (!defaultFont) {
        self.defaultFont = [NSFont fontWithName:@"Helvetica" size:14.0];
    }
    self.defaultFrame = NSMakeRect(200, 300, 280, 240);
    self.defaultFloatOnTop = [defaults boolForKey:@"defaultFloatOnTop"];
    self.defaultTranslucent = [defaults boolForKey:@"defaultTranslucent"];
}

- (void)saveDefaults
{
    [defaults setObject:[StickyNoteColors nameForColor:defaultColor] forKey:@"defaultColor"];
    [defaults setObject:[defaultFont fontName] forKey:@"defaultFontName"];
    [defaults setObject:[NSNumber numberWithFloat:[defaultFont pointSize]] forKey:@"defaultFontSize"];
    [defaults setBool:defaultFloatOnTop forKey:@"defaultFloatOnTop"];
    [defaults setBool:defaultTranslucent forKey:@"defaultTranslucent"];
    [defaults synchronize];
}

- (void)loadNotes
{
    [notes removeAllObjects];
}

- (void)saveNotes
{
    for (StickyNoteController *nc in notes) {
        [nc saveNote];
    }
    [[StickyNoteDatabase sharedDatabase] save];
}

- (void)setupMenu
{
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];

    // Application menu
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:@"Stickies" action:NULL keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Stickies"];
    [appMenu addItemWithTitle:@"About Stickies" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit Stickies" action:@selector(terminate:) keyEquivalent:@"q"];
    [appMenuItem setSubmenu:appMenu];
    [mainMenu addItem:appMenuItem];

    // File menu
    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] initWithTitle:@"File" action:NULL keyEquivalent:@""];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"New Note" action:@selector(newNote:) keyEquivalent:@"n"];
    [fileMenu addItemWithTitle:@"Close" action:@selector(closeNote:) keyEquivalent:@"w"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"Print..." action:@selector(printNote:) keyEquivalent:@"p"];
    [fileMenuItem setSubmenu:fileMenu];
    [mainMenu addItem:fileMenuItem];

    // Edit menu
    NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:NULL keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Delete" action:@selector(delete:) keyEquivalent:@""];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *findItem = [[NSMenuItem alloc] initWithTitle:@"Find..." action:@selector(find:) keyEquivalent:@"f"];
    [findItem setTag:1];
    [editMenu addItem:findItem];
    [findItem release];
    NSMenuItem *findNextItem = [[NSMenuItem alloc] initWithTitle:@"Find Next" action:@selector(findNext:) keyEquivalent:@"g"];
    [findNextItem setTag:2];
    [editMenu addItem:findNextItem];
    [findNextItem release];
    NSMenuItem *findPrevItem = [[NSMenuItem alloc] initWithTitle:@"Find Previous" action:@selector(findPrevious:) keyEquivalent:@"G"];
    [findPrevItem setTag:3];
    [editMenu addItem:findPrevItem];
    [findPrevItem release];
    [editMenuItem setSubmenu:editMenu];
    [mainMenu addItem:editMenuItem];

    // Font menu
    NSMenuItem *fontMenuItem = [[NSMenuItem alloc] initWithTitle:@"Font" action:NULL keyEquivalent:@""];
    NSMenu *fontMenu = [[NSMenu alloc] initWithTitle:@"Font"];
    [fontMenu addItemWithTitle:@"Show Fonts" action:@selector(showFontPanel:) keyEquivalent:@"t"];
    [fontMenu addItem:[NSMenuItem separatorItem]];
    [fontMenu addItemWithTitle:@"Copy Font" action:@selector(copyFont:) keyEquivalent:@""];
    [fontMenu addItemWithTitle:@"Paste Font" action:@selector(pasteFont:) keyEquivalent:@""];
    [fontMenuItem setSubmenu:fontMenu];
    [mainMenu addItem:fontMenuItem];

    // Color menu
    NSMenuItem *colorMenuItem = [[NSMenuItem alloc] initWithTitle:@"Color" action:NULL keyEquivalent:@""];
    NSMenu *colorMenu = [[NSMenu alloc] initWithTitle:@"Color"];
    [colorMenu addItemWithTitle:@"Show Colors" action:@selector(showColorPanel:) keyEquivalent:@"C"];
    [colorMenuItem setSubmenu:colorMenu];
    [mainMenu addItem:colorMenuItem];

    // Note menu
    NSMenuItem *noteMenuItem = [[NSMenuItem alloc] initWithTitle:@"Note" action:NULL keyEquivalent:@""];
    NSMenu *noteMenu = [[NSMenu alloc] initWithTitle:@"Note"];
    [noteMenu addItemWithTitle:@"Note Info" action:@selector(showNoteInfo:) keyEquivalent:@"i"];
    [noteMenu addItem:[NSMenuItem separatorItem]];
    [noteMenu addItemWithTitle:@"Use as Default" action:@selector(useAsDefault:) keyEquivalent:@""];
    [noteMenu addItem:[NSMenuItem separatorItem]];
    NSMenu *colorsSubmenu = [[NSMenu alloc] initWithTitle:@"Color"];
    id colorItem;
    colorItem = [colorsSubmenu addItemWithTitle:@"Yellow" action:@selector(setNoteColor:) keyEquivalent:@"1"];
    [colorItem setTag:0];
    [colorItem setTarget:self];
    colorItem = [colorsSubmenu addItemWithTitle:@"Blue" action:@selector(setNoteColor:) keyEquivalent:@"2"];
    [colorItem setTag:1];
    [colorItem setTarget:self];
    colorItem = [colorsSubmenu addItemWithTitle:@"Green" action:@selector(setNoteColor:) keyEquivalent:@"3"];
    [colorItem setTag:2];
    [colorItem setTarget:self];
    colorItem = [colorsSubmenu addItemWithTitle:@"Pink" action:@selector(setNoteColor:) keyEquivalent:@"4"];
    [colorItem setTag:3];
    [colorItem setTarget:self];
    colorItem = [colorsSubmenu addItemWithTitle:@"Purple" action:@selector(setNoteColor:) keyEquivalent:@"5"];
    [colorItem setTag:4];
    [colorItem setTarget:self];
    colorItem = [colorsSubmenu addItemWithTitle:@"Gray" action:@selector(setNoteColor:) keyEquivalent:@"6"];
    [colorItem setTag:5];
    [colorItem setTarget:self];
    NSMenuItem *colorsItem = [[NSMenuItem alloc] initWithTitle:@"Color" action:NULL keyEquivalent:@""];
    [colorsItem setSubmenu:colorsSubmenu];
    [noteMenu addItem:colorsItem];
    [noteMenuItem setSubmenu:noteMenu];
    [mainMenu addItem:noteMenuItem];

    // Window menu
    NSMenuItem *windowMenuItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:NULL keyEquivalent:@""];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Collapse" action:@selector(collapseWindow:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Expand" action:@selector(expandWindow:) keyEquivalent:@""];
    [windowMenu addItemWithTitle:@"Zoom" action:@selector(zoomWindow:) keyEquivalent:@""];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *floatItem = [[NSMenuItem alloc] initWithTitle:@"Float on Top" action:@selector(makeFloatOnTop:) keyEquivalent:@"f"];
    [floatItem setKeyEquivalentModifierMask:NSCommandKeyMask | NSAlternateKeyMask];
    [windowMenu addItem:floatItem];
    [floatItem release];
    NSMenuItem *translucentItem = [[NSMenuItem alloc] initWithTitle:@"Translucent" action:@selector(makeTranslucent:) keyEquivalent:@"t"];
    [translucentItem setKeyEquivalentModifierMask:NSCommandKeyMask | NSAlternateKeyMask];
    [windowMenu addItem:translucentItem];
    [translucentItem release];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];
    [windowMenuItem setSubmenu:windowMenu];
    [mainMenu addItem:windowMenuItem];

    [NSApp setMainMenu:mainMenu];
}

- (StickyNoteController *)createNewNoteWithDefaults
{
    StickyNoteController *controller = [self createNewNoteWithText:nil
                                                        color:defaultColor
                                                        frame:defaultFrame
                                                         font:defaultFont
                                                   floatOnTop:defaultFloatOnTop
                                                  translucent:defaultTranslucent
                                                    collapsed:defaultCollapsed
                                                 creationDate:[NSDate date]
                                            modificationDate:[NSDate date]];
    return controller;
}

- (StickyNoteController *)createNewNoteWithText:(NSString *)aText color:(NSColor *)aColor frame:(NSRect)aFrame font:(NSFont *)aFont floatOnTop:(BOOL)aFloatOnTop translucent:(BOOL)aTranslucent collapsed:(BOOL)aCollapsed creationDate:(NSDate *)aCreationDate modificationDate:(NSDate *)aModificationDate
{
    StickyNoteController *controller = [[StickyNoteController alloc]
        initWithText:aText color:aColor frame:aFrame font:aFont
          floatOnTop:aFloatOnTop translucent:aTranslucent collapsed:aCollapsed
        creationDate:aCreationDate modificationDate:aModificationDate];
    [notes addObject:controller];
    [[[StickyNoteDatabase sharedDatabase] notes] addObject:controller.document];
    [controller release];
    return controller;
}

- (StickyNoteController *)activeNoteController
{
    NSWindow *keyWindow = [NSApp keyWindow];
    for (StickyNoteController *nc in notes) {
        if ((NSWindow *)[nc noteWindow] == keyWindow) {
            return nc;
        }
    }
    return [notes lastObject];
}

- (void)updateWindowsItem
{
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)theApp
{
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    [self saveNotes];
    return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    [self saveNotes];
}

#pragma mark - Actions

- (void)newNote:(id)sender
{
    StickyNoteController *controller = [self createNewNoteWithDefaults];
    CGFloat offset = [notes count] * 20;
    NSRect frame = [controller noteWindow].frame;
    frame.origin.x += offset;
    frame.origin.y -= offset;
    [[controller noteWindow] setFrameOrigin:frame.origin];
    [controller showWindow];
}

- (void)closeNote:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        [ctrl closeNote];
    }
}

- (void)printNote:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        NSPrintInfo *printInfo = [NSPrintInfo sharedPrintInfo];
        NSPrintOperation *printOp = [NSPrintOperation printOperationWithView:[[ctrl noteView] textView]
                                                                   printInfo:printInfo];
        [printOp runOperation];
    }
}

- (void)showNoteInfo:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        [ctrl showNoteInfo];
    }
}

- (void)useAsDefault:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        self.defaultColor = ctrl.noteColor;
        self.defaultFont = ctrl.noteFont;
        self.defaultFrame = [ctrl noteWindow].frame;
        [self saveDefaults];
    }
}

- (void)showColorPanel:(id)sender
{
    [[NSColorPanel sharedColorPanel] orderFront:self];
}

- (void)showFontPanel:(id)sender
{
    [[NSFontPanel sharedFontPanel] orderFront:self];
}

- (void)makeFloatOnTop:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        [ctrl toggleFloatOnTop];
    }
}

- (void)makeTranslucent:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        [ctrl toggleTranslucent];
    }
}

- (void)collapseWindow:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        [ctrl collapseWindow];
    }
}

- (void)expandWindow:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        [ctrl expandWindow];
    }
}

- (void)zoomWindow:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        [[ctrl noteWindow] performZoom:self];
    }
}

- (void)arrangeInFront:(id)sender
{
    for (StickyNoteController *ctrl in notes) {
        [[ctrl noteWindow] orderFront:self];
    }
}

- (void)copyFont:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        self.copiedFont = [[[ctrl noteView] textView] font];
    }
}

- (void)pasteFont:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl && copiedFont) {
        [[[ctrl noteView] textView] setFont:copiedFont];
    }
}

- (void)setNoteColor:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        NSInteger tag = [sender tag];
        NSArray *colors = [StickyNoteColors stickyNoteColors];
        if (tag >= 0 && tag < (NSInteger)[colors count]) {
            [ctrl setNoteColor:[colors objectAtIndex:tag]];
        }
    }
}

- (void)find:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        [[[ctrl noteView] textView] performFindPanelAction:sender];
    }
}

- (void)findNext:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        [[[ctrl noteView] textView] performFindPanelAction:sender];
    }
}

- (void)findPrevious:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        [[[ctrl noteView] textView] performFindPanelAction:sender];
    }
}

- (void)selectAll:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        [[[ctrl noteView] textView] selectAll:sender];
    }
}

- (void)copy:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        [[[ctrl noteView] textView] copy:sender];
    }
}

- (void)paste:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        [[[ctrl noteView] textView] paste:sender];
    }
}

- (void)cut:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        [[[ctrl noteView] textView] cut:sender];
    }
}

- (void)delete:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        [[[ctrl noteView] textView] delete:sender];
    }
}

- (void)undo:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        [NSApp sendAction:@selector(undo:) to:nil from:sender];
    }
}

- (void)redo:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        [NSApp sendAction:@selector(redo:) to:nil from:sender];
    }
}

- (void)checkSpelling:(id)sender
{
    StickyNoteController *ctrl = [self activeNoteController];
    if (ctrl) {
        [[[ctrl noteView] textView] checkSpelling:sender];
    }
}

- (void)registerServices
{
    [NSApp setServicesProvider:self];
}

- (void)makeNewStickyFromService:(id)sender userData:(NSString *)string
{
    if ([string length] > 0) {
        StickyNoteController *ctrl = [self createNewNoteWithDefaults];
        [ctrl noteView];
        [[[ctrl noteView] textView] insertText:string];
        [ctrl showWindow];
    }
}

- (void)dealloc
{
    [notes release];
    [defaults release];
    [defaultColor release];
    [defaultFont release];
    [copiedFont release];
    [super dealloc];
}

@end