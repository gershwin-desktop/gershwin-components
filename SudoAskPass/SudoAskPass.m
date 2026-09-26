/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <security/pam_appl.h>

#import "AppearanceMetrics.h"

// Height of the collapsed panel and of the details box revealed by "Details".
// Built up the same way the layout itself is - header block (icon/headline/
// Name/Password), then the details disclosure row, then (expanded only) the
// details box, then the footer button row - so kCompactHeight/kExpandedHeight
// always match what -showPasswordDialog actually lays out, the same pattern
// SWProgressWindowController uses for its own layout constants.
static const float kWinWidth = METRICS_WIN_MIN_WIDTH - 100.0;   // 400: a password prompt is not a full dialog
static const float kHeaderHeight = METRICS_CONTENT_TOP_MARGIN + 40.0 + METRICS_SPACE_16
                                  + METRICS_TEXT_INPUT_FIELD_HEIGHT + METRICS_SPACE_12
                                  + METRICS_TEXT_INPUT_FIELD_HEIGHT;
static const float kDetailsRowHeight = METRICS_BUTTON_HEIGHT;
static const float kFooterHeight = METRICS_CONTENT_BOTTOM_MARGIN + METRICS_BUTTON_HEIGHT;
static const float kDetailsBoxHeight = 90.0;
static const float kCompactHeight = kHeaderHeight + METRICS_SPACE_16 + kDetailsRowHeight
                                   + METRICS_SPACE_16 + kFooterHeight;
static const float kExpandedHeight = kHeaderHeight + METRICS_SPACE_16 + kDetailsRowHeight
                                    + METRICS_SPACE_16 + kDetailsBoxHeight
                                    + METRICS_SPACE_16 + kFooterHeight;
static const float kLabelWidth = 60.0;
// The Eau theme draws the disclosure triangle at 40% of its button's frame
// (Eau+Button.m _eau_drawDisclosureArrow), so the stock 13x13 GNUstep
// disclosure button renders a ~5pt glyph - much smaller and fainter than the
// handoff mockup's bold, nearly edge-to-edge triangle. Sizing the button up
// is the only lever this theme call exposes for that.
static const float kDisclosureSide = 24.0;

// GNUstep's NSView -alphaValue is a documented no-op (there is no layer
// backing yet), so fading the details box in/out cannot be done by animating
// a view's own opacity. NSImage compositing DOES support a real alpha
// fraction, though (-drawInRect:fromRect:operation:fraction:), so this view
// fakes the fade by drawing a snapshot of the box's content at a controllable
// fraction instead of the box itself.
@interface GWFadeOverlayView : NSView
{
    NSImage *fadeImage;
    CGFloat fadeFraction;
}
- (void)setFadeImage:(NSImage *)image;
- (void)setFadeFraction:(CGFloat)fraction;
@end

@implementation GWFadeOverlayView
- (void)dealloc
{
    [fadeImage release];
    [super dealloc];
}
- (void)setFadeImage:(NSImage *)image
{
    [image retain];
    [fadeImage release];
    fadeImage = image;
}
- (void)setFadeFraction:(CGFloat)fraction
{
    fadeFraction = fraction;
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect
{
    if (fadeFraction <= 0.0) return;
    NSRect bounds = [self bounds];
    [fadeImage drawInRect:bounds
                  fromRect:NSMakeRect(0, 0, [fadeImage size].width, [fadeImage size].height)
                 operation:NSCompositeSourceOver
                  fraction:fadeFraction];
}
@end

// -[NSView setFrame:] does not mark the view's OLD position dirty (it just
// updates the frame and resizes subviews - see NSView.m), and the default
// content view GNUstep gives every window has no -drawRect: of its own, so
// nothing was ever repainting the area a moved subview vacated. Manually
// calling -lockFocus/-unlockFocus from the resize timer to paint over it had
// no visible effect at all (confirmed with a solid red fill), which means
// that trick does not work outside a real display cycle here. Giving the
// content view an actual -drawRect: makes the NORMAL AppKit redraw path -
// the one -display already walks every tick - responsible for erasing the
// background before subviews draw on top of it, instead of trying to
// intercept and out-run that path from the outside.
@interface GWOpaqueContentView : NSView
@end

@implementation GWOpaqueContentView
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect
{
    [[NSColor windowBackgroundColor] set];
    NSRectFill(dirtyRect);
}
@end

#define DS_SOCKET_PATH "/var/run/dshelper.sock"

/* Outcome of asking one authentication backend about a password.
 * "Unavailable" is distinct from "rejected": a backend that is not
 * installed must never be read as a wrong password, or the dialog
 * becomes impossible to satisfy. */
typedef enum {
    GWAuthAccepted,
    GWAuthRejected,
    GWAuthUnavailable
} GWAuthResult;

/* Credentials handed to the PAM conversation callback. */
struct GWAskPassCredentials {
    const char *username;
    const char *password;
};

/* PAM conversation callback: answers prompts from the stored credentials
 * rather than from a terminal, since we have no tty. */
static int gw_askpass_pam_conv(int num_msg, const struct pam_message **msg,
                               struct pam_response **resp, void *appdata_ptr)
{
    struct GWAskPassCredentials *creds =
        (struct GWAskPassCredentials *)appdata_ptr;

    if (num_msg <= 0 || !creds) {
        return PAM_CONV_ERR;
    }

    struct pam_response *replies =
        (struct pam_response *)calloc((size_t)num_msg, sizeof(struct pam_response));
    if (!replies) {
        return PAM_BUF_ERR;
    }

    for (int i = 0; i < num_msg; i++) {
        switch (msg[i]->msg_style) {
            case PAM_PROMPT_ECHO_OFF:
                replies[i].resp = strdup(creds->password ? creds->password : "");
                break;
            case PAM_PROMPT_ECHO_ON:
                replies[i].resp = strdup(creds->username ? creds->username : "");
                break;
            case PAM_ERROR_MSG:
            case PAM_TEXT_INFO:
                break;
            default:
                for (int j = 0; j < i; j++) {
                    free(replies[j].resp);
                }
                free(replies);
                return PAM_CONV_ERR;
        }
    }

    *resp = replies;
    return PAM_SUCCESS;
}

/* Saved stdout fd for password output - set in main() before GNUstep init
 * can pollute stdout with startup messages. */
static int savedStdoutFd = -1;

@interface SudoAskPassController : NSObject<NSTextFieldDelegate>
{
    NSWindow *window;
    NSImageView *iconView;
    NSTextField *headlineField;
    NSTextField *nameLabelField;
    NSTextField *nameValueField;
    NSTextField *passwordLabelField;
    NSSecureTextField *passwordField;
    NSButton *okButton;
    NSButton *cancelButton;
    NSButton *detailsButton;
    NSTextField *detailsLabel;
    NSTextField *commandLabel;
    NSScrollView *commandScrollView;
    NSString *sudoCommand;
    NSString *requesterName;
    BOOL cancelled;
    BOOL detailsVisible;
    NSTimer *detailsAnimTimer;
    GWFadeOverlayView *boxFadeOverlay;
    // -detailsClicked:'s animation state, read by -detailsAnimTick: - a
    // target/action NSTimer instead of block-based (see -detailsClicked:'s
    // comment: GNUstep's block-based NSTimer only retains, never copies,
    // the block it is handed, which crashes once a stack-allocated block
    // literal's frame is gone; target/action carries no such risk).
    NSDate *animStartDate;
    NSTimeInterval animDuration;
    float animFromFrameHeight;
    float animToFrameHeight;
    float animFixedX;
    float animFixedWidth;
    float animTopY;
    BOOL animCollapsing;
}

- (void)showPasswordDialog;
- (BOOL)validatePassword:(NSString *)password;
- (NSString *)sendDirectoryServicesRequest:(NSString *)request;
- (GWAuthResult)checkPassword:(NSString *)password
      withDirectoryServicesUser:(NSString *)username;
- (GWAuthResult)checkPassword:(NSString *)password withPAMUser:(NSString *)username;
- (const char *)pamServiceName;
- (void)shakeWindow;
- (void)updateOKButtonState;
- (void)okClicked:(id)sender;
- (void)cancelClicked:(id)sender;
- (void)detailsClicked:(id)sender;
- (void)detailsAnimTick:(NSTimer *)stepTimer;
- (void)applicationWillFinishLaunching:(NSNotification *)notification;
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (BOOL)application:(NSApplication *)app openFile:(NSString *)filename;

@end

@implementation SudoAskPassController

- (id)init
{
    self = [super init];
    if (self) {
        cancelled = NO;
        detailsVisible = NO;

        // sudo does not reliably pass the original command to askpass
        // programs, so a caller that wants to be named in the headline sets
        // this itself (e.g. ASKPASS_REQUESTER="Software Update").
        const char *requester = getenv("ASKPASS_REQUESTER");
        if (requester && strlen(requester) > 0) {
            requesterName = [[NSString stringWithUTF8String:requester] retain];
        } else {
            requesterName = [@"An application" retain];
        }
    }
    return self;
}

- (void)showPasswordDialog
{

    // Check command line arguments as fallback - extract actual command after sudo options
    NSArray *args = [[NSProcessInfo processInfo] arguments];
    if ([args count] > 1) {
        // Look for the command after sudo options (skip -A, -E, etc.)
        NSMutableArray *commandParts = [NSMutableArray array];
        BOOL foundCommand = NO;
        for (NSUInteger i = 1; i < [args count]; i++) {
            NSString *arg = [args objectAtIndex:i];
            // Skip sudo options that start with dash
            if ([arg hasPrefix:@"-"] && !foundCommand) {
                continue;
            }
            foundCommand = YES;
            [commandParts addObject:arg];
        }
        if ([commandParts count] > 0) {
            sudoCommand = [[commandParts componentsJoinedByString:@" "] retain];
        } else {
            sudoCommand = [[NSString stringWithFormat:@"Arguments: %@", [args componentsJoinedByString:@" "]] retain];
        }
    }


    // Create window with initial size (compact mode)
    NSRect windowRect = NSMakeRect(100, 100, kWinWidth, kCompactHeight);
    // Resizable is required for -setFrame: (used by -detailsClicked: to
    // reveal the details box) to actually take effect: a non-resizable
    // GNUstep window advertises fixed X11 size hints, and the window
    // manager clamps any resize request - including a programmatic one from
    // this process - back to the original size, so only the position half
    // of the request took effect and the details box was never revealed.
    window = [[NSWindow alloc] initWithContentRect:windowRect
                                         styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     | NSWindowStyleMaskResizable)
                                           backing:NSBackingStoreBuffered
                                             defer:NO];

    if (!window) {
        // If window creation fails, exit gracefully
        exit(1);
    }

    [window setTitle:@"Authenticate"];
    [window center];
    // NSFloatingWindowLevel makes gnustep-back publish _NET_WM_WINDOW_TYPE_UTILITY
    // (XGServerWindow.m), which gets this window treated as a palette/auxiliary
    // panel by the window manager - thin titlebar instead of full dialog chrome,
    // and (per that same convention) not resizable, which silently broke the
    // details-disclosure animation. NSModalPanelWindowLevel maps to
    // _NET_WM_WINDOW_TYPE_NORMAL instead, giving proper dialog decorations and
    // working resize while still keeping the window above normal app windows.
    [window setLevel:NSModalPanelWindowLevel]; // Keep window on top

    // Disable system beeps and alerts for this window
    [window setHidesOnDeactivate:NO];

    float contentRight = kWinWidth - METRICS_CONTENT_SIDE_MARGIN;
    // See GWOpaqueContentView's comment: the stock content view has no
    // -drawRect: of its own, which is what let moved subviews leave a
    // trail behind during -detailsClicked:'s animation.
    GWOpaqueContentView *opaqueContentView = [[GWOpaqueContentView alloc] initWithFrame:[[window contentView] frame]];
    [window setContentView:opaqueContentView];
    [opaqueContentView release];
    NSView *contentView = opaqueContentView;

    // Headline: bold, names the requesting app so the user knows what is
    // asking for their password (sudo does not reliably pass this on).
    NSRect headlineRect = NSMakeRect(METRICS_TEXT_LEFT,
                                      kCompactHeight - METRICS_CONTENT_TOP_MARGIN - 40.0,
                                      contentRight - METRICS_TEXT_LEFT, 40.0);
    headlineField = [[NSTextField alloc] initWithFrame:headlineRect];
    [headlineField setStringValue:[NSString stringWithFormat:
        @"%@ requires that you type your password.", requesterName]];
    [headlineField setFont:METRICS_FONT_SYSTEM_BOLD_13];
    [headlineField setBezeled:NO];
    [headlineField setDrawsBackground:NO];
    [headlineField setEditable:NO];
    [headlineField setSelectable:NO];
    // Pin to the window's top edge (fixed local y grows automatically as the
    // content view's height changes) so nothing here has to be manually
    // repositioned when -detailsClicked: grows/shrinks the window - which is
    // what a moved-by-hand -setFrame: used to do, and which turned out to
    // leave a visible ghost of the old position behind during the animation
    // (reproduces with no window manager or compositor running at all, so
    // it is a GNUstep/X11-level redraw issue with that pattern, not
    // something fixable by drawing harder from here). NSViewMinYMargin lets
    // AppKit's own, already-correct resize path do the repositioning
    // instead, the same way SWProgressWindowController's header already
    // does it safely.
    [headlineField setAutoresizingMask:NSViewMinYMargin];

    // Lock icon, top-left, same placement alerts use for their icon -
    // centered against the headline's own (up to two-line) span rather than
    // a fixed top offset, or it visibly sits below the text block's center
    // (see the identical fix in SoftwareUpdate's SWMainWindowController).
    NSRect iconRect = NSMakeRect(METRICS_ICON_LEFT,
                                  NSMidY(headlineRect) - METRICS_ICON_SIDE / 2.0,
                                  METRICS_ICON_SIDE, METRICS_ICON_SIDE);
    iconView = [[NSImageView alloc] initWithFrame:iconRect];
    [iconView setImage:[NSImage imageNamed:@"Lock"]];
    [iconView setImageFrameStyle:NSImageFrameNone];
    [iconView setAutoresizingMask:NSViewMinYMargin];
    [contentView addSubview:iconView];
    [[headlineField cell] setWraps:YES];
    [contentView addSubview:headlineField];

    // Name row: the account sudo will authenticate, read-only. Directly
    // below the headline and, like it, pinned to the top rather than
    // repositioned by hand.
    float nameY = kCompactHeight - METRICS_CONTENT_TOP_MARGIN - 40.0 - METRICS_SPACE_16
                - METRICS_TEXT_INPUT_FIELD_HEIGHT;
    NSRect nameLabelRect = NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, nameY,
                                       kLabelWidth, METRICS_TEXT_INPUT_FIELD_HEIGHT);
    nameLabelField = [[NSTextField alloc] initWithFrame:nameLabelRect];
    [nameLabelField setStringValue:@"Name:"];
    [nameLabelField setAlignment:NSRightTextAlignment];
    [nameLabelField setBezeled:NO];
    [nameLabelField setDrawsBackground:NO];
    [nameLabelField setEditable:NO];
    [nameLabelField setSelectable:NO];
    [nameLabelField setAutoresizingMask:NSViewMinYMargin];
    [contentView addSubview:nameLabelField];

    float fieldLeft = METRICS_CONTENT_SIDE_MARGIN + kLabelWidth + METRICS_SPACE_8;
    NSRect nameValueRect = NSMakeRect(fieldLeft, nameY,
                                       contentRight - fieldLeft, METRICS_TEXT_INPUT_FIELD_HEIGHT);
    nameValueField = [[NSTextField alloc] initWithFrame:nameValueRect];
    [nameValueField setStringValue:(NSUserName() ?: @"")];
    [nameValueField setEditable:NO];
    [nameValueField setSelectable:NO];
    [nameValueField setTextColor:[NSColor disabledControlTextColor]];
    [nameValueField setAutoresizingMask:NSViewMinYMargin];
    [contentView addSubview:nameValueField];

    // Password row, directly below Name - also pinned to the top.
    float passwordY = nameY - METRICS_SPACE_12 - METRICS_TEXT_INPUT_FIELD_HEIGHT;
    NSRect passwordLabelRect = NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, passwordY,
                                           kLabelWidth, METRICS_TEXT_INPUT_FIELD_HEIGHT);
    passwordLabelField = [[NSTextField alloc] initWithFrame:passwordLabelRect];
    [passwordLabelField setStringValue:@"Password:"];
    [passwordLabelField setAlignment:NSRightTextAlignment];
    [passwordLabelField setBezeled:NO];
    [passwordLabelField setDrawsBackground:NO];
    [passwordLabelField setEditable:NO];
    [passwordLabelField setSelectable:NO];
    [passwordLabelField setAutoresizingMask:NSViewMinYMargin];
    [contentView addSubview:passwordLabelField];

    NSRect passwordRect = NSMakeRect(fieldLeft, passwordY,
                                      contentRight - fieldLeft, METRICS_TEXT_INPUT_FIELD_HEIGHT);
    passwordField = [[NSSecureTextField alloc] initWithFrame:passwordRect];
    [passwordField setDelegate:self];  // Set delegate to monitor text changes
    [passwordField setAutoresizingMask:NSViewMinYMargin];
    [contentView addSubview:passwordField];

    // Details disclosure: the handoff mockup shows a plain triangle next to
    // a static "Details" label, not a bordered button whose own title swaps
    // between "Details" and "Hide Details" - GNUstep has this natively
    // (NSDisclosureBezelStyle + NSPushOnPushOffButton; the Eau theme already
    // draws the triangle open or closed from the button's own on/off state).
    // Sits directly below Password and above the (revealed/hidden) box,
    // pinned to the top the same way - not down at the bottom sharing a row
    // with Cancel/OK, which is where it used to live before the box ended
    // up appearing below this row instead of above it.
    float detailsRowY = passwordY - METRICS_SPACE_16 - kDetailsRowHeight;
    NSRect detailsRect = NSMakeRect(METRICS_CONTENT_SIDE_MARGIN,
                                     detailsRowY + (kDetailsRowHeight - kDisclosureSide) / 2.0,
                                     kDisclosureSide, kDisclosureSide);
    detailsButton = [[NSButton alloc] initWithFrame:detailsRect];
    [detailsButton setBezelStyle:NSDisclosureBezelStyle];
    [detailsButton setButtonType:NSPushOnPushOffButton];
    [detailsButton setTitle:@""];
    [detailsButton setTarget:self];
    [detailsButton setAction:@selector(detailsClicked:)];
    [detailsButton setAutoresizingMask:NSViewMinYMargin];
    [contentView addSubview:detailsButton];

    NSRect detailsLabelRect = NSMakeRect(NSMaxX(detailsRect) + METRICS_SPACE_8, detailsRowY,
                                          100.0, kDetailsRowHeight);
    detailsLabel = [[NSTextField alloc] initWithFrame:detailsLabelRect];
    [detailsLabel setStringValue:@"Details"];
    [detailsLabel setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [detailsLabel setBezeled:NO];
    [detailsLabel setDrawsBackground:NO];
    [detailsLabel setEditable:NO];
    [detailsLabel setSelectable:NO];
    [detailsLabel setAutoresizingMask:NSViewMinYMargin];
    [contentView addSubview:detailsLabel];

    // OK button (right side, default - the theme pulses whatever cell is
    // registered as the window's default button).
    NSRect okRect = NSMakeRect(contentRight - METRICS_BUTTON_MIN_WIDTH, METRICS_CONTENT_BOTTOM_MARGIN,
                                METRICS_BUTTON_MIN_WIDTH, METRICS_BUTTON_HEIGHT);
    okButton = [[NSButton alloc] initWithFrame:okRect];
    [okButton setTitle:@"OK"];
    [okButton setTarget:self];
    [okButton setAction:@selector(okClicked:)];
    [okButton setKeyEquivalent:@"\r"];
    [okButton setEnabled:NO]; // Initially disabled
    // Pinned to the bottom, correctly - see -detailsAnimTick:'s comment for
    // a known, root-caused (but unresolved from application code) redraw
    // issue this exposes during the animation.
    [okButton setAutoresizingMask:NSViewMaxYMargin];
    [contentView addSubview:okButton];
    [window setDefaultButtonCell:[okButton cell]];

    // Cancel button, to the left of OK.
    NSRect cancelRect = NSMakeRect(NSMinX(okRect) - METRICS_BUTTON_HORIZ_INTERSPACE - METRICS_BUTTON_MIN_WIDTH,
                                    METRICS_CONTENT_BOTTOM_MARGIN,
                                    METRICS_BUTTON_MIN_WIDTH, METRICS_BUTTON_HEIGHT);
    cancelButton = [[NSButton alloc] initWithFrame:cancelRect];
    [cancelButton setTitle:@"Cancel"];
    [cancelButton setTarget:self];
    [cancelButton setAction:@selector(cancelClicked:)];
    [cancelButton setKeyEquivalent:@"\033"];
    [cancelButton setAutoresizingMask:NSViewMaxYMargin]; // see okButton's comment above
    [contentView addSubview:cancelButton];

    // Details box (initially hidden): requesting app and what will run as
    // root, so the user can check before typing a password. Never shown by
    // default - the only reason to open it is curiosity, not the workflow.
    // Directly below the details row, pinned to the top the same way so its
    // distance below that row stays constant at any window height.
    NSRect commandRect = NSMakeRect(METRICS_CONTENT_SIDE_MARGIN,
                                     detailsRowY - METRICS_SPACE_16 - kDetailsBoxHeight,
                                     contentRight - METRICS_CONTENT_SIDE_MARGIN, kDetailsBoxHeight);
    commandScrollView = [[NSScrollView alloc] initWithFrame:commandRect];
    [commandScrollView setHasVerticalScroller:YES];
    [commandScrollView setHasHorizontalScroller:NO];
    [commandScrollView setAutohidesScrollers:YES];
    [commandScrollView setBorderType:NSBezelBorder];
    [commandScrollView setHidden:YES];
    [commandScrollView setAutoresizingMask:NSViewMinYMargin];

    NSSize contentSize = [commandScrollView contentSize];
    commandLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)];
    [commandLabel setStringValue:[NSString stringWithFormat:
        @"Requested by: %@\nWill run as root:\n%@", requesterName, sudoCommand ?: @""]];
    [commandLabel setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [[commandLabel cell] setWraps:YES];
    [commandLabel setBezeled:NO];
    [commandLabel setDrawsBackground:YES];
    [commandLabel setBackgroundColor:[NSColor controlBackgroundColor]];
    [commandLabel setEditable:NO];
    [commandLabel setSelectable:YES];
    [commandScrollView setDocumentView:commandLabel];

    [contentView addSubview:commandScrollView];

    // Sits exactly over the box and is only ever shown mid-fade (see
    // -detailsClicked:); hidden and empty the rest of the time.
    boxFadeOverlay = [[GWFadeOverlayView alloc] initWithFrame:commandRect];
    [boxFadeOverlay setHidden:YES];
    [boxFadeOverlay setAutoresizingMask:NSViewMinYMargin];
    [contentView addSubview:boxFadeOverlay];

    // Show window immediately and aggressively
    [window makeKeyAndOrderFront:nil];
    [window orderFrontRegardless]; // Force window to front immediately
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];

    // Set focus to password field immediately - no delay
    [window makeFirstResponder:passwordField];
}

- (void)okClicked:(id)sender
{
    NSString *password = [passwordField stringValue];

    if (password && [password length] > 0) {
        if ([self validatePassword:password]) {
            // Password is correct, write to saved stdout fd and exit.
            // We use the saved fd because GNUstep may have written
            // startup messages to stdout, corrupting the askpass protocol.
            const char *pw = [password UTF8String];
            write(savedStdoutFd, pw, strlen(pw));
            write(savedStdoutFd, "\n", 1);
            [NSApp terminate:nil];
        } else {
            // Password is wrong, shake window and clear field
            [self shakeWindow];
            [passwordField setStringValue:@""];
            [self updateOKButtonState];
            [window makeFirstResponder:passwordField];
        }
    }
}

- (void)cancelClicked:(id)sender
{
    cancelled = YES;
    [NSApp terminate:nil];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    [self showPasswordDialog];
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    // Ensure our window is on top when we become active
    if (window) {
        [window makeKeyAndOrderFront:nil];
    }
}

- (BOOL)application:(NSApplication *)app openFile:(NSString *)filename
{
    // Sudo passes a prompt string as an argument to the askpass program.
    // GNUstep interprets unknown arguments as files to open and shows an
    // alert when it can't. Return YES to silently accept and ignore them.
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    return NSTerminateNow;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return YES;
}

- (void)dealloc
{
    [detailsAnimTimer invalidate];
    [detailsAnimTimer release];
    [window release];
    [iconView release];
    [headlineField release];
    [nameLabelField release];
    [nameValueField release];
    [passwordLabelField release];
    [passwordField release];
    [okButton release];
    [cancelButton release];
    [detailsButton release];
    [detailsLabel release];
    [commandLabel release];
    [commandScrollView release];
    [boxFadeOverlay release];
    [animStartDate release];
    [sudoCommand release];
    [requesterName release];
    [super dealloc];
}

- (void)detailsClicked:(id)sender
{
    // NSPushOnPushOffButton already flipped [detailsButton state] before
    // this action fired, which is what drives the Eau theme's arrow
    // direction - so detailsVisible only needs to track it for the resize
    // math below.
    detailsVisible = !detailsVisible;

    float targetContentHeight = detailsVisible ? kExpandedHeight : kCompactHeight;

    // Everything above the box (icon, headline, Name, Password, the details
    // row itself) is pinned to the window's top edge via NSViewMinYMargin
    // (see -showPasswordDialog), so none of it needs to be touched here -
    // AppKit's own resize path repositions it correctly and safely. An
    // earlier version of this method moved those six views by hand every
    // tick, which left a visible ghost of their old positions behind during
    // the animation - reproduces even with no window manager or compositor
    // running, so it is a GNUstep/X11-level redraw issue with hand-driven
    // -setFrame: during a live resize, not something fixable by drawing
    // harder from here. Matches the pattern SWProgressWindowController
    // already uses safely for its own header.
    //
    // Real views can't fade in GNUstep (-alphaValue is a documented no-op,
    // no layer backing), so the box reveal/hide fades a captured snapshot
    // via NSImage's fraction-based compositing instead of the live view -
    // see GWFadeOverlayView.
    if (detailsVisible) {
        [commandScrollView setHidden:NO];
        NSRect boxBounds = [commandScrollView bounds];
        NSBitmapImageRep *rep = [commandScrollView bitmapImageRepForCachingDisplayInRect:boxBounds];
        [commandScrollView cacheDisplayInRect:boxBounds toBitmapImageRep:rep];
        NSImage *snapshot = [[NSImage alloc] initWithSize:[rep size]];
        [snapshot addRepresentation:rep];
        [commandScrollView setHidden:YES];
        [boxFadeOverlay setFadeImage:snapshot];
        [snapshot release];
        [boxFadeOverlay setFadeFraction:0.0];
        [boxFadeOverlay setHidden:NO];
    } else {
        NSRect boxBounds = [commandScrollView bounds];
        NSBitmapImageRep *rep = [commandScrollView bitmapImageRepForCachingDisplayInRect:boxBounds];
        [commandScrollView cacheDisplayInRect:boxBounds toBitmapImageRep:rep];
        NSImage *snapshot = [[NSImage alloc] initWithSize:[rep size]];
        [snapshot addRepresentation:rep];
        [commandScrollView setHidden:YES];
        [boxFadeOverlay setFadeImage:snapshot];
        [snapshot release];
        [boxFadeOverlay setFadeFraction:1.0];
        [boxFadeOverlay setHidden:NO];
    }

    // -setFrame: takes a FRAME rect (titlebar included), not the CONTENT
    // rect targetContentHeight is expressed in - going through
    // -frameRectForContentRect: gets the conversion right regardless of the
    // actual titlebar height. The WIDTH is taken from the window's OWN
    // current frame, never from kWinWidth directly: kWinWidth is a logical
    // point value, but -frame reports device pixels, and at any backing
    // scale factor other than 1.0 those two numbers differ. Anchoring on
    // the OLD frame's top edge (NSMaxY) keeps it fixed on screen while the
    // window grows downward.
    NSRect desiredContentRect = NSMakeRect(0, 0, kWinWidth, targetContentHeight);
    NSRect desiredFrameRect = [window frameRectForContentRect:desiredContentRect];
    float toFrameHeight = NSHeight(desiredFrameRect);

    NSRect currentFrame = [window frame];
    animFromFrameHeight = NSHeight(currentFrame);
    animToFrameHeight = toFrameHeight;
    animFixedWidth = NSWidth(currentFrame);
    animFixedX = currentFrame.origin.x;
    animTopY = NSMaxY(currentFrame);

    if (animFromFrameHeight == animToFrameHeight) return;

    // Roller-blind animation, same easing/timing as the WindowShade roll-up
    // in gershwin-windowmanager's XCBFrame -animateFrameHeightFrom:toHeight:
    // - 60fps timer, 0.22s, quadratic ease-out - so this disclosure feels
    // like the same physical motion as the window manager's own shade.
    //
    // Target/action, not block-based: GNUstep's NSTimer (NSTimer.m) stores a
    // block-based timer's action with ASSIGN(_block, (id)block) - a plain
    // -retain, never a -copy. Retaining a stack block does not move it to
    // the heap, so once this method returns and its stack frame is reused,
    // the timer fires a block pointing at overwritten stack memory - a
    // reproducible crash (confirmed with gdb - SIGSEGV inside the block,
    // dereferencing a captured pointer that had gone stale). An explicit
    // -copy on the block before handing it to the timer did not fix it
    // either, so the state this animation needs is carried in ivars
    // instead, read back by -detailsAnimTick:, which sidesteps the whole
    // block/closure question.
    if (detailsAnimTimer) {
        [detailsAnimTimer invalidate];
        [detailsAnimTimer release];
        detailsAnimTimer = nil;
    }

    [animStartDate release];
    animStartDate = [[NSDate date] retain];
    animDuration = 0.22;
    animCollapsing = !detailsVisible;

    detailsAnimTimer = [[NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                                          target:self
                                                        selector:@selector(detailsAnimTick:)
                                                        userInfo:nil
                                                         repeats:YES] retain];
}

- (void)detailsAnimTick:(NSTimer *)stepTimer
{
    NSTimeInterval elapsed = -1.0 * [animStartDate timeIntervalSinceNow];
    CGFloat progress = elapsed / animDuration;
    // A timer fires at discrete ~16ms steps, so the tick that crosses the
    // finish line almost always lands a little past it (elapsed slightly
    // exceeds duration) - clamping is what makes that last tick land
    // exactly on the target instead of overshooting past it.
    if (progress < 0.0) progress = 0.0;
    if (progress > 1.0) progress = 1.0;
    BOOL done = progress >= 1.0;
    if (!done)
        progress = 1.0 - (1.0 - progress) * (1.0 - progress);   // ease-out

    float h = animFromFrameHeight + (animToFrameHeight - animFromFrameHeight) * progress;
    NSRect stepFrame = NSMakeRect(animFixedX, animTopY - h, animFixedWidth, h);
    [boxFadeOverlay setFadeFraction:animCollapsing ? (1.0 - progress) : progress];
    [window setFrame:stepFrame display:YES animate:NO];

    // Cancel/OK are pinned to the bottom, at a fixed distance from the
    // window's own bottom edge that never needs to change - correct, since
    // they should stay glued to the bottom throughout. But their SCREEN
    // position must still shift each tick, because the window's origin
    // does. On this GNUstep version that repaint does not happen
    // correctly: confirmed NOT to be about -setFrame:'s no-op-on-equal-rect
    // short circuit (forcing a real, non-trivial value change every tick,
    // and even an unconditional -flushWindow, changed nothing), so the
    // stale pixels are coming from somewhere the application layer cannot
    // reach - most likely the X11 backend's handling of a growing window's
    // backing store. Left as a known, root-caused limitation rather than
    // a workaround that turned out not to work; see session notes for the
    // fixes that were ruled out and why.

    if (done) {
        [stepTimer invalidate];
        [detailsAnimTimer release];
        detailsAnimTimer = nil;
        NSRect finalFrame = NSMakeRect(animFixedX, animTopY - animToFrameHeight, animFixedWidth, animToFrameHeight);
        [window setFrame:finalFrame display:YES animate:NO];
        [boxFadeOverlay setHidden:YES];
        if (!animCollapsing)
            [commandScrollView setHidden:NO];
    }
}

- (BOOL)validatePassword:(NSString *)password
{
    // Pre-validate so a typo can be reported in this dialog instead of
    // being bounced back through sudo. Either backend avoids recursively
    // spawning sudo (which would re-invoke this askpass via SUDO_ASKPASS).
    //
    // Whichever backend owns the account answers for it: Directory Services
    // for DS-managed users, PAM for local OS accounts. The two coexist, so a
    // system running dshelper still authenticates its local users correctly.
    // If neither can render a verdict we accept and let sudo be the authority
    // - an absent backend must not produce a dialog no password can satisfy.

    NSString *username = NSUserName();
    if (!username || [username length] == 0) {
        return NO;
    }

    GWAuthResult ds = [self checkPassword:password
                withDirectoryServicesUser:username];
    if (ds != GWAuthUnavailable) {
        return (ds == GWAuthAccepted);
    }

    GWAuthResult pam = [self checkPassword:password withPAMUser:username];
    if (pam != GWAuthUnavailable) {
        return (pam == GWAuthAccepted);
    }

    return YES;
}

- (NSString *)sendDirectoryServicesRequest:(NSString *)request
{
    // Returns dshelper's reply, or nil if the daemon is not reachable.
    int sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock < 0) {
        return nil;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, DS_SOCKET_PATH, sizeof(addr.sun_path) - 1);

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(sock);
        return nil;
    }

    const char *requestBytes = [request UTF8String];
    size_t remaining = strlen(requestBytes);
    while (remaining > 0) {
        ssize_t written = write(sock, requestBytes, remaining);
        if (written <= 0) {
            close(sock);
            return nil;
        }
        requestBytes += written;
        remaining -= (size_t)written;
    }

    // Shutdown write side so dshelper knows the request is complete
    shutdown(sock, SHUT_WR);

    // Read the whole reply; getpwnam records are longer than an auth verdict.
    NSMutableData *reply = [NSMutableData data];
    char buf[512];
    ssize_t bytesRead;
    while ((bytesRead = read(sock, buf, sizeof(buf))) > 0) {
        [reply appendBytes:buf length:(NSUInteger)bytesRead];
    }
    close(sock);

    if (bytesRead < 0 || [reply length] == 0) {
        return nil;
    }

    NSString *response = [[[NSString alloc] initWithData:reply
                                               encoding:NSUTF8StringEncoding] autorelease];
    return [response stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (GWAuthResult)checkPassword:(NSString *)password
    withDirectoryServicesUser:(NSString *)username
{
    // Establish whether Directory Services owns this account before asking it
    // to authenticate. If it does, its verdict is final - falling back to PAM
    // for a DS-managed user would consult a stack that holds no hash for them,
    // and pam_unix's nullok accepts ANY password for an account with no shadow
    // entry. Local OS accounts are unknown to dshelper and fall through to PAM.
    NSString *record = [self sendDirectoryServicesRequest:
                            [NSString stringWithFormat:@"getpwnam:%@", username]];
    if (!record || [record length] == 0 || [record hasPrefix:@"NOTFOUND"]) {
        return GWAuthUnavailable;
    }

    NSString *verdict = [self sendDirectoryServicesRequest:
                            [NSString stringWithFormat:@"auth:%@:%@", username, password]];
    if (!verdict || [verdict length] == 0) {
        return GWAuthUnavailable;
    }

    // dshelper returns "1" for success, "0" for failure
    return ([verdict characterAtIndex:0] == '1') ? GWAuthAccepted : GWAuthRejected;
}

- (const char *)pamServiceName
{
    // Only name a service that has a policy file. An unknown service falls
    // through to the "other" policy, which denies on Linux - that would be
    // indistinguishable from a wrong password.
    static const char *candidates[] = { "sudo", "login", NULL };
    NSFileManager *fm = [NSFileManager defaultManager];

    for (int i = 0; candidates[i] != NULL; i++) {
        NSString *name = [NSString stringWithUTF8String:candidates[i]];
        NSString *etc = [@"/etc/pam.d" stringByAppendingPathComponent:name];
        NSString *localEtc = [@"/usr/local/etc/pam.d" stringByAppendingPathComponent:name];

        if ([fm fileExistsAtPath:etc] || [fm fileExistsAtPath:localEtc]) {
            return candidates[i];
        }
    }

    return NULL;
}

- (GWAuthResult)checkPassword:(NSString *)password withPAMUser:(NSString *)username
{
    const char *service = [self pamServiceName];
    if (!service) {
        return GWAuthUnavailable;
    }

    struct GWAskPassCredentials creds;
    creds.username = [username UTF8String];
    creds.password = [password UTF8String];

    struct pam_conv conversation;
    conversation.conv = gw_askpass_pam_conv;
    conversation.appdata_ptr = &creds;

    pam_handle_t *handle = NULL;
    int result = pam_start(service, [username UTF8String], &conversation, &handle);
    if (result != PAM_SUCCESS || handle == NULL) {
        if (handle) {
            pam_end(handle, result);
        }
        return GWAuthUnavailable;
    }

    // Some modules expect a tty; we are launched from the GUI and may not
    // have one, so fall back to the display.
    const char *tty = ttyname(STDIN_FILENO);
    if (!tty) {
        tty = getenv("DISPLAY");
    }
    if (tty) {
        pam_set_item(handle, PAM_TTY, tty);
    }

    // Authentication only. Account and session management are left to sudo:
    // a pre-check that is stricter than sudo would reject passwords sudo
    // would have accepted.
    result = pam_authenticate(handle, 0);
    pam_end(handle, result);

    if (result == PAM_SUCCESS) {
        return GWAuthAccepted;
    }

    // Distinguish "wrong password" from a stack that cannot answer at all.
    if (result == PAM_AUTH_ERR || result == PAM_USER_UNKNOWN ||
        result == PAM_MAXTRIES || result == PAM_CRED_INSUFFICIENT ||
        result == PAM_PERM_DENIED) {
        return GWAuthRejected;
    }

    return GWAuthUnavailable;
}

- (void)shakeWindow
{
    NSRect originalFrame = [window frame];
    NSRect shakeFrame = originalFrame;

    // Create a shake animation by moving the window left and right
    for (int i = 0; i < 6; i++) {
        // Move window 10 pixels to the right, then left
        shakeFrame.origin.x = originalFrame.origin.x + ((i % 2 == 0) ? 10 : -10);
        [window setFrame:shakeFrame display:YES];

        // Small delay between shake movements
        usleep(50000); // 50ms delay

        // Process events to ensure smooth animation
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    }

    // Return to original position
    [window setFrame:originalFrame display:YES];
}

- (void)updateOKButtonState
{
    NSString *password = [passwordField stringValue];
    BOOL hasPassword = (password && [password length] > 0);
    [okButton setEnabled:hasPassword];
}

// NSTextField delegate method to monitor text changes
- (void)controlTextDidChange:(NSNotification *)notification
{
    if ([notification object] == passwordField) {
        [self updateOKButtonState];
    }
}

@end

int main(int argc, const char * argv[])
{
    // Save stdout fd BEFORE GNUstep can write startup messages to it.
    // sudo reads the password from our stdout, so it must be clean.
    savedStdoutFd = dup(STDOUT_FILENO);

    // Redirect stdout to /dev/null so GNUstep initialization noise
    // doesn't reach sudo. Keep stderr open for debugging.
    int devnull = open("/dev/null", O_WRONLY);
    if (devnull != -1) {
        dup2(devnull, STDOUT_FILENO);
        close(devnull);
    }

    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    // Get the shared application instance and cast it
    NSApplication *app = [NSApplication sharedApplication];

    // Create controller immediately
    SudoAskPassController *controller = [[SudoAskPassController alloc] init];

    // Set delegate
    [app setDelegate:controller];

    // Force activation and run
    [app activateIgnoringOtherApps:YES];
    [app run];

    [controller release];
    [pool drain];

    return 0;
}
