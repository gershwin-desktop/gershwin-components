/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "XLController.h"
#import "XLXephyr.h"
#import "AppearanceMetrics.h"

static const CGFloat kLabelHeight = 17.0;
static const CGFloat kLabelColumnWidth = 120.0;
static const CGFloat kDimensionFieldWidth = 60.0;
/* Two lines of 11pt text; the longer translations wrap. */
static const CGFloat kHintHeight = 28.0;
static const CGFloat kStatusHeight = 51.0;
static const CGFloat kPollInterval = 0.2;
/* Xephyr only needs to connect to the host display; this is far longer. */
static const NSTimeInterval kStartupTimeout = 10.0;
/* Enough of a log to show the reason, not a screenful of option help. */
static const NSUInteger kLogExcerptLength = 400;

static const NSInteger kDefaultWidth = 1280;
static const NSInteger kDefaultHeight = 720;
static NSString *const kCustomSize = @"Custom";

@interface XLController ()
- (void)showError:(NSString *)message;
- (void)showStatus:(NSString *)message;
- (void)setControlsEnabled:(BOOL)enabled;
- (void)startServer;
- (void)stopServer;
- (void)discardLogs;
- (void)serverEnded;
@end

@implementation XLController

- (void)dealloc
{
    [pollTimer invalidate];
    [xephyrLogPath release];
    [commandLogPath release];
    [commandLine release];
    [startedAt release];
    [xephyrTask release];
    [commandTask release];
    [mainWindow release];
    [sizePopUp release];
    [widthField release];
    [heightField release];
    [screensPopUp release];
    [commandField release];
    [statusLabel release];
    [startStopButton release];
    [super dealloc];
}

#pragma mark - User interface

- (NSTextField *)labelWithString:(NSString *)string frame:(NSRect)frame
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    [label setStringValue:string];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setBezeled:NO];
    [label setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [label setDrawsBackground:YES];
    [label setBackgroundColor:[NSColor windowBackgroundColor]];
    return [label autorelease];
}

- (NSTextField *)fieldWithFrame:(NSRect)frame
{
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    [field setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [field setBezeled:YES];
    [field setDrawsBackground:YES];
    [field setEditable:YES];
    [field setDelegate:self];
    return [field autorelease];
}

- (NSMenu *)addSubmenuWithTitle:(NSString *)title toMenu:(NSMenu *)menu
{
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];
    NSMenu *submenu = [[NSMenu alloc] initWithTitle:title];
    [item setSubmenu:submenu];
    [menu addItem:item];
    [item release];
    return [submenu autorelease];
}

- (void)createMainMenu
{
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"Xephyr"];

    NSMenu *appMenu = [self addSubmenuWithTitle:@"Xephyr" toMenu:mainMenu];
    [appMenu addItemWithTitle:NSLocalizedString(@"About Xephyr", @"")
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:NSLocalizedString(@"Hide Xephyr", @"")
                       action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:NSLocalizedString(@"Hide Others", @"")
                       action:@selector(hideOtherApplications:) keyEquivalent:@""];
    [appMenu addItemWithTitle:NSLocalizedString(@"Show All", @"")
                       action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:NSLocalizedString(@"Quit Xephyr", @"")
                       action:@selector(terminate:) keyEquivalent:@"q"];

    // The text fields need the clipboard shortcuts
    NSMenu *editMenu = [self addSubmenuWithTitle:NSLocalizedString(@"Edit", @"") toMenu:mainMenu];
    [editMenu addItemWithTitle:NSLocalizedString(@"Cut", @"") action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Copy", @"") action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Paste", @"") action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Select All", @"") action:@selector(selectAll:) keyEquivalent:@"a"];

    NSMenu *windowMenu = [self addSubmenuWithTitle:NSLocalizedString(@"Window", @"") toMenu:mainMenu];
    [windowMenu addItemWithTitle:NSLocalizedString(@"Minimize", @"")
                          action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:NSLocalizedString(@"Close", @"")
                          action:@selector(performClose:) keyEquivalent:@"w"];

    [NSApp setMainMenu:mainMenu];
    [NSApp setWindowsMenu:windowMenu];
    [mainMenu release];
}

- (void)createMainWindow
{
    CGFloat width = METRICS_WIN_MIN_WIDTH;
    CGFloat rowHeight = METRICS_TEXT_INPUT_FIELD_HEIGHT;
    CGFloat height = METRICS_CONTENT_TOP_MARGIN
                   + rowHeight + METRICS_SPACE_12      // size
                   + rowHeight + METRICS_SPACE_12      // screens
                   + rowHeight + METRICS_SPACE_8       // command
                   + kHintHeight + METRICS_SPACE_16    // command hint
                   + kStatusHeight + METRICS_SPACE_16
                   + METRICS_BUTTON_HEIGHT
                   + METRICS_CONTENT_BOTTOM_MARGIN;
    CGFloat left = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat controlLeft = left + kLabelColumnWidth;
    CGFloat contentWidth = width - 2 * METRICS_CONTENT_SIDE_MARGIN;
    // Vertically centers the label text on the field text
    CGFloat labelOffset = floor((rowHeight - kLabelHeight) / 2);

    mainWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
                                             styleMask:NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    [mainWindow setTitle:@"Xephyr"];
    [mainWindow setDelegate:self];
    [mainWindow setReleasedWhenClosed:NO];
    NSView *content = [mainWindow contentView];

    // Size row
    CGFloat y = height - METRICS_CONTENT_TOP_MARGIN - rowHeight;
    [content addSubview:[self labelWithString:NSLocalizedString(@"Screen size:", @"")
                                        frame:NSMakeRect(left, y + labelOffset, kLabelColumnWidth, kLabelHeight)]];
    sizePopUp = [[NSPopUpButton alloc] initWithFrame:
        NSMakeRect(controlLeft, y, 150, rowHeight) pullsDown:NO];
    [sizePopUp setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [sizePopUp addItemWithTitle:NSLocalizedString(@"Custom", @"")];
    [[sizePopUp lastItem] setRepresentedObject:kCustomSize];
    NSArray *presets = [NSArray arrayWithObjects:
        @"800x600", @"1024x768", @"1280x720", @"1280x800", @"1366x768",
        @"1600x900", @"1920x1080", nil];
    NSEnumerator *e = [presets objectEnumerator];
    NSString *preset;
    while ((preset = [e nextObject]) != nil) {
        // The title is only for reading; the size comes from the object
        [sizePopUp addItemWithTitle:[preset stringByReplacingOccurrencesOfString:@"x"
                                                                       withString:@" x "]];
        [[sizePopUp lastItem] setRepresentedObject:preset];
    }
    [sizePopUp setTarget:self];
    [sizePopUp setAction:@selector(sizePresetChanged:)];
    [content addSubview:sizePopUp];

    CGFloat fieldLeft = NSMaxX([sizePopUp frame]) + METRICS_SPACE_12;
    widthField = [[self fieldWithFrame:
        NSMakeRect(fieldLeft, y, kDimensionFieldWidth, rowHeight)] retain];
    [widthField setAlignment:NSRightTextAlignment];
    [content addSubview:widthField];
    NSTextField *times = [self labelWithString:@"x" frame:
        NSMakeRect(NSMaxX([widthField frame]) + METRICS_SPACE_8, y + labelOffset, 10, kLabelHeight)];
    [times setAlignment:NSCenterTextAlignment];
    [content addSubview:times];
    heightField = [[self fieldWithFrame:
        NSMakeRect(NSMaxX([times frame]) + METRICS_SPACE_8, y,
                   kDimensionFieldWidth, rowHeight)] retain];
    [content addSubview:heightField];

    // Screens row
    y -= METRICS_SPACE_12 + rowHeight;
    [content addSubview:[self labelWithString:NSLocalizedString(@"Screens:", @"")
                                        frame:NSMakeRect(left, y + labelOffset, kLabelColumnWidth, kLabelHeight)]];
    screensPopUp = [[NSPopUpButton alloc] initWithFrame:
        NSMakeRect(controlLeft, y, 70, rowHeight) pullsDown:NO];
    [screensPopUp setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    NSInteger i;
    for (i = 1; i <= XLMaximumScreenCount; i++) {
        [screensPopUp addItemWithTitle:[NSString stringWithFormat:@"%ld", (long)i]];
    }
    [content addSubview:screensPopUp];

    // Command row
    y -= METRICS_SPACE_12 + rowHeight;
    [content addSubview:[self labelWithString:NSLocalizedString(@"Command:", @"")
                                        frame:NSMakeRect(left, y + labelOffset, kLabelColumnWidth, kLabelHeight)]];
    commandField = [[self fieldWithFrame:
        NSMakeRect(controlLeft, y, contentWidth - kLabelColumnWidth, rowHeight)] retain];
    [commandField setContinuous:NO];
    [content addSubview:commandField];

    y -= METRICS_SPACE_8 + kHintHeight;
    NSTextField *hint = [self labelWithString:
        NSLocalizedString(@"Started on the new display, for example xterm. Leave empty for an empty display.", @"")
        frame:NSMakeRect(controlLeft, y, contentWidth - kLabelColumnWidth, kHintHeight)];
    [[hint cell] setWraps:YES];
    [hint setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [hint setTextColor:[NSColor disabledControlTextColor]];
    [content addSubview:hint];

    // Status; errors can be long, so the label wraps
    y -= METRICS_SPACE_16 + kStatusHeight;
    statusLabel = [[self labelWithString:NSLocalizedString(@"Not running.", @"")
                                   frame:NSMakeRect(left, y, contentWidth, kStatusHeight)] retain];
    [[statusLabel cell] setWraps:YES];
    [[statusLabel cell] setLineBreakMode:NSLineBreakByWordWrapping];
    [content addSubview:statusLabel];

    y -= METRICS_SPACE_16 + METRICS_BUTTON_HEIGHT;
    startStopButton = [[NSButton alloc] initWithFrame:
        NSMakeRect(width - METRICS_CONTENT_SIDE_MARGIN - METRICS_BUTTON_MIN_WIDTH, y,
                   METRICS_BUTTON_MIN_WIDTH, METRICS_BUTTON_HEIGHT)];
    [startStopButton setButtonType:NSMomentaryPushInButton];
    [startStopButton setBezelStyle:NSRoundedBezelStyle];
    [startStopButton setTitle:NSLocalizedString(@"Start", @"")];
    [startStopButton setKeyEquivalent:@"\r"];
    [startStopButton setTarget:self];
    [startStopButton setAction:@selector(startOrStop:)];
    [content addSubview:startStopButton];

    [widthField setIntegerValue:kDefaultWidth];
    [heightField setIntegerValue:kDefaultHeight];
    [sizePopUp selectItemAtIndex:[sizePopUp indexOfItemWithRepresentedObject:@"1280x720"]];
    [mainWindow center];
}

#pragma mark - Status

- (void)showStatus:(NSString *)message
{
    [statusLabel setTextColor:[NSColor controlTextColor]];
    [statusLabel setStringValue:message];
}

- (void)showError:(NSString *)message
{
    [statusLabel setTextColor:[NSColor redColor]];
    [statusLabel setStringValue:message];
}

- (void)setControlsEnabled:(BOOL)enabled
{
    [sizePopUp setEnabled:enabled];
    [widthField setEnabled:enabled];
    [heightField setEnabled:enabled];
    [screensPopUp setEnabled:enabled];
    [commandField setEnabled:enabled];
    [startStopButton setTitle:enabled ? NSLocalizedString(@"Start", @"")
                                      : NSLocalizedString(@"Stop", @"")];
}

#pragma mark - Actions

- (void)sizePresetChanged:(id)sender
{
    NSString *size = [[sizePopUp selectedItem] representedObject];
    NSArray *parts = [size componentsSeparatedByString:@"x"];
    if ([parts count] != 2) {
        return;     // Custom: the fields keep what the user typed
    }
    [widthField setStringValue:[parts objectAtIndex:0]];
    [heightField setStringValue:[parts objectAtIndex:1]];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
    id field = [notification object];
    if (field == widthField || field == heightField) {
        [sizePopUp selectItemAtIndex:[sizePopUp indexOfItemWithRepresentedObject:kCustomSize]];
    }
}

- (void)startOrStop:(id)sender
{
    if (xephyrTask != nil) {
        [self stopServer];
    } else {
        [self startServer];
    }
}

#pragma mark - Processes

/* An empty file the child writes its diagnostics to.  A pipe would block
 * Xephyr once nobody reads it, and the diagnostics are only wanted after
 * something went wrong. */
- (NSString *)createLogFile
{
    NSString *template = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"xephyr-launcher-XXXXXX"];
    char *path = strdup([template fileSystemRepresentation]);
    int fd = mkstemp(path);
    NSString *result = nil;
    if (fd >= 0) {
        close(fd);
        result = [[NSFileManager defaultManager]
            stringWithFileSystemRepresentation:path length:strlen(path)];
    }
    free(path);
    return result;
}

- (NSString *)excerptOfLog:(NSString *)path
{
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding error:NULL];
    text = [text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([text length] > kLogExcerptLength) {
        text = [@"..." stringByAppendingString:
            [text substringFromIndex:[text length] - kLogExcerptLength]];
    }
    return text;
}

- (NSTask *)launchPath:(NSString *)path
             arguments:(NSArray *)arguments
           environment:(NSDictionary *)environment
               logPath:(NSString *)logPath
                 error:(NSString **)error
{
    NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:logPath];
    NSTask *task = [[[NSTask alloc] init] autorelease];
    [task setLaunchPath:path];
    [task setArguments:arguments];
    [task setEnvironment:environment];
    [task setStandardOutput:log];
    [task setStandardError:log];
    @try {
        [task launch];
    } @catch (NSException *exception) {
        *error = [NSString stringWithFormat:
            NSLocalizedString(@"Could not start %@: %@", @""), path, [exception reason]];
        task = nil;
    }
    [log closeFile];
    return task;
}

- (void)startServer
{
    NSInteger width = [XLXephyr dimensionFromString:[widthField stringValue]];
    NSInteger height = [XLXephyr dimensionFromString:[heightField stringValue]];
    NSInteger screens = [[screensPopUp titleOfSelectedItem] integerValue];
    NSString *problem = [XLXephyr validationErrorForWidth:width height:height
                                              screenCount:screens];
    if (problem != nil) {
        [self showError:problem];
        return;
    }

    NSString *xephyr = [XLXephyr xephyrPath];
    if (xephyr == nil) {
        [self showError:NSLocalizedString(
            @"Xephyr is not installed. Install the Xephyr package of your system and try again.", @"")];
        return;
    }

    displayNumber = [XLXephyr firstFreeDisplayNumber];
    if (displayNumber < 0) {
        [self showError:NSLocalizedString(@"No free display number is left.", @"")];
        return;
    }

    xephyrLogPath = [[self createLogFile] retain];
    if (xephyrLogPath == nil) {
        [self showError:NSLocalizedString(@"Could not create a temporary file for the Xephyr messages.", @"")];
        return;
    }

    NSString *error = nil;
    xephyrTask = [[self launchPath:xephyr
                         arguments:[XLXephyr argumentsForDisplayNumber:displayNumber
                                                                 width:width height:height
                                                           screenCount:screens]
                       environment:[[NSProcessInfo processInfo] environment]
                           logPath:xephyrLogPath
                             error:&error] retain];
    if (xephyrTask == nil) {
        [self showError:error];
        [self discardLogs];
        return;
    }

    NSString *command = [[commandField stringValue] stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    commandLine = [command length] > 0 ? [command copy] : nil;
    serverIsUp = NO;
    stopRequested = NO;
    startedAt = [[NSDate alloc] init];
    [self setControlsEnabled:NO];
    [self showStatus:[NSString stringWithFormat:
        NSLocalizedString(@"Starting Xephyr on display %@...", @""),
        [XLXephyr displayStringForNumber:displayNumber]]];
    pollTimer = [NSTimer scheduledTimerWithTimeInterval:kPollInterval
                                                 target:self
                                               selector:@selector(poll:)
                                               userInfo:nil repeats:YES];
}

- (void)stopServer
{
    stopRequested = YES;
    if ([xephyrTask isRunning]) {
        [xephyrTask terminate];
    }
}

- (void)discardLogs
{
    NSFileManager *fm = [NSFileManager defaultManager];
    if (xephyrLogPath != nil) {
        [fm removeItemAtPath:xephyrLogPath error:NULL];
    }
    if (commandLogPath != nil) {
        [fm removeItemAtPath:commandLogPath error:NULL];
    }
    [xephyrLogPath release];
    xephyrLogPath = nil;
    [commandLogPath release];
    commandLogPath = nil;
}

/* Back to the idle state once Xephyr is gone for whatever reason. */
- (void)serverEnded
{
    [pollTimer invalidate];
    pollTimer = nil;
    [xephyrTask release];
    xephyrTask = nil;
    [commandTask release];
    commandTask = nil;
    [commandLine release];
    commandLine = nil;
    [startedAt release];
    startedAt = nil;
    [self discardLogs];
    [self setControlsEnabled:YES];
}

- (void)launchCommand
{
    NSString *error = nil;
    commandLogPath = [[self createLogFile] retain];
    if (commandLogPath == nil) {
        [self showError:NSLocalizedString(@"Could not create a temporary file for the command messages.", @"")];
        return;
    }
    // sh -c so that the field may hold arguments, quoting and pipelines
    commandTask = [[self launchPath:@"/bin/sh"
                          arguments:[NSArray arrayWithObjects:@"-c", commandLine, nil]
                        environment:[XLXephyr environmentForDisplayNumber:displayNumber
                                                          baseEnvironment:[[NSProcessInfo processInfo] environment]]
                            logPath:commandLogPath
                              error:&error] retain];
    if (commandTask == nil) {
        [self showError:error];
    }
}

- (void)poll:(NSTimer *)timer
{
    NSString *display = [XLXephyr displayStringForNumber:displayNumber];

    if (![xephyrTask isRunning]) {
        int status = [xephyrTask terminationStatus];
        if (stopRequested || (serverIsUp && status == 0)) {
            [self serverEnded];
            [self showStatus:[NSString stringWithFormat:
                NSLocalizedString(@"Xephyr on display %@ was closed.", @""), display]];
        } else {
            NSString *log = [self excerptOfLog:xephyrLogPath];
            NSString *message = [NSString stringWithFormat:
                NSLocalizedString(@"Xephyr exited with status %d.", @""), status];
            if ([log length] > 0) {
                message = [NSString stringWithFormat:@"%@\n%@", message, log];
            }
            [self serverEnded];
            [self showError:message];
        }
        return;
    }

    if (!serverIsUp) {
        if ([[NSFileManager defaultManager]
                fileExistsAtPath:[XLXephyr socketPathForDisplayNumber:displayNumber]]) {
            serverIsUp = YES;
            [self showStatus:[NSString stringWithFormat:
                NSLocalizedString(@"Xephyr is running on display %@.", @""), display]];
            if (commandLine != nil) {
                [self launchCommand];
            }
        } else if (-[startedAt timeIntervalSinceNow] > kStartupTimeout) {
            [self stopServer];
            NSString *message = [NSString stringWithFormat:
                NSLocalizedString(@"Xephyr did not open display %@ within %d seconds.", @""),
                display, (int)kStartupTimeout];
            [self serverEnded];
            [self showError:message];
        }
        return;
    }

    if (commandTask != nil && ![commandTask isRunning]) {
        int status = [commandTask terminationStatus];
        if (status != 0) {
            NSString *log = [self excerptOfLog:commandLogPath];
            NSString *message = [NSString stringWithFormat:
                NSLocalizedString(@"The command exited with status %d.", @""), status];
            if ([log length] > 0) {
                message = [NSString stringWithFormat:@"%@\n%@", message, log];
            }
            [self showError:message];
        }
        [commandTask release];
        commandTask = nil;
    }
}

#pragma mark - Delegates

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    [self createMainMenu];
    [self createMainWindow];
    [mainWindow makeKeyAndOrderFront:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    // The nested display belongs to this window; do not leave it behind
    if ([xephyrTask isRunning]) {
        [xephyrTask terminate];
        [xephyrTask waitUntilExit];
    }
    [self discardLogs];
}

@end
