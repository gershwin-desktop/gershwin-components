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
// Everything else (icon/text positions, button row) is derived from
// AppearanceMetrics so spacing stays correct if these change.
static const float kWinWidth = METRICS_WIN_MIN_WIDTH - 100.0;   // 400: a password prompt is not a full dialog
static const float kCompactHeight = 220.0;
static const float kDetailsBoxHeight = 90.0;
static const float kExpandedHeight = kCompactHeight + kDetailsBoxHeight + METRICS_SPACE_16 + METRICS_SPACE_8;
static const float kLabelWidth = 60.0;

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
    NSTextField *commandLabel;
    NSScrollView *commandScrollView;
    NSString *sudoCommand;
    NSString *requesterName;
    BOOL cancelled;
    BOOL detailsVisible;
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
    [window setLevel:NSFloatingWindowLevel]; // Keep window on top

    // Disable system beeps and alerts for this window
    [window setHidesOnDeactivate:NO];

    float contentRight = kWinWidth - METRICS_CONTENT_SIDE_MARGIN;
    NSView *contentView = [window contentView];

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
    [contentView addSubview:iconView];
    [[headlineField cell] setWraps:YES];
    [contentView addSubview:headlineField];

    // Name row: the account sudo will authenticate, read-only.
    NSRect nameLabelRect = NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, 90.0,
                                       kLabelWidth, METRICS_TEXT_INPUT_FIELD_HEIGHT);
    nameLabelField = [[NSTextField alloc] initWithFrame:nameLabelRect];
    [nameLabelField setStringValue:@"Name:"];
    [nameLabelField setAlignment:NSRightTextAlignment];
    [nameLabelField setBezeled:NO];
    [nameLabelField setDrawsBackground:NO];
    [nameLabelField setEditable:NO];
    [nameLabelField setSelectable:NO];
    [contentView addSubview:nameLabelField];

    float fieldLeft = METRICS_CONTENT_SIDE_MARGIN + kLabelWidth + METRICS_SPACE_8;
    NSRect nameValueRect = NSMakeRect(fieldLeft, 90.0,
                                       contentRight - fieldLeft, METRICS_TEXT_INPUT_FIELD_HEIGHT);
    nameValueField = [[NSTextField alloc] initWithFrame:nameValueRect];
    [nameValueField setStringValue:(NSUserName() ?: @"")];
    [nameValueField setEditable:NO];
    [nameValueField setSelectable:NO];
    [nameValueField setTextColor:[NSColor disabledControlTextColor]];
    [contentView addSubview:nameValueField];

    // Password row, directly below Name.
    NSRect passwordLabelRect = NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, 56.0,
                                           kLabelWidth, METRICS_TEXT_INPUT_FIELD_HEIGHT);
    passwordLabelField = [[NSTextField alloc] initWithFrame:passwordLabelRect];
    [passwordLabelField setStringValue:@"Password:"];
    [passwordLabelField setAlignment:NSRightTextAlignment];
    [passwordLabelField setBezeled:NO];
    [passwordLabelField setDrawsBackground:NO];
    [passwordLabelField setEditable:NO];
    [passwordLabelField setSelectable:NO];
    [contentView addSubview:passwordLabelField];

    NSRect passwordRect = NSMakeRect(fieldLeft, 56.0,
                                      contentRight - fieldLeft, METRICS_TEXT_INPUT_FIELD_HEIGHT);
    passwordField = [[NSSecureTextField alloc] initWithFrame:passwordRect];
    [passwordField setDelegate:self];  // Set delegate to monitor text changes
    [contentView addSubview:passwordField];

    // Details button (left side)
    NSRect detailsRect = NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, METRICS_CONTENT_BOTTOM_MARGIN,
                                     METRICS_BUTTON_MIN_WIDTH, METRICS_BUTTON_HEIGHT);
    detailsButton = [[NSButton alloc] initWithFrame:detailsRect];
    [detailsButton setTitle:@"Details"];
    [detailsButton setTarget:self];
    [detailsButton setAction:@selector(detailsClicked:)];
    [contentView addSubview:detailsButton];

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
    [contentView addSubview:cancelButton];

    // Details box (initially hidden): requesting app and what will run as
    // root, so the user can check before typing a password. Never shown by
    // default - the only reason to open it is curiosity, not the workflow.
    NSRect commandRect = NSMakeRect(METRICS_CONTENT_SIDE_MARGIN,
                                     METRICS_CONTENT_BOTTOM_MARGIN + METRICS_BUTTON_HEIGHT + METRICS_SPACE_16,
                                     contentRight - METRICS_CONTENT_SIDE_MARGIN, kDetailsBoxHeight);
    commandScrollView = [[NSScrollView alloc] initWithFrame:commandRect];
    [commandScrollView setHasVerticalScroller:YES];
    [commandScrollView setHasHorizontalScroller:NO];
    [commandScrollView setAutohidesScrollers:YES];
    [commandScrollView setBorderType:NSBezelBorder];
    [commandScrollView setHidden:YES];

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
    [commandLabel release];
    [commandScrollView release];
    [sudoCommand release];
    [requesterName release];
    [super dealloc];
}

- (void)detailsClicked:(id)sender
{
    @try {
        detailsVisible = !detailsVisible;

        float newHeight = detailsVisible ? kExpandedHeight : kCompactHeight;
        float fieldLeft = METRICS_CONTENT_SIDE_MARGIN + kLabelWidth + METRICS_SPACE_8;
        float contentRight = kWinWidth - METRICS_CONTENT_SIDE_MARGIN;

        // Icon and headline are anchored to the window TOP, so their
        // content-view Y (measured from the bottom) depends on the height.
        // Icon is centered on the headline's own span, not top-anchored -
        // see the -init rationale above.
        NSRect headlineRect = NSMakeRect(METRICS_TEXT_LEFT,
                                          newHeight - METRICS_CONTENT_TOP_MARGIN - 40.0,
                                          contentRight - METRICS_TEXT_LEFT, 40.0);
        [headlineField setFrame:headlineRect];
        [iconView setFrame:NSMakeRect(METRICS_ICON_LEFT,
                                       NSMidY(headlineRect) - METRICS_ICON_SIDE / 2.0,
                                       METRICS_ICON_SIDE, METRICS_ICON_SIDE)];

        if (detailsVisible) {
            // Grow the window downward (top edge stays put on screen) and
            // make room above the details box for Name/Password.
            [detailsButton setTitle:@"Hide Details"];

            float passwordY = METRICS_CONTENT_BOTTOM_MARGIN + METRICS_BUTTON_HEIGHT
                             + METRICS_SPACE_16 + kDetailsBoxHeight + METRICS_SPACE_16;
            float nameY = passwordY + METRICS_TEXT_INPUT_FIELD_HEIGHT + METRICS_SPACE_12;

            [nameLabelField setFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, nameY,
                                                 kLabelWidth, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
            [nameValueField setFrame:NSMakeRect(fieldLeft, nameY,
                                                 contentRight - fieldLeft, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
            [passwordLabelField setFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, passwordY,
                                                     kLabelWidth, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
            [passwordField setFrame:NSMakeRect(fieldLeft, passwordY,
                                                contentRight - fieldLeft, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
            [commandScrollView setHidden:NO];
        } else {
            [detailsButton setTitle:@"Details"];

            [nameLabelField setFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, 90.0,
                                                 kLabelWidth, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
            [nameValueField setFrame:NSMakeRect(fieldLeft, 90.0,
                                                 contentRight - fieldLeft, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
            [passwordLabelField setFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, 56.0,
                                                     kLabelWidth, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
            [passwordField setFrame:NSMakeRect(fieldLeft, 56.0,
                                                contentRight - fieldLeft, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
            [commandScrollView setHidden:YES];
        }

        // -setFrame: takes a FRAME rect (titlebar included), not the CONTENT
        // rect newHeight is expressed in - going through
        // -frameRectForContentRect: gets the conversion right regardless of
        // the actual titlebar height, and anchoring on the OLD frame's top
        // edge (NSMaxY) keeps it fixed on screen while the window grows
        // downward, matching -detailsClicked: in SoftwareUpdate's
        // SWProgressWindowController (the identical bug, fixed the same way).
        NSRect desiredContentRect = NSMakeRect(0, 0, kWinWidth, newHeight);
        NSRect desiredFrameRect = [window frameRectForContentRect:desiredContentRect];
        float frameHeight = NSHeight(desiredFrameRect);

        NSRect currentFrame = [window frame];
        NSRect newFrame = NSMakeRect(currentFrame.origin.x,
                                      NSMaxY(currentFrame) - frameHeight,
                                      kWinWidth, frameHeight);
        [window setFrame:newFrame display:YES animate:YES];
    }
    @catch (NSException *exception) {
        // If animation fails, just ignore it
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
