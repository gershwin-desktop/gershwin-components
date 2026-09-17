/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ScreenshotController.h"
#import "ScreenshotActionPanel.h"
#import "AppearanceMetrics.h"

/* Height of a one-line label in the 13pt system font without clipping. */
static const CGFloat kLabelHeight = 17.0;
static const CGFloat kDelayFieldWidth = 50.0;
static const CGFloat kPreferencesWidth = 320.0;

/* The countdown cannot be interrupted, so a typo must not lock the
 * controls for a long time. */
static const int kMaximumDelay = 60;

/* orderOut: reaches the X server only once the run loop flushes, and the
 * window manager and compositor then need to repaint what the window
 * covered; capturing earlier would include our own window. */
static const NSTimeInterval kWindowHideSettleDelay = 0.3;

@implementation ScreenshotController

- (void)dealloc
{
    [countdownTimer invalidate];
    [countdownTimer release];
    [windowsHiddenForCapture release];
    [capturedImage release];
    [capturedPNG release];
    [ocrTask release];
    [ocrInputPath release];
    [statusLabel release];
    [windowButton release];
    [areaButton release];
    [screenButton release];
    [delayField release];
    [progressIndicator release];
    [frameCheckbox release];
    [shadowCheckbox release];
    [actionPanel release];
    [preferencesWindow release];
    [mainWindow release];
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
    // Opaque, so changing text never leaves stale glyphs behind
    [label setDrawsBackground:YES];
    [label setBackgroundColor:[NSColor windowBackgroundColor]];
    return [label autorelease];
}

- (NSButton *)buttonWithTitle:(NSString *)title action:(SEL)action frame:(NSRect)frame
{
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    [button setTitle:title];
    [button setButtonType:NSMomentaryPushInButton];
    [button setBezelStyle:NSRoundedBezelStyle];
    [button setTarget:self];
    [button setAction:action];
    return [button autorelease];
}

- (NSButton *)checkboxWithTitle:(NSString *)title state:(BOOL)state
                         action:(SEL)action frame:(NSRect)frame
{
    NSButton *checkbox = [[NSButton alloc] initWithFrame:frame];
    [checkbox setButtonType:NSSwitchButton];
    [checkbox setTitle:title];
    [checkbox setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [checkbox setState:state ? NSOnState : NSOffState];
    [checkbox setTarget:self];
    [checkbox setAction:action];
    return [checkbox autorelease];
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
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"Screenshot"];

    NSMenu *appMenu = [self addSubmenuWithTitle:@"Screenshot" toMenu:mainMenu];
    [appMenu addItemWithTitle:NSLocalizedString(@"About Screenshot", @"")
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    // The controller is not in the responder chain, so target it directly
    [[appMenu addItemWithTitle:NSLocalizedString(@"Preferences...", @"")
                        action:@selector(showPreferences:)
                 keyEquivalent:@","] setTarget:self];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:NSLocalizedString(@"Hide Screenshot", @"")
                       action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:NSLocalizedString(@"Hide Others", @"")
                       action:@selector(hideOtherApplications:) keyEquivalent:@""];
    [appMenu addItemWithTitle:NSLocalizedString(@"Show All", @"")
                       action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:NSLocalizedString(@"Quit Screenshot", @"")
                       action:@selector(terminate:) keyEquivalent:@"q"];

    // Needed for the delay field's clipboard shortcuts
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
    CGFloat height = METRICS_CONTENT_TOP_MARGIN + kLabelHeight
                   + METRICS_SPACE_16 + kLabelHeight
                   + METRICS_SPACE_8 + METRICS_BUTTON_HEIGHT
                   + METRICS_SPACE_16 + METRICS_TEXT_INPUT_FIELD_HEIGHT
                   + METRICS_CONTENT_BOTTOM_MARGIN;
    CGFloat left = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat contentWidth = width - 2 * METRICS_CONTENT_SIDE_MARGIN;

    mainWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
                                             styleMask:NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    [mainWindow setTitle:@"Screenshot"];
    [mainWindow setDelegate:self];
    [mainWindow setReleasedWhenClosed:NO];
    // Capturing another application deactivates us; the window must stay
    [mainWindow setHidesOnDeactivate:NO];
    NSView *content = [mainWindow contentView];

    CGFloat y = height - METRICS_CONTENT_TOP_MARGIN - kLabelHeight;
    statusLabel = [[self labelWithString:NSLocalizedString(@"Ready to take screenshot", @"")
                                   frame:NSMakeRect(left, y, contentWidth, kLabelHeight)] retain];
    [content addSubview:statusLabel];

    y -= METRICS_SPACE_16 + kLabelHeight;
    [content addSubview:[self labelWithString:NSLocalizedString(@"Select capture mode:", @"")
                                        frame:NSMakeRect(left, y, contentWidth, kLabelHeight)]];

    y -= METRICS_SPACE_8 + METRICS_BUTTON_HEIGHT;
    // Whole pixels keep the bezels crisp; the last button takes the remainder
    CGFloat spacing = METRICS_BUTTON_HORIZ_INTERSPACE;
    CGFloat buttonWidth = floor((contentWidth - 2 * spacing) / 3);
    CGFloat lastWidth = contentWidth - 2 * (buttonWidth + spacing);
    windowButton = [[self buttonWithTitle:NSLocalizedString(@"Window", @"")
                                  action:@selector(takeWindowScreenshot:)
                                   frame:NSMakeRect(left, y, buttonWidth, METRICS_BUTTON_HEIGHT)] retain];
    areaButton = [[self buttonWithTitle:NSLocalizedString(@"Area", @"")
                                action:@selector(takeAreaScreenshot:)
                                 frame:NSMakeRect(left + buttonWidth + spacing, y,
                                                  buttonWidth, METRICS_BUTTON_HEIGHT)] retain];
    screenButton = [[self buttonWithTitle:NSLocalizedString(@"Full Screen", @"")
                                  action:@selector(takeScreenScreenshot:)
                                   frame:NSMakeRect(left + 2 * (buttonWidth + spacing), y,
                                                    lastWidth, METRICS_BUTTON_HEIGHT)] retain];
    [content addSubview:windowButton];
    [content addSubview:areaButton];
    [content addSubview:screenButton];

    y -= METRICS_SPACE_16 + METRICS_TEXT_INPUT_FIELD_HEIGHT;
    // Vertically centers the label text on the field text
    CGFloat labelOffset = floor((METRICS_TEXT_INPUT_FIELD_HEIGHT - kLabelHeight) / 2);
    NSTextField *delayLabel = [self labelWithString:NSLocalizedString(@"Delay (seconds):", @"")
                                              frame:NSMakeRect(left, y + labelOffset, 0, kLabelHeight)];
    [delayLabel sizeToFit];
    [delayLabel setFrame:NSMakeRect(left, y + labelOffset,
                                    ceil(NSWidth([delayLabel frame])), kLabelHeight)];
    [content addSubview:delayLabel];

    delayField = [[NSTextField alloc] initWithFrame:
        NSMakeRect(NSMaxX([delayLabel frame]) + METRICS_SPACE_8, y,
                   kDelayFieldWidth, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
    [delayField setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [delayField setBezeled:YES];
    [delayField setDrawsBackground:YES];
    [delayField setEditable:YES];
    [delayField setAlignment:NSRightTextAlignment];
    [delayField setIntValue:0];
    [content addSubview:delayField];

    CGFloat spinnerSize = 16.0;
    progressIndicator = [[NSProgressIndicator alloc] initWithFrame:
        NSMakeRect(width - METRICS_CONTENT_SIDE_MARGIN - spinnerSize,
                   y + floor((METRICS_TEXT_INPUT_FIELD_HEIGHT - spinnerSize) / 2),
                   spinnerSize, spinnerSize)];
    [progressIndicator setStyle:NSProgressIndicatorSpinningStyle];
    [progressIndicator setDisplayedWhenStopped:NO];
    [content addSubview:progressIndicator];

    [mainWindow center];
}

- (void)createPreferencesWindow
{
    CGFloat width = kPreferencesWidth;
    CGFloat height = METRICS_CONTENT_TOP_MARGIN + kLabelHeight + METRICS_SPACE_8
                   + 2 * METRICS_RADIO_BUTTON_LINE_SPACING
                   + METRICS_CONTENT_BOTTOM_MARGIN;
    CGFloat left = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat contentWidth = width - 2 * METRICS_CONTENT_SIDE_MARGIN;

    preferencesWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
                                                    styleMask:NSTitledWindowMask | NSClosableWindowMask
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
    [preferencesWindow setTitle:NSLocalizedString(@"Screenshot Preferences", @"")];
    [preferencesWindow setReleasedWhenClosed:NO];
    [preferencesWindow setHidesOnDeactivate:NO];
    NSView *content = [preferencesWindow contentView];

    CGFloat y = height - METRICS_CONTENT_TOP_MARGIN - kLabelHeight;
    NSTextField *hint = [self labelWithString:NSLocalizedString(@"These options apply to Window screenshots.", @"")
                                        frame:NSMakeRect(left, y, contentWidth, kLabelHeight)];
    [hint setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [content addSubview:hint];

    y -= METRICS_SPACE_8 + METRICS_RADIO_BUTTON_LINE_SPACING;
    frameCheckbox = [[self checkboxWithTitle:NSLocalizedString(@"Include window title", @"")
                                      state:[ScreenshotPreferences includeWindowFrame]
                                     action:@selector(toggleIncludeFrame:)
                                      frame:NSMakeRect(left, y, contentWidth, METRICS_RADIO_BUTTON_SIZE)] retain];
    [content addSubview:frameCheckbox];

    y -= METRICS_RADIO_BUTTON_LINE_SPACING;
    shadowCheckbox = [[self checkboxWithTitle:NSLocalizedString(@"Include shadow", @"")
                                       state:[ScreenshotPreferences includeWindowShadow]
                                      action:@selector(toggleIncludeShadow:)
                                       frame:NSMakeRect(left, y, contentWidth, METRICS_RADIO_BUTTON_SIZE)] retain];
    [content addSubview:shadowCheckbox];

    [preferencesWindow center];
}

- (void)setStatus:(NSString *)status
{
    [statusLabel setStringValue:status];
}

- (void)setBusy:(BOOL)busy
{
    [windowButton setEnabled:!busy];
    [areaButton setEnabled:!busy];
    [screenButton setEnabled:!busy];
    [delayField setEnabled:!busy];
    if (busy)
        [progressIndicator startAnimation:self];
    else
        [progressIndicator stopAnimation:self];
}

- (void)runAlertWithTitle:(NSString *)title message:(NSString *)message
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:title];
    [alert setInformativeText:message];
    [alert setAlertStyle:NSWarningAlertStyle];
    [alert runModal];
    [alert release];
}

#pragma mark - Application and window delegate

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    [self createMainMenu];
    [self createMainWindow];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    [mainWindow makeKeyAndOrderFront:self];
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    if ([ocrTask isRunning])
        [ocrTask terminate];
    if (ocrInputPath)
        [[NSFileManager defaultManager] removeItemAtPath:ocrInputPath error:NULL];
    x11_cleanup();
}

- (void)windowWillClose:(NSNotification *)notification
{
    [NSApp terminate:self];
}

#pragma mark - Actions

- (IBAction)takeWindowScreenshot:(id)sender
{
    [self beginCaptureWithMode:ScreenshotModeWindow];
}

- (IBAction)takeAreaScreenshot:(id)sender
{
    [self beginCaptureWithMode:ScreenshotModeArea];
}

- (IBAction)takeScreenScreenshot:(id)sender
{
    [self beginCaptureWithMode:ScreenshotModeScreen];
}

- (IBAction)showPreferences:(id)sender
{
    if (!preferencesWindow)
        [self createPreferencesWindow];
    [preferencesWindow makeKeyAndOrderFront:self];
}

- (IBAction)toggleIncludeFrame:(id)sender
{
    [ScreenshotPreferences setIncludeWindowFrame:[sender state] == NSOnState];
}

- (IBAction)toggleIncludeShadow:(id)sender
{
    [ScreenshotPreferences setIncludeWindowShadow:[sender state] == NSOnState];
}

#pragma mark - Capture flow

- (int)delaySeconds
{
    int delay = MAX(0, MIN([delayField intValue], kMaximumDelay));
    [delayField setIntValue:delay];
    return delay;
}

- (void)beginCaptureWithMode:(ScreenshotMode)mode
{
    pendingMode = mode;
    remainingDelay = [self delaySeconds];
    [self setBusy:YES];

    if (remainingDelay == 0) {
        [self hideWindowsAndCapture];
        return;
    }

    [self showCountdown];
    countdownTimer = [[NSTimer timerWithTimeInterval:1.0
                                              target:self
                                            selector:@selector(countdownTick:)
                                            userInfo:nil
                                             repeats:YES] retain];
    // Keep counting while a menu is being tracked
    [[NSRunLoop currentRunLoop] addTimer:countdownTimer forMode:NSDefaultRunLoopMode];
    [[NSRunLoop currentRunLoop] addTimer:countdownTimer forMode:NSEventTrackingRunLoopMode];
}

- (void)showCountdown
{
    [self setStatus:[NSString stringWithFormat:
        NSLocalizedString(@"Taking screenshot in %d seconds...", @""), remainingDelay]];
}

- (void)countdownTick:(NSTimer *)timer
{
    remainingDelay--;
    if (remainingDelay > 0) {
        [self showCountdown];
        return;
    }
    [countdownTimer invalidate];
    [countdownTimer release];
    countdownTimer = nil;
    [self hideWindowsAndCapture];
}

- (void)hideWindowsAndCapture
{
    NSMutableArray *visible = [NSMutableArray array];
    if ([mainWindow isVisible])
        [visible addObject:mainWindow];
    if ([preferencesWindow isVisible])
        [visible addObject:preferencesWindow];
    [visible makeObjectsPerformSelector:@selector(orderOut:) withObject:nil];
    windowsHiddenForCapture = [visible retain];

    [self setStatus:NSLocalizedString(@"Taking screenshot...", @"")];
    [self performSelector:@selector(performCapture)
               withObject:nil
               afterDelay:kWindowHideSettleDelay];
}

- (void)restoreHiddenWindows
{
    [windowsHiddenForCapture makeObjectsPerformSelector:@selector(orderFront:) withObject:nil];
    [windowsHiddenForCapture release];
    windowsHiddenForCapture = nil;
    [NSApp activateIgnoringOtherApps:YES];
    [mainWindow makeKeyAndOrderFront:nil];
}

- (void)performCapture
{
    CaptureStatus status;
    NSBitmapImageRep *image = [ScreenshotCapture captureWithMode:pendingMode
                                                    includeFrame:[ScreenshotPreferences includeWindowFrame]
                                                   includeShadow:[ScreenshotPreferences includeWindowShadow]
                                                          status:&status];
    if (image)
        [ScreenshotCapture flashScreen];

    [self restoreHiddenWindows];
    [self setBusy:NO];

    if (status == CaptureStatusCancelled) {
        [self setStatus:NSLocalizedString(@"Screenshot cancelled", @"")];
        return;
    }
    if (!image) {
        [self setStatus:NSLocalizedString(@"Failed to capture screenshot", @"")];
        [self runAlertWithTitle:NSLocalizedString(@"Screenshot Failed", @"")
                        message:[ScreenshotCapture messageForStatus:status]];
        return;
    }

    [capturedImage release];
    capturedImage = [image retain];
    [capturedPNG release];
    capturedPNG = nil;
    [self setStatus:[NSString stringWithFormat:
        NSLocalizedString(@"Screenshot captured (%d x %d)", @""),
        (int)[image pixelsWide], (int)[image pixelsHigh]]];
    [self offerCapturedImage];
}

- (void)offerCapturedImage
{
    // Kept for reuse: releasing the panel after each modal session crashed
    // the next capture once a save panel had been shown in between
    if (!actionPanel)
        actionPanel = [[ScreenshotActionPanel alloc] init];
    switch ([actionPanel runModal]) {
    case ScreenshotActionSave:
        [self saveCapturedImage];
        break;
    case ScreenshotActionCopy:
        [self copyCapturedImage];
        break;
    case ScreenshotActionRecognizeText:
        [self recognizeTextInCapturedImage];
        break;
    case ScreenshotActionCancel:
        [self setStatus:NSLocalizedString(@"Ready to take screenshot", @"")];
        break;
    }
}

#pragma mark - Using the captured image

- (NSData *)capturedPNG
{
    if (!capturedPNG)
        capturedPNG = [[ScreenshotCapture PNGDataForImageRep:capturedImage] retain];
    return capturedPNG;
}

- (void)saveCapturedImage
{
    NSString *defaultPath = [ScreenshotCapture defaultFilePath];
    NSSavePanel *panel = [NSSavePanel savePanel];
    [panel setAllowedFileTypes:[NSArray arrayWithObject:@"png"]];
    [panel setCanCreateDirectories:YES];
    if ([panel runModalForDirectory:[defaultPath stringByDeletingLastPathComponent]
                               file:[defaultPath lastPathComponent]] != NSOKButton) {
        [self setStatus:NSLocalizedString(@"Save cancelled", @"")];
        return;
    }

    NSString *path = [panel filename];
    NSData *png = [self capturedPNG];
    NSError *error = nil;
    if (!png) {
        [self runAlertWithTitle:NSLocalizedString(@"Save Failed", @"")
                        message:NSLocalizedString(@"The screenshot could not be converted to PNG.", @"")];
        return;
    }
    if (![png writeToFile:path options:NSDataWritingAtomic error:&error]) {
        [self runAlertWithTitle:NSLocalizedString(@"Save Failed", @"")
                        message:[error localizedDescription]];
        return;
    }
    [self setStatus:[NSString stringWithFormat:NSLocalizedString(@"Saved to %@", @""),
                     [path lastPathComponent]]];
}

- (void)copyCapturedImage
{
    NSData *png = [self capturedPNG];
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard declareTypes:[NSArray arrayWithObject:NSPasteboardTypePNG] owner:nil];
    if (!png || ![pasteboard setData:png forType:NSPasteboardTypePNG]) {
        [self runAlertWithTitle:NSLocalizedString(@"Copy Failed", @"")
                        message:NSLocalizedString(@"The screenshot could not be put on the clipboard.", @"")];
        return;
    }
    [self setStatus:NSLocalizedString(@"Screenshot copied to clipboard", @"")];
}

- (NSString *)pathForTool:(NSString *)name
{
    NSString *searchPath = [[[NSProcessInfo processInfo] environment] objectForKey:@"PATH"];
    for (NSString *directory in [searchPath componentsSeparatedByString:@":"]) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:path])
            return path;
    }
    return nil;
}

- (void)recognizeTextInCapturedImage
{
    NSString *tesseract = [self pathForTool:@"tesseract"];
    if (!tesseract) {
        [self setStatus:NSLocalizedString(@"Text recognition needs tesseract", @"")];
        [self runAlertWithTitle:NSLocalizedString(@"Tesseract Not Found", @"")
                        message:NSLocalizedString(@"Install tesseract with your package manager:\n\n"
                                                  @"Debian/Ubuntu: sudo apt install tesseract-ocr\n"
                                                  @"Arch: sudo pacman -S tesseract\n"
                                                  @"FreeBSD: sudo pkg install tesseract\n"
                                                  @"OpenBSD: doas pkg_add tesseract", @"")];
        return;
    }

    NSData *png = [self capturedPNG];
    NSString *input = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Screenshot-OCR-%@.png",
         [[NSProcessInfo processInfo] globallyUniqueString]]];
    if (!png || ![png writeToFile:input atomically:YES]) {
        [self runAlertWithTitle:NSLocalizedString(@"Text Recognition Failed", @"")
                        message:NSLocalizedString(@"The screenshot could not be written to a temporary file.", @"")];
        return;
    }

    NSPipe *output = [NSPipe pipe];
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:tesseract];
    [task setArguments:[NSArray arrayWithObjects:input, @"stdout", nil]];
    [task setStandardOutput:output];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    @try {
        [task launch];
    } @catch (NSException *exception) {
        [task release];
        [[NSFileManager defaultManager] removeItemAtPath:input error:NULL];
        [self runAlertWithTitle:NSLocalizedString(@"Text Recognition Failed", @"")
                        message:[exception reason]];
        return;
    }

    ocrTask = task;
    ocrInputPath = [input retain];
    [self setBusy:YES];
    [self setStatus:NSLocalizedString(@"Recognizing text...", @"")];

    // Read in the background: a synchronous read would freeze the window
    // for as long as tesseract runs
    NSFileHandle *reader = [output fileHandleForReading];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(textRecognitionDidFinish:)
                                                 name:NSFileHandleReadToEndOfFileCompletionNotification
                                               object:reader];
    [reader readToEndOfFileInBackgroundAndNotify];
}

- (void)textRecognitionDidFinish:(NSNotification *)notification
{
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSFileHandleReadToEndOfFileCompletionNotification
                                                  object:[notification object]];
    NSData *data = [[notification userInfo] objectForKey:NSFileHandleNotificationDataItem];

    // Output reached end of file, so the process is exiting and this is brief
    [ocrTask waitUntilExit];
    int exitStatus = [ocrTask terminationStatus];
    [ocrTask release];
    ocrTask = nil;
    [[NSFileManager defaultManager] removeItemAtPath:ocrInputPath error:NULL];
    [ocrInputPath release];
    ocrInputPath = nil;
    [self setBusy:NO];

    if (exitStatus != 0) {
        [self setStatus:NSLocalizedString(@"Text recognition failed", @"")];
        [self runAlertWithTitle:NSLocalizedString(@"Text Recognition Failed", @"")
                        message:[NSString stringWithFormat:
                            NSLocalizedString(@"tesseract exited with status %d.", @""), exitStatus]];
        return;
    }

    // tesseract ends its output with a form feed besides newlines
    NSMutableCharacterSet *trim = [[[NSCharacterSet whitespaceAndNewlineCharacterSet] mutableCopy] autorelease];
    [trim addCharactersInString:@"\f"];
    NSString *text = [[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease]
                      stringByTrimmingCharactersInSet:trim];
    if ([text length] == 0) {
        [self setStatus:NSLocalizedString(@"No text found in the screenshot", @"")];
        return;
    }

    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    if (![pasteboard setString:text forType:NSStringPboardType]) {
        [self runAlertWithTitle:NSLocalizedString(@"Copy Failed", @"")
                        message:NSLocalizedString(@"The text could not be put on the clipboard.", @"")];
        return;
    }
    [self setStatus:[NSString stringWithFormat:
        NSLocalizedString(@"Recognized text copied to clipboard (%lu characters)", @""),
        (unsigned long)[text length]]];
}

@end
