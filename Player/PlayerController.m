/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PlayerController.h"
#import "PlayerController+Private.h"
#import "PlayerMenu.h"
#import "AppearanceMetrics.h"
#import <AVFoundation/AVFoundation.h>

NSString *const PlayerDefaultsVolume = @"PlayerVolume";
NSString *const PlayerDefaultsMuted = @"PlayerMuted";
NSString *const PlayerDefaultsRepeat = @"PlayerRepeatEnabled";
NSString *const PlayerDefaultsShuffle = @"PlayerShuffleEnabled";
NSString *const PlayerDefaultsMode = @"PlayerMode";

// Content size the window opens with
static const CGFloat kDefaultWidth = 520.0;
static const CGFloat kDefaultHeight = 560.0;
static const CGFloat kMinHeight = 400.0;

// Rows below the cover art, top to bottom
static const CGFloat kTitleHeight = 17.0;
static const CGFloat kInfoLineHeight = 14.0;
static const CGFloat kTimeRowHeight = 16.0;
static const CGFloat kTimeLabelWidth = 48.0;
static const CGFloat kTransportButtonWidth = 40.0;
static const CGFloat kTransportButtonHeight = 24.0;
static const CGFloat kTransportButtonGap = 8.0;
static const CGFloat kOpenButtonWidth = 100.0;
static const CGFloat kVolumeSliderWidth = 120.0;
static const CGFloat kMuteWidth = 56.0;
static const CGFloat kIconButtonWidth = 32.0;
static const CGFloat kOverlayHeight = 64.0;

// Arrow keys move this far through a track
static const NSTimeInterval kSkipSeconds = 5.0;
static const float kVolumeStep = 0.05f;
// How long browsing the covers must rest before the track under the
// cursor plays, so flicking through them does not start every track
static const NSTimeInterval kBrowseDelay = 0.5;
static const NSTimeInterval kOverlayHideDelay = 3.0;

@implementation PlayerController

@synthesize mainWindow;

#pragma mark - Init

- (instancetype)init
{
    self = [super init];
    if (self) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        // Earlier versions kept one volume per mode; the local one wins
        [defaults registerDefaults:@{PlayerDefaultsVolume:
            [defaults objectForKey:@"PlayerLocalVolume"] ?: @0.8f}];

        StreamPlayer *media = [[[StreamPlayer alloc] init] autorelease];
        session = [[PlayerSession alloc] initWithMedia:media];
        [session setDelegate:self];
        [session setVolume:[defaults floatForKey:PlayerDefaultsVolume]];
        [session setMuted:[defaults boolForKey:PlayerDefaultsMuted]];
        [[session playlist] setRepeat:[defaults boolForKey:PlayerDefaultsRepeat]];
        [[session playlist] setShuffle:[defaults boolForKey:PlayerDefaultsShuffle]];

        coverImages = [[NSMutableDictionary alloc] init];
        streamTitles = [[NSMutableDictionary alloc] init];
        pendingFlowIndex = NSNotFound;
        playerMode = PlayerModeLocal;

        ytdlpBackend = [[YTDLPBackend alloc] init];
        [ytdlpBackend setDelegate:self];
    }
    return self;
}

- (void)dealloc
{
    [positionTimer invalidate];
    [overlayHideTimer invalidate];
    [fadeTimer invalidate];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [session setDelegate:nil];
    [session release];
    [coverImages release];
    [streamTitles release];
    [playImage release];
    [pauseImage release];
    [pendingRadioStation release];
    [ytdlpBackend setDelegate:nil];
    [ytdlpBackend release];
    [preferencesController release];
    [fadeStartDate release];
    [mainWindow release];
    [super dealloc];
}

#pragma mark - Application delegate

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    NSArray *args = [[NSProcessInfo processInfo] arguments];
    if ([args containsObject:@"-h"] || [args containsObject:@"--help"]) {
        printf("Usage: Player [file-or-folder ...]\n\n"
               "Plays the given media files, or all media files in the given\n"
               "folders, one after the other.\n");
        exit(0);
    }

    [NSApp setMainMenu:[PlayerMenu mainMenuWithTarget:self]];
    [self createWindow];
    [self updateControls];
    [self updateTrackInfo];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    // Files given at launch were opened already and take precedence over
    // the radio mode of the last run.
    if ([[session playlist] count] == 0
        && [[NSUserDefaults standardUserDefaults] integerForKey:PlayerDefaultsMode] == PlayerModeRadio) {
        [self enterRadioMode];
    }
    [mainWindow makeKeyAndOrderFront:self];
    [mainWindow makeFirstResponder:contentView];
}

- (void)application:(NSApplication *)application openFiles:(NSArray *)filenames
{
    [self openPaths:filenames];
    [application replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

- (BOOL)application:(NSApplication *)application openFile:(NSString *)filename
{
    return [self openPaths:@[filename]];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    if (quittingAfterFade) {
        return NSTerminateNow;
    }
    BOOL radioPlaying = [[RadioManager sharedManager] isPlaying];
    if ([session state] != PlayerSessionPlaying && !radioPlaying) {
        return NSTerminateNow;
    }

    // Fade the sound out behind the scenes instead of cutting it off
    [[NSApp windows] makeObjectsPerformSelector:@selector(orderOut:) withObject:nil];
    fadeStartVolume = [self volume];
    [fadeStartDate release];
    fadeStartDate = [[NSDate alloc] init];
    fadeTimer = [NSTimer scheduledTimerWithTimeInterval:0.02
                                                 target:self
                                               selector:@selector(fadeOutTick:)
                                               userInfo:nil
                                                repeats:YES];
    return NSTerminateLater;
}

- (void)fadeOutTick:(NSTimer *)timer
{
    CGFloat t = MIN(1.0, -[fadeStartDate timeIntervalSinceNow] / 1.0);
    // Smoothstep, so the fade starts and ends gently
    CGFloat remaining = 1.0 - t * t * (3.0 - 2.0 * t);
    [self applyVolume:fadeStartVolume * remaining];

    if (t >= 1.0) {
        [fadeTimer invalidate];
        fadeTimer = nil;
        [session stop];
        [[RadioManager sharedManager] stop];
        quittingAfterFade = YES;
        [NSApp replyToApplicationShouldTerminate:YES];
    }
}

#pragma mark - Window

- (NSTextField *)labelWithFont:(NSFont *)font
{
    NSTextField *label = PlayerMakeLabel(font);
    [contentView addSubview:label];
    return label;
}

// Buttons do not take the keyboard focus, so Space always plays and
// pauses instead of pressing the button clicked last.
- (NSButton *)iconButtonWithImage:(NSImage *)image title:(NSString *)title
                           action:(SEL)action
{
    NSButton *button = [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease];
    [button setImage:image];
    // The title is not drawn; it names the button for tooltips and tools
    [button setTitle:title];
    [button setToolTip:title];
    [button setImagePosition:NSImageOnly];
    [button setBezelStyle:NSRoundedBezelStyle];
    [button setRefusesFirstResponder:YES];
    [button setTarget:self];
    [button setAction:action];
    [contentView addSubview:button];
    return button;
}

- (void)createWindow
{
    NSRect frame = NSMakeRect(0, 0, kDefaultWidth, kDefaultHeight);
    mainWindow = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:NSTitledWindowMask
                                                     | NSClosableWindowMask
                                                     | NSMiniaturizableWindowMask
                                                     | NSResizableWindowMask
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    [mainWindow setTitle:@"Player"];
    [mainWindow setDelegate:self];
    [mainWindow setContentMinSize:NSMakeSize(METRICS_WIN_MIN_WIDTH, kMinHeight)];
    [mainWindow setAcceptsMouseMovedEvents:YES];

    contentView = [[[PlayerContentView alloc] initWithFrame:frame controller:self] autorelease];
    [mainWindow setContentView:contentView];
    [mainWindow setInitialFirstResponder:contentView];

    flowView = [[[ItemFlowView alloc] initWithFrame:NSZeroRect] autorelease];
    [flowView setDataSource:self];
    [flowView setDelegate:self];
    [contentView addSubview:flowView];

    videoView = [[[NSView alloc] initWithFrame:NSZeroRect] autorelease];
    [videoView setHidden:YES];
    [contentView addSubview:videoView];
    videoRenderView = [[[VideoRenderView alloc] initWithFrame:NSZeroRect] autorelease];
    [videoRenderView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [videoView addSubview:videoRenderView];

    overlayBar = [[[OverlayBarView alloc] initWithFrame:NSZeroRect] autorelease];
    [overlayBar setHidden:YES];
    [contentView addSubview:overlayBar];

    // Small, beside text: over the covers the carousel's GL subwindow would
    // hide it
    progressIndicator = [[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, 16, 16)] autorelease];
    [progressIndicator setControlSize:NSSmallControlSize];
    [progressIndicator setStyle:NSProgressIndicatorSpinningStyle];
    [progressIndicator setDisplayedWhenStopped:NO];
    [contentView addSubview:progressIndicator];

    titleLabel = [self labelWithFont:METRICS_FONT_SYSTEM_BOLD_13];
    artistLabel = [self labelWithFont:METRICS_FONT_SYSTEM_REGULAR_11];
    albumLabel = [self labelWithFont:METRICS_FONT_SYSTEM_REGULAR_11];
    detailsLabel = [self labelWithFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [detailsLabel setTextColor:[NSColor disabledControlTextColor]];

    currentTimeLabel = [self labelWithFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [currentTimeLabel setAlignment:NSRightTextAlignment];
    timeSlider = [[[NSSlider alloc] initWithFrame:NSZeroRect] autorelease];
    [timeSlider setMinValue:0.0];
    [timeSlider setMaxValue:1.0];
    // Seek once, when the knob is let go; decoding restarts at every seek
    [timeSlider setContinuous:NO];
    [timeSlider setTarget:self];
    [timeSlider setAction:@selector(seekToTime:)];
    [timeSlider setRefusesFirstResponder:YES];
    [contentView addSubview:timeSlider];
    totalTimeLabel = [self labelWithFont:METRICS_FONT_SYSTEM_REGULAR_11];

    playImage = [[self iconPlay] retain];
    pauseImage = [[self iconPause] retain];
    previousButton = [self iconButtonWithImage:[self iconPrevious] title:@"Previous"
                                        action:@selector(previousTrack:)];
    playButton = [self iconButtonWithImage:playImage title:@"Play"
                                    action:@selector(playPause:)];
    stopButton = [self iconButtonWithImage:[self iconStop] title:@"Stop"
                                    action:@selector(stop:)];
    nextButton = [self iconButtonWithImage:[self iconNext] title:@"Next"
                                    action:@selector(nextTrack:)];

    openButton = [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease];
    [openButton setTitle:@"Open..."];
    [openButton setBezelStyle:NSRoundedBezelStyle];
    [openButton setRefusesFirstResponder:YES];
    [openButton setTarget:self];
    [openButton setAction:@selector(openFile:)];
    [contentView addSubview:openButton];

    volumeLabel = [self labelWithFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [volumeLabel setStringValue:@"Volume:"];
    [volumeLabel setAlignment:NSRightTextAlignment];
    volumeSlider = [[[NSSlider alloc] initWithFrame:NSZeroRect] autorelease];
    [volumeSlider setMinValue:0.0];
    [volumeSlider setMaxValue:1.0];
    [volumeSlider setFloatValue:[self volume]];
    [volumeSlider setContinuous:YES];
    [volumeSlider setTarget:self];
    [volumeSlider setAction:@selector(volumeChanged:)];
    [volumeSlider setRefusesFirstResponder:YES];
    [contentView addSubview:volumeSlider];

    muteCheckbox = [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease];
    [muteCheckbox setButtonType:NSSwitchButton];
    [muteCheckbox setTitle:@"Mute"];
    [muteCheckbox setState:[session muted] ? NSOnState : NSOffState];
    [muteCheckbox setRefusesFirstResponder:YES];
    [muteCheckbox setTarget:self];
    [muteCheckbox setAction:@selector(toggleMute:)];
    [contentView addSubview:muteCheckbox];

    fullscreenButton = [self iconButtonWithImage:[self iconFullscreen] title:@"Full Screen"
                                          action:@selector(toggleFullscreen:)];

    [self createRadioViews];

    // Restoring the frame resizes the window, which lays out all views, so
    // they must all exist by now
    if (![mainWindow setFrameUsingName:@"PlayerWindow"]) {
        [mainWindow center];
    }
    [mainWindow setFrameAutosaveName:@"PlayerWindow"];
    [self layoutSubviews];
}

#pragma mark - Icons

- (NSImage *)iconOfSize:(NSSize)size drawing:(void (^)(void))drawBlock
{
    NSImage *image = [[NSImage alloc] initWithSize:size];
    [image lockFocus];
    [[NSColor controlTextColor] set];
    drawBlock();
    [image unlockFocus];
    return [image autorelease];
}

- (NSImage *)iconPrevious
{
    return [self iconOfSize:NSMakeSize(12, 10) drawing:^{
        NSBezierPath *p = [NSBezierPath bezierPathWithRect:NSMakeRect(0, 0, 2, 10)];
        [p moveToPoint:NSMakePoint(12, 0)];
        [p lineToPoint:NSMakePoint(3, 5)];
        [p lineToPoint:NSMakePoint(12, 10)];
        [p closePath];
        [p fill];
    }];
}

- (NSImage *)iconPlay
{
    return [self iconOfSize:NSMakeSize(10, 10) drawing:^{
        NSBezierPath *p = [NSBezierPath bezierPath];
        [p moveToPoint:NSMakePoint(1, 0)];
        [p lineToPoint:NSMakePoint(10, 5)];
        [p lineToPoint:NSMakePoint(1, 10)];
        [p closePath];
        [p fill];
    }];
}

- (NSImage *)iconPause
{
    return [self iconOfSize:NSMakeSize(10, 10) drawing:^{
        NSRectFill(NSMakeRect(1, 0, 3, 10));
        NSRectFill(NSMakeRect(6, 0, 3, 10));
    }];
}

- (NSImage *)iconStop
{
    return [self iconOfSize:NSMakeSize(10, 10) drawing:^{
        NSRectFill(NSMakeRect(1, 1, 8, 8));
    }];
}

- (NSImage *)iconNext
{
    return [self iconOfSize:NSMakeSize(12, 10) drawing:^{
        NSBezierPath *p = [NSBezierPath bezierPathWithRect:NSMakeRect(10, 0, 2, 10)];
        [p moveToPoint:NSMakePoint(0, 0)];
        [p lineToPoint:NSMakePoint(9, 5)];
        [p lineToPoint:NSMakePoint(0, 10)];
        [p closePath];
        [p fill];
    }];
}

- (NSImage *)iconFullscreen
{
    return [self iconOfSize:NSMakeSize(10, 10) drawing:^{
        NSBezierPath *p = [NSBezierPath bezierPath];
        [p setLineWidth:1.5];
        [p moveToPoint:NSMakePoint(0.75, 4)];
        [p lineToPoint:NSMakePoint(0.75, 0.75)];
        [p lineToPoint:NSMakePoint(4, 0.75)];
        [p moveToPoint:NSMakePoint(0.75, 0.75)];
        [p lineToPoint:NSMakePoint(4, 4)];
        [p moveToPoint:NSMakePoint(6, 9.25)];
        [p lineToPoint:NSMakePoint(9.25, 9.25)];
        [p lineToPoint:NSMakePoint(9.25, 6)];
        [p moveToPoint:NSMakePoint(9.25, 9.25)];
        [p lineToPoint:NSMakePoint(6, 6)];
        [p stroke];
    }];
}

#pragma mark - Layout

- (void)windowDidResize:(NSNotification *)notification
{
    [self layoutSubviews];
}

- (void)layoutSubviews
{
    if (isFullscreen) {
        [self layoutFullscreen];
    } else if (playerMode == PlayerModeRadio) {
        [self layoutRadioMode];
    } else {
        [self layoutLocalMode];
    }
    [contentView setNeedsDisplay:YES];
}

- (void)setViews:(NSArray *)views hidden:(BOOL)hidden
{
    for (NSView *view in views) {
        [view setHidden:hidden];
    }
}

- (NSArray *)trackInfoViews
{
    return @[titleLabel, artistLabel, albumLabel, detailsLabel];
}

- (NSArray *)positionViews
{
    return @[currentTimeLabel, timeSlider, totalTimeLabel];
}

- (NSArray *)transportViews
{
    return @[previousButton, playButton, stopButton, nextButton];
}

- (NSArray *)bottomRowViews
{
    return @[openButton, volumeLabel, volumeSlider, muteCheckbox, fullscreenButton];
}

- (void)layoutTransportCenteredAt:(CGFloat)midX y:(CGFloat)y
{
    NSArray *buttons = [self transportViews];
    CGFloat rowWidth = [buttons count] * kTransportButtonWidth
        + ([buttons count] - 1) * kTransportButtonGap;
    CGFloat x = floor(midX - rowWidth / 2.0);
    for (NSButton *button in buttons) {
        [button setFrame:NSMakeRect(x, y, kTransportButtonWidth, kTransportButtonHeight)];
        x += kTransportButtonWidth + kTransportButtonGap;
    }
}

- (void)layoutPositionRowFrom:(CGFloat)left to:(CGFloat)right y:(CGFloat)y
{
    [currentTimeLabel setFrame:NSMakeRect(left, y, kTimeLabelWidth, kTimeRowHeight)];
    CGFloat sliderX = left + kTimeLabelWidth + METRICS_SPACE_8;
    CGFloat sliderRight = right - kTimeLabelWidth - METRICS_SPACE_8;
    [timeSlider setFrame:NSMakeRect(sliderX, y, sliderRight - sliderX, kTimeRowHeight)];
    [totalTimeLabel setFrame:NSMakeRect(sliderRight + METRICS_SPACE_8, y,
                                        kTimeLabelWidth, kTimeRowHeight)];
}

// Laid out from the bottom up: bottom row, transport, position, track
// info; the cover art takes whatever height is left at the top.
- (void)layoutLocalMode
{
    NSRect bounds = [contentView bounds];
    CGFloat W = NSWidth(bounds);
    CGFloat left = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat right = W - METRICS_CONTENT_SIDE_MARGIN;

    [self setViews:@[searchField, statusLabel, radioTextLabel, overlayBar] hidden:YES];
    [self setViews:[self trackInfoViews] hidden:NO];
    [self setViews:[self positionViews] hidden:NO];
    [self setViews:[self transportViews] hidden:NO];
    [self setViews:[self bottomRowViews] hidden:NO];

    CGFloat y = METRICS_CONTENT_BOTTOM_MARGIN;
    [openButton setFrame:NSMakeRect(left, y, kOpenButtonWidth, METRICS_BUTTON_HEIGHT)];
    [fullscreenButton setFrame:NSMakeRect(right - kIconButtonWidth, y,
                                          kIconButtonWidth, METRICS_BUTTON_HEIGHT)];
    CGFloat muteX = NSMinX([fullscreenButton frame]) - METRICS_SPACE_12 - kMuteWidth;
    [muteCheckbox setFrame:NSMakeRect(muteX, y + 1, kMuteWidth, 18)];
    CGFloat sliderX = muteX - METRICS_SPACE_8 - kVolumeSliderWidth;
    [volumeSlider setFrame:NSMakeRect(sliderX, y, kVolumeSliderWidth, METRICS_BUTTON_HEIGHT)];
    CGFloat labelLeft = NSMaxX([openButton frame]) + METRICS_SPACE_12;
    [volumeLabel setFrame:NSMakeRect(labelLeft, y + 3,
                                     sliderX - METRICS_SPACE_8 - labelLeft, 14)];
    y += METRICS_BUTTON_HEIGHT + METRICS_SPACE_16;

    [self layoutTransportCenteredAt:NSMidX(bounds) y:y];
    y += kTransportButtonHeight + METRICS_SPACE_12;

    [self layoutPositionRowFrom:left to:right y:y];
    y += kTimeRowHeight + METRICS_SPACE_12;

    // Title on top, then artist, album and the details line
    CGFloat infoWidth = right - left;
    [detailsLabel setFrame:NSMakeRect(left, y, infoWidth, kInfoLineHeight)];
    y += kInfoLineHeight + 2;
    [albumLabel setFrame:NSMakeRect(left, y, infoWidth, kInfoLineHeight)];
    y += kInfoLineHeight + 2;
    [artistLabel setFrame:NSMakeRect(left, y, infoWidth, kInfoLineHeight)];
    y += kInfoLineHeight + 2;
    [titleLabel setFrame:NSMakeRect(left, y, infoWidth - 16 - METRICS_SPACE_8, kTitleHeight)];
    [progressIndicator setFrameOrigin:NSMakePoint(right - 16, y)];
    y += kTitleHeight + METRICS_SPACE_12;

    NSRect cover = NSMakeRect(0, y, W, NSHeight(bounds) - y);
    [self setPictureFrame:cover];
}

// The carousel draws in an X subwindow of its own (OpenGL) that stays on
// screen when the view is hidden; while video plays it is parked outside
// the window instead, or it would cover the picture.
- (void)setPictureFrame:(NSRect)frame
{
    BOOL showsVideo = ![videoView isHidden];
    [flowView setFrame:showsVideo ? NSMakeRect(-2, -2, 1, 1) : frame];
    // NSOpenGLView does not always follow its frame: not before it has
    // drawn, and not when only the window around it changed size.  Until
    // the context is attached (it never is at a scale factor other than
    // 1) there is no subwindow to move, and making it current would raise.
    NSOpenGLContext *gl = [flowView openGLContext];
    if ([gl view] == flowView) {
        [gl makeCurrentContext];
        [flowView update];
        [flowView reshape];
    }
    [flowView setNeedsDisplay:YES];
    [videoView setFrame:frame];
    [videoRenderView setFrame:[videoView bounds]];
}

- (void)layoutFullscreen
{
    NSRect bounds = [contentView bounds];
    BOOL controlsShown = ![overlayBar isHidden];

    [self setViews:@[searchField, statusLabel, radioTextLabel] hidden:YES];
    [self setViews:[self trackInfoViews] hidden:YES];
    [self setViews:@[openButton, volumeLabel, volumeSlider, muteCheckbox] hidden:YES];
    [self setViews:[self positionViews] hidden:!controlsShown];
    [self setViews:[self transportViews] hidden:!controlsShown];
    [fullscreenButton setHidden:!controlsShown];

    // The picture ends above the bar, so frames never paint over controls
    CGFloat barHeight = controlsShown ? kOverlayHeight : 0.0;
    [self setPictureFrame:NSMakeRect(0, barHeight, NSWidth(bounds), NSHeight(bounds) - barHeight)];

    [overlayBar setFrame:NSMakeRect(0, 0, NSWidth(bounds), kOverlayHeight)];
    CGFloat left = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat right = NSWidth(bounds) - METRICS_CONTENT_SIDE_MARGIN;
    [self layoutTransportCenteredAt:NSMidX(bounds) y:8];
    [fullscreenButton setFrame:NSMakeRect(right - kIconButtonWidth, 10,
                                          kIconButtonWidth, METRICS_BUTTON_HEIGHT)];
    [self layoutPositionRowFrom:left to:right y:kOverlayHeight - kTimeRowHeight - 8];
}

#pragma mark - Full screen

- (IBAction)toggleFullscreen:(id)sender
{
    if (isFullscreen) {
        [self exitFullscreen];
    } else {
        [self enterFullscreen];
    }
}

- (void)setOverlayTextColor:(NSColor *)color
{
    [currentTimeLabel setTextColor:color];
    [totalTimeLabel setTextColor:color];
}

- (void)enterFullscreen
{
    if (isFullscreen || ![self showsVideo]) {
        return;
    }
    isFullscreen = YES;
    PlayerSetWindowFullScreen(mainWindow, YES);
    [self setOverlayTextColor:[NSColor whiteColor]];
    [self showOverlay];
    [self layoutSubviews];
    [self revalidateMenu];
}

- (void)exitFullscreen
{
    if (!isFullscreen) {
        return;
    }
    isFullscreen = NO;
    [overlayHideTimer invalidate];
    overlayHideTimer = nil;
    [overlayBar setHidden:YES];
    [self setOverlayTextColor:[NSColor controlTextColor]];
    PlayerSetWindowFullScreen(mainWindow, NO);
    [self layoutSubviews];
    [self revalidateMenu];
}

- (void)showOverlay
{
    if (!isFullscreen) {
        return;
    }
    [overlayHideTimer invalidate];
    overlayHideTimer = [NSTimer scheduledTimerWithTimeInterval:kOverlayHideDelay
                                                        target:self
                                                      selector:@selector(hideOverlay:)
                                                      userInfo:nil
                                                       repeats:NO];
    if ([overlayBar isHidden]) {
        [overlayBar setHidden:NO];
        [self layoutSubviews];
    }
}

- (void)hideOverlay:(NSTimer *)timer
{
    overlayHideTimer = nil;
    // Keep the controls while there is nothing playing to look at
    if (!isFullscreen || [session state] != PlayerSessionPlaying) {
        return;
    }
    [overlayBar setHidden:YES];
    [self layoutSubviews];
}

- (void)contentViewMouseMoved:(NSEvent *)event
{
    [self showOverlay];
}

#pragma mark - Keyboard and drops

- (BOOL)handleKeyDown:(NSEvent *)event
{
    NSString *chars = [event charactersIgnoringModifiers];
    if ([chars length] == 0) {
        return NO;
    }
    if ([event modifierFlags] & (NSCommandKeyMask | NSControlKeyMask | NSAlternateKeyMask)) {
        return NO;
    }
    [self showOverlay];

    switch ([chars characterAtIndex:0]) {
    case ' ':
        [self playPause:nil];
        return YES;
    case 0x1b:  // Escape
        if (isFullscreen) {
            [self exitFullscreen];
            return YES;
        }
        return NO;
    case NSLeftArrowFunctionKey:
        [session skipBy:-kSkipSeconds];
        [self updatePosition];
        return YES;
    case NSRightArrowFunctionKey:
        [session skipBy:kSkipSeconds];
        [self updatePosition];
        return YES;
    case NSUpArrowFunctionKey:
        [self increaseVolume:nil];
        return YES;
    case NSDownArrowFunctionKey:
        [self decreaseVolume:nil];
        return YES;
    default:
        return NO;
    }
}

- (void)contentViewDragEntered:(BOOL)entered
{
    if (entered) {
        [mainWindow setTitle:@"Player - Add to Playlist"];
    } else {
        [self updateWindowTitle];
    }
}

- (void)handleDroppedFiles:(NSArray *)paths
{
    NSArray *files = [self mediaFilesInPaths:paths];
    if ([files count] == 0) {
        [self showNoMediaAlert];
        return;
    }
    if (playerMode == PlayerModeRadio) {
        [self exitRadioMode];
    }
    errorAlertShown = NO;
    [session addItems:files];
    [self playlistDidChange];
}

#pragma mark - Opening

- (NSArray *)mediaExtensions
{
    return @[@"mp3", @"wav", @"aiff", @"aif", @"m4a", @"aac", @"flac", @"ogg", @"oga",
             @"opus", @"wma", @"mp4", @"m4v", @"mov", @"avi", @"mkv", @"webm", @"flv",
             @"wmv", @"mpg", @"mpeg"];
}

- (BOOL)isMediaFile:(NSString *)path
{
    return [[self mediaExtensions] containsObject:[[path pathExtension] lowercaseString]];
}

// Files in the order given; folders are searched and contribute their
// media files sorted by path, so albums play in track order.
- (NSArray *)mediaFilesInPaths:(NSArray *)paths
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *path in paths) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
            continue;
        }
        if (!isDir) {
            if ([self isMediaFile:path]) {
                [result addObject:path];
            }
            continue;
        }
        NSMutableArray *found = [NSMutableArray array];
        for (NSString *sub in [fm enumeratorAtPath:path]) {
            NSString *full = [path stringByAppendingPathComponent:sub];
            if ([self isMediaFile:full]
                && [fm fileExistsAtPath:full isDirectory:&isDir] && !isDir) {
                [found addObject:full];
            }
        }
        [found sortUsingSelector:@selector(localizedStandardCompare:)];
        [result addObjectsFromArray:found];
    }
    return result;
}

- (void)showNoMediaAlert
{
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:@"No Playable Files"];
    [alert setInformativeText:@"Player plays audio and video files. None were found in what was given."];
    [alert runModal];
}

- (BOOL)openPaths:(NSArray *)paths
{
    NSArray *files = [self mediaFilesInPaths:paths];
    if ([files count] == 0) {
        [self showNoMediaAlert];
        return NO;
    }
    if (playerMode == PlayerModeRadio) {
        [self exitRadioMode];
    }
    errorAlertShown = NO;
    [session openItems:files];
    [self playlistDidChange];
    return [session state] == PlayerSessionPlaying;
}

- (IBAction)openFile:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:YES];
    [panel setAllowsMultipleSelection:YES];
    [panel setAllowedFileTypes:[self mediaExtensions]];
    [panel setTitle:@"Open"];
    if ([panel runModal] != NSFileHandlingPanelOKButton) {
        return;
    }
    NSMutableArray *paths = [NSMutableArray array];
    for (NSURL *url in [panel URLs]) {
        [paths addObject:[url path]];
    }
    [self openPaths:paths];
}

- (IBAction)openURL:(id)sender
{
    NSString *url = [self runURLDialog];
    if ([url length] == 0) {
        return;
    }
    NSString *lower = [url lowercaseString];
    BOOL web = [lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"];
    NSString *ext = [[[NSURL URLWithString:url] path] pathExtension];
    BOOL directMedia = [[self mediaExtensions] containsObject:[ext lowercaseString]]
        || [@[@"m3u8", @"m3u", @"pls"] containsObject:[ext lowercaseString]];

    // Web pages (YouTube and the like) need yt-dlp to find the media in
    // them; media URLs and other schemes (rtsp, mms) play directly.
    if (!web || directMedia) {
        [self playStreamURL:url title:nil];
        return;
    }
    [ytdlpBackend setYtdlpPath:[PreferencesController ytdlpPath]];
    if (![ytdlpBackend checkAvailability]) {
        NSAlert *alert = [[[NSAlert alloc] init] autorelease];
        [alert setMessageText:@"Web Page Addresses Need yt-dlp"];
        [alert setInformativeText:@"To play media from web pages such as video sites, "
            @"install yt-dlp with your package manager, or set its location in Preferences.\n\n"
            @"Addresses of media files and radio streams play without it."];
        [alert addButtonWithTitle:@"Open Preferences"];
        [alert addButtonWithTitle:@"Play Directly"];
        [alert addButtonWithTitle:@"Cancel"];
        NSInteger answer = [alert runModal];
        if (answer == NSAlertFirstButtonReturn) {
            [self openPreferences:sender];
        } else if (answer == NSAlertSecondButtonReturn) {
            [self playStreamURL:url title:nil];
        }
        return;
    }
    [ytdlpBackend setFormatSpec:[PreferencesController selectedFormat]];
    [progressIndicator startAnimation:self];
    [mainWindow setTitle:@"Player - Finding media..."];
    [ytdlpBackend resolveURL:url];
}

- (void)playStreamURL:(NSString *)url title:(NSString *)title
{
    if (playerMode == PlayerModeRadio) {
        [self exitRadioMode];
    }
    if ([title length] > 0) {
        [streamTitles setObject:title forKey:url];
    }
    errorAlertShown = NO;
    [session openItems:@[url]];
    [self playlistDidChange];
}

- (NSString *)runURLDialog
{
    NSRect frame = NSMakeRect(0, 0, 460, 132);
    NSPanel *panel = [[[NSPanel alloc] initWithContentRect:frame
                                                 styleMask:NSTitledWindowMask
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO] autorelease];
    [panel setTitle:@"Open URL"];
    NSView *cv = [panel contentView];
    CGFloat left = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat width = NSWidth(frame) - 2 * left;
    CGFloat y = NSHeight(frame) - METRICS_CONTENT_TOP_MARGIN - 17;

    NSTextField *message = [[[NSTextField alloc] initWithFrame:
        NSMakeRect(left, y, width, 17)] autorelease];
    [message setStringValue:@"Address of a media file, radio stream, or video page:"];
    [message setEditable:NO];
    [message setSelectable:NO];
    [message setBezeled:NO];
    [message setDrawsBackground:NO];
    [message setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [cv addSubview:message];

    y -= METRICS_SPACE_8 + METRICS_TEXT_INPUT_FIELD_HEIGHT;
    NSTextField *input = [[[NSTextField alloc] initWithFrame:
        NSMakeRect(left, y, width, METRICS_TEXT_INPUT_FIELD_HEIGHT)] autorelease];
    [input setEditable:YES];
    [input setSelectable:YES];
    [input setBezeled:YES];
    [input setDrawsBackground:YES];
    [[input cell] setPlaceholderString:@"https://"];
    [cv addSubview:input];

    CGFloat buttonX = NSWidth(frame) - left - METRICS_BUTTON_MIN_WIDTH;
    NSButton *ok = [[[NSButton alloc] initWithFrame:NSMakeRect(buttonX,
        METRICS_CONTENT_BOTTOM_MARGIN, METRICS_BUTTON_MIN_WIDTH, METRICS_BUTTON_HEIGHT)] autorelease];
    [ok setTitle:@"Open"];
    [ok setBezelStyle:NSRoundedBezelStyle];
    [ok setKeyEquivalent:@"\r"];
    [ok setTarget:NSApp];
    [ok setAction:@selector(stopModal)];
    [cv addSubview:ok];

    buttonX -= METRICS_BUTTON_HORIZ_INTERSPACE + METRICS_BUTTON_MIN_WIDTH;
    NSButton *cancel = [[[NSButton alloc] initWithFrame:NSMakeRect(buttonX,
        METRICS_CONTENT_BOTTOM_MARGIN, METRICS_BUTTON_MIN_WIDTH, METRICS_BUTTON_HEIGHT)] autorelease];
    [cancel setTitle:@"Cancel"];
    [cancel setBezelStyle:NSRoundedBezelStyle];
    [cancel setKeyEquivalent:@"\e"];
    [cancel setTarget:NSApp];
    [cancel setAction:@selector(abortModal)];
    [cv addSubview:cancel];

    [panel setInitialFirstResponder:input];
    [panel center];
    NSInteger response = [NSApp runModalForWindow:panel];
    [panel orderOut:nil];
    if (response != NSRunStoppedResponse) {
        return nil;
    }
    return [[input stringValue] stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (IBAction)openPreferences:(id)sender
{
    if (!preferencesController) {
        preferencesController = [[PreferencesController alloc] init];
    }
    [preferencesController showPreferencesWindow:mainWindow];
}

#pragma mark - YTDLPBackendDelegate

- (void)ytdlpBackend:(YTDLPBackend *)backend didResolveURL:(NSString *)streamURL
               title:(NSString *)title thumbnail:(NSString *)thumbnailURL
            duration:(NSTimeInterval)duration
{
    [progressIndicator stopAnimation:self];
    [self playStreamURL:streamURL title:title];
}

- (void)ytdlpBackend:(YTDLPBackend *)backend didFailWithError:(NSString *)error
{
    [progressIndicator stopAnimation:self];
    [self updateWindowTitle];
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setAlertStyle:NSWarningAlertStyle];
    [alert setMessageText:@"No Media Found at This Address"];
    [alert setInformativeText:error ?: @""];
    [alert runModal];
}

- (void)ytdlpBackendDidCancel:(YTDLPBackend *)backend
{
    [progressIndicator stopAnimation:self];
    [self updateWindowTitle];
}

#pragma mark - Playback commands

- (IBAction)playPause:(id)sender
{
    if (playerMode == PlayerModeRadio) {
        [self radioPlayPause];
    } else {
        [session togglePlayPause];
    }
}

- (IBAction)stop:(id)sender
{
    if (playerMode == PlayerModeRadio) {
        [self radioStop];
    } else {
        [session stop];
    }
}

- (IBAction)nextTrack:(id)sender
{
    if (playerMode == PlayerModeRadio) {
        [self radioNextStation];
    } else {
        [session next];
    }
}

- (IBAction)previousTrack:(id)sender
{
    if (playerMode == PlayerModeRadio) {
        [self radioPreviousStation];
    } else {
        [session previous];
    }
}

- (IBAction)seekToTime:(id)sender
{
    [session seekToTime:[timeSlider doubleValue]];
    [self updatePosition];
}

- (IBAction)toggleRepeat:(id)sender
{
    PlayerPlaylist *playlist = [session playlist];
    [playlist setRepeat:![playlist repeat]];
    [[NSUserDefaults standardUserDefaults] setBool:[playlist repeat] forKey:PlayerDefaultsRepeat];
    [self updateControls];
}

- (IBAction)toggleShuffle:(id)sender
{
    PlayerPlaylist *playlist = [session playlist];
    [playlist setShuffle:![playlist shuffle]];
    [[NSUserDefaults standardUserDefaults] setBool:[playlist shuffle] forKey:PlayerDefaultsShuffle];
    [self updateControls];
}

#pragma mark - Volume

- (float)volume
{
    return [session volume];
}

// Local playback and the radio share one volume
- (void)applyVolume:(float)volume
{
    [session setVolume:volume];
    [[RadioManager sharedManager] setVolume:volume];
}

- (void)setVolume:(float)volume
{
    volume = MAX(0.0f, MIN(1.0f, volume));
    [self applyVolume:volume];
    [volumeSlider setFloatValue:volume];
    [[NSUserDefaults standardUserDefaults] setFloat:volume forKey:PlayerDefaultsVolume];
}

- (IBAction)volumeChanged:(id)sender
{
    [self setVolume:[volumeSlider floatValue]];
}

- (IBAction)increaseVolume:(id)sender
{
    [self setVolume:[self volume] + kVolumeStep];
}

- (IBAction)decreaseVolume:(id)sender
{
    [self setVolume:[self volume] - kVolumeStep];
}

- (IBAction)toggleMute:(id)sender
{
    // The checkbox has already flipped when it sends this
    BOOL muted = (sender == muteCheckbox) ? ([muteCheckbox state] == NSOnState) : ![session muted];
    [session setMuted:muted];
    [[RadioManager sharedManager] setMuted:muted];
    [muteCheckbox setState:muted ? NSOnState : NSOffState];
    [[NSUserDefaults standardUserDefaults] setBool:muted forKey:PlayerDefaultsMuted];
}

#pragma mark - PlayerSessionDelegate

- (void)playerSessionDidChangeState:(PlayerSession *)aSession
{
    if ([session state] == PlayerSessionPlaying) {
        if (!positionTimer) {
            positionTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                             target:self
                                                           selector:@selector(positionTimerFired:)
                                                           userInfo:nil
                                                            repeats:YES];
        }
    } else {
        [positionTimer invalidate];
        positionTimer = nil;
    }
    if ([session state] == PlayerSessionStopped) {
        [self showCoverArt];
    }
    [self updateControls];
    [self showOverlay];
}

- (void)playerSessionDidChangeTrack:(PlayerSession *)aSession
{
    [videoRenderView clear];
    [self showCoverArt];
    [self updateTrackInfo];
    [self updateControls];

    NSUInteger index = [[session playlist] currentIndex];
    if (index != NSNotFound && index != [flowView selectedIndex]) {
        suppressFlowSelection = YES;
        [flowView setSelectedIndex:index];
        suppressFlowSelection = NO;
    }
}

- (void)playerSession:(PlayerSession *)aSession didFailToOpenItem:(NSString *)item
                error:(NSError *)error
{
    NSLog(@"Player: cannot play %@: %@", item, [error localizedDescription]);
    // One alert per open, not one for every broken file of an album
    if (errorAlertShown) {
        return;
    }
    errorAlertShown = YES;
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setAlertStyle:NSWarningAlertStyle];
    [alert setMessageText:[NSString stringWithFormat:@"\"%@\" Cannot Be Played",
                           [self displayNameForItem:item]]];
    [alert setInformativeText:[error localizedDescription] ?: @""];
    [alert runModal];
}

- (void)playerSession:(PlayerSession *)aSession didDiscoverVideoWithWidth:(int)width
               height:(int)height
{
    [flowView setHidden:YES];
    [videoView setHidden:NO];
    [self layoutSubviews];
    [self updateControls];
}

- (void)playerSession:(PlayerSession *)aSession didDecodeVideoFrameData:(NSData *)data
                width:(int)width height:(int)height
{
    if (![videoView isHidden]) {
        [videoRenderView setFrameData:data width:width height:height];
    }
}

// Full screen is for pictures; it ends with the video
- (void)showCoverArt
{
    if (![videoView isHidden]) {
        [videoView setHidden:YES];
        [flowView setHidden:NO];
        [self exitFullscreen];
        [self layoutSubviews];
        [self updateControls];
    }
}

- (BOOL)showsVideo
{
    return ![videoView isHidden];
}

#pragma mark - Showing state

- (void)positionTimerFired:(NSTimer *)timer
{
    [self updatePosition];
}

- (NSString *)formatTime:(NSTimeInterval)seconds
{
    if (seconds < 0 || isnan(seconds) || isinf(seconds)) {
        seconds = 0;
    }
    long total = lround(seconds);
    if (total >= 3600) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld",
                total / 3600, (total % 3600) / 60, total % 60];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", total / 60, total % 60];
}

- (void)updatePosition
{
    NSTimeInterval duration = [session duration];
    NSTimeInterval position = [session currentTime];
    BOOL stopped = ([session state] == PlayerSessionStopped);

    [currentTimeLabel setStringValue:[self formatTime:position]];
    // A live stream has no end to show
    [totalTimeLabel setStringValue:(duration > 0 || stopped) ? [self formatTime:duration] : @"Live"];
    [timeSlider setEnabled:[session canSeek]];
    [timeSlider setMaxValue:MAX(duration, 1.0)];
    [timeSlider setDoubleValue:MIN(position, MAX(duration, 1.0))];
}

- (void)updateControls
{
    if (playerMode == PlayerModeRadio) {
        [self updateRadioControls];
        return;
    }
    BOOL playing = ([session state] == PlayerSessionPlaying);
    [playButton setImage:playing ? pauseImage : playImage];
    [playButton setTitle:playing ? @"Pause" : @"Play"];
    [playButton setToolTip:[playButton title]];
    [playButton setEnabled:[session canPlay]];
    [stopButton setEnabled:[session canStop]];
    [previousButton setEnabled:[session canGoPrevious]];
    [nextButton setEnabled:[session canGoNext]];
    [fullscreenButton setEnabled:[self showsVideo]];
    [self updatePosition];
    [self revalidateMenu];
}

// Titles, check marks and enabled state of the menu follow the player's
// state right away: the global menu bar shows them, and NSMenu -update
// validates only the submenus that are open on screen.
- (void)revalidateMenu
{
    for (NSMenuItem *item in [[NSApp mainMenu] itemArray]) {
        [[item submenu] update];
    }
}

- (NSString *)displayNameForItem:(NSString *)item
{
    NSString *title = [streamTitles objectForKey:item];
    if (title) {
        return title;
    }
    if ([item rangeOfString:@"://"].location != NSNotFound) {
        return item;
    }
    return [[item lastPathComponent] stringByDeletingPathExtension];
}

- (NSDictionary *)metadataForItem:(NSString *)item
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if ([item rangeOfString:@"://"].location != NSNotFound) {
        return info;
    }
    AVURLAsset *asset = [[[AVURLAsset alloc] initWithURL:[NSURL fileURLWithPath:item]
                                                  options:nil] autorelease];
    for (AVMetadataItem *entry in [asset commonMetadata]) {
        id key = [entry key];
        NSString *value = [entry stringValue];
        if ([key isKindOfClass:[NSString class]] && [value length] > 0) {
            [info setObject:value forKey:key];
        }
    }
    return info;
}

- (void)updateTrackInfo
{
    NSString *item = [[session playlist] currentItem];
    if (!item) {
        [titleLabel setStringValue:@"No file loaded"];
        [artistLabel setStringValue:@"Open files, or drop them here."];
        [albumLabel setStringValue:@""];
        [detailsLabel setStringValue:@""];
        [self updateWindowTitle];
        return;
    }

    NSDictionary *meta = [self metadataForItem:item];
    NSString *title = [meta objectForKey:AVMetadataCommonKeyTitle] ?: [self displayNameForItem:item];
    [titleLabel setStringValue:title];
    [artistLabel setStringValue:[meta objectForKey:AVMetadataCommonKeyArtist] ?: @""];
    [albumLabel setStringValue:[meta objectForKey:AVMetadataCommonKeyAlbumName] ?: @""];

    NSMutableArray *details = [NSMutableArray array];
    PlayerPlaylist *playlist = [session playlist];
    if ([playlist count] > 1) {
        [details addObject:[NSString stringWithFormat:@"%lu of %lu",
            (unsigned long)[playlist currentIndex] + 1, (unsigned long)[playlist count]]];
    }
    if ([item rangeOfString:@"://"].location != NSNotFound) {
        [details addObject:@"Stream"];
    }
    for (NSString *key in @[AVMetadataCommonKeyGenre, AVMetadataCommonKeyComposer]) {
        if ([meta objectForKey:key]) {
            [details addObject:[meta objectForKey:key]];
        }
    }
    [detailsLabel setStringValue:[details componentsJoinedByString:@"  -  "]];
    [self updateWindowTitle];
}

- (void)updateWindowTitle
{
    NSString *item = [[session playlist] currentItem];
    if (playerMode == PlayerModeRadio) {
        NSString *station = [[RadioManager sharedManager] currentStationName];
        [mainWindow setTitle:station ? [NSString stringWithFormat:@"Player - %@", station]
                                     : @"Player - Internet Radio"];
    } else if (item) {
        [mainWindow setTitle:[NSString stringWithFormat:@"Player - %@", [titleLabel stringValue]]];
    } else {
        [mainWindow setTitle:@"Player"];
    }
}

#pragma mark - Cover art

- (void)playlistDidChange
{
    [flowView reloadData];
    NSUInteger index = [[session playlist] currentIndex];
    if (index != NSNotFound) {
        suppressFlowSelection = YES;
        [flowView setSelectedIndex:index];
        suppressFlowSelection = NO;
    }
    [self loadCoverArt];
    [self updateTrackInfo];
    [self updateControls];
}

// Covers are read on a thread of their own, a slow disk must not freeze
// the window.
- (void)loadCoverArt
{
    NSMutableArray *missing = [NSMutableArray array];
    for (NSString *item in [[session playlist] items]) {
        if (![coverImages objectForKey:item]) {
            [missing addObject:item];
        }
    }
    if ([missing count] > 0) {
        [NSThread detachNewThreadSelector:@selector(readCoverArt:) toTarget:self withObject:missing];
    }
    [self refreshCoverTextures];
}

- (void)readCoverArt:(NSArray *)items
{
    @autoreleasepool {
        NSMutableDictionary *found = [NSMutableDictionary dictionary];
        for (NSString *item in items) {
            NSData *data = [self artworkDataForItem:item];
            if (data) {
                [found setObject:data forKey:item];
            }
        }
        [self performSelectorOnMainThread:@selector(coverArtRead:)
                               withObject:@[items, found]
                            waitUntilDone:NO];
    }
}

- (NSData *)artworkDataForItem:(NSString *)item
{
    if ([item rangeOfString:@"://"].location != NSNotFound) {
        return nil;
    }
    AVURLAsset *asset = [[[AVURLAsset alloc] initWithURL:[NSURL fileURLWithPath:item]
                                                  options:nil] autorelease];
    for (AVMetadataItem *entry in [asset commonMetadata]) {
        if ([[entry key] isEqual:AVMetadataCommonKeyArtwork]
            && [[entry value] isKindOfClass:[NSData class]]) {
            return (NSData *)[entry value];
        }
    }
    return nil;
}

- (void)coverArtRead:(NSArray *)result
{
    NSArray *items = [result objectAtIndex:0];
    NSDictionary *found = [result objectAtIndex:1];
    for (NSString *item in items) {
        NSData *data = [found objectForKey:item];
        NSImage *image = data ? [[[NSImage alloc] initWithData:data] autorelease] : nil;
        [coverImages setObject:image ?: [self placeholderCoverForItem:item] forKey:item];
    }
    [self refreshCoverTextures];
}

// Tracks without artwork show their title on a plain sleeve, so the
// carousel tells them apart.
- (NSImage *)placeholderCoverForItem:(NSString *)item
{
    NSSize size = NSMakeSize(256, 256);
    NSImage *image = [[[NSImage alloc] initWithSize:size] autorelease];
    NSString *title = [[self metadataForItem:item] objectForKey:AVMetadataCommonKeyTitle]
        ?: [self displayNameForItem:item];

    [image lockFocus];
    NSGradient *gradient = [[[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithCalibratedWhite:0.35 alpha:1.0]
                  endingColor:[NSColor colorWithCalibratedWhite:0.15 alpha:1.0]] autorelease];
    [gradient drawInRect:NSMakeRect(0, 0, size.width, size.height) angle:90];

    NSMutableParagraphStyle *style = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [style setAlignment:NSCenterTextAlignment];
    [style setLineBreakMode:NSLineBreakByWordWrapping];
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont boldSystemFontOfSize:22],
                            NSForegroundColorAttributeName: [NSColor whiteColor],
                            NSParagraphStyleAttributeName: style};
    // Vertically centered: as many lines as the wrapped title needs
    CGFloat width = size.width - 40;
    NSSize oneLine = [title sizeWithAttributes:attrs];
    CGFloat height = MIN(size.height - 40, ceil(oneLine.width / width) * oneLine.height);
    [title drawInRect:NSMakeRect(20, floor((size.height - height) / 2.0), width, height)
       withAttributes:attrs];
    [image unlockFocus];
    return image;
}

- (void)refreshCoverTextures
{
    if (playerMode != PlayerModeLocal) {
        return;
    }
    NSArray *items = [[session playlist] items];
    NSMutableIndexSet *indices = [NSMutableIndexSet indexSet];
    NSUInteger i;
    for (i = 0; i < [items count]; i++) {
        if ([coverImages objectForKey:[items objectAtIndex:i]]) {
            [indices addIndex:i];
        }
    }
    [flowView updateTexturesForIndices:indices];
}

#pragma mark - ItemFlowView

- (NSUInteger)numberOfItemsInItemFlowView:(ItemFlowView *)view
{
    if (playerMode == PlayerModeRadio) {
        return [[[RadioManager sharedManager] stations] count];
    }
    return [[session playlist] count];
}

- (NSImage *)itemFlowView:(ItemFlowView *)view imageAtIndex:(NSUInteger)index
{
    if (playerMode == PlayerModeRadio) {
        NSArray *stations = [[RadioManager sharedManager] stations];
        return index < [stations count]
            ? [[RadioManager sharedManager] imageForStation:[stations objectAtIndex:index]] : nil;
    }
    return [coverImages objectForKey:[[session playlist] itemAtIndex:index]];
}

- (void)itemFlowView:(ItemFlowView *)view didSelectItemAtIndex:(NSUInteger)index
{
    if (suppressFlowSelection) {
        return;
    }
    // Plays once browsing rests on a cover
    pendingFlowIndex = index;
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(playBrowsedItem)
                                               object:nil];
    [self performSelector:@selector(playBrowsedItem) withObject:nil afterDelay:kBrowseDelay];
}

- (void)playBrowsedItem
{
    NSUInteger index = pendingFlowIndex;
    pendingFlowIndex = NSNotFound;
    if (index == NSNotFound) {
        return;
    }
    if (playerMode == PlayerModeRadio) {
        [self radioSelectStationAtIndex:index];
    } else {
        [session playItemAtIndex:index];
    }
}

#pragma mark - Menu validation

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SEL action = [item action];
    BOOL local = (playerMode == PlayerModeLocal);

    if (action == @selector(playPause:)) {
        [item setTitle:[playButton title]];
        return [playButton isEnabled];
    }
    if (action == @selector(stop:)) {
        return [stopButton isEnabled];
    }
    if (action == @selector(nextTrack:)) {
        return [nextButton isEnabled];
    }
    if (action == @selector(previousTrack:)) {
        return [previousButton isEnabled];
    }
    if (action == @selector(toggleRepeat:)) {
        [item setState:[[session playlist] repeat] ? NSOnState : NSOffState];
        return local;
    }
    if (action == @selector(toggleShuffle:)) {
        [item setState:[[session playlist] shuffle] ? NSOnState : NSOffState];
        return local;
    }
    if (action == @selector(toggleMute:)) {
        [item setState:[session muted] ? NSOnState : NSOffState];
        return YES;
    }
    if (action == @selector(increaseVolume:)) {
        return [self volume] < 1.0f;
    }
    if (action == @selector(decreaseVolume:)) {
        return [self volume] > 0.0f;
    }
    if (action == @selector(toggleFullscreen:)) {
        [item setTitle:isFullscreen ? @"Exit Full Screen" : @"Enter Full Screen"];
        return isFullscreen || [self showsVideo];
    }
    return [self validateRadioMenuItem:item];
}

@end
