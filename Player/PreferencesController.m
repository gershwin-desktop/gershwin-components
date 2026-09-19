/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PreferencesController.h"
#import "PlayerAsync.h"
#import "AppearanceMetrics.h"

// ---------------------------------------------------------------------------
// UserDefaults keys
// ---------------------------------------------------------------------------
NSString *const PrefKeyYTDLPFormat = @"YTDLPFormat";
NSString *const PrefKeyYTDLPPath   = @"YTDLPPath";
NSString *const PrefKeyFadeEnabled = @"PlayerFadeEnabled";

// Default values
static NSString *const kDefaultFormat = @"best/best";
static NSString *const kDefaultPath   = @"yt-dlp";
static const NSTimeInterval kFadeDuration = 1.0;

// ---------------------------------------------------------------------------
// Popup menu item tags → format strings
// ---------------------------------------------------------------------------
typedef NS_ENUM(NSInteger, FormatTag) {
    FormatTagBestAuto       = 0,
    FormatTagBestAudio      = 1,
    FormatTagBestVideo      = 2,
    FormatTag1080p          = 3,
    FormatTag720p           = 4,
    FormatTag480p           = 5,
    FormatTag360p           = 6,
    FormatTagWorst          = 7,
};

static NSString *formatStringForTag(FormatTag tag)
{
    switch (tag) {
        case FormatTagBestAudio: return @"bestaudio/best";
        case FormatTagBestVideo: return @"best/best";
        case FormatTag1080p:     return @"best[height<=1080]/best";
        case FormatTag720p:      return @"best[height<=720]/best";
        case FormatTag480p:      return @"best[height<=480]/best";
        case FormatTag360p:      return @"best[height<=360]/best";
        case FormatTagWorst:     return @"worst";
        case FormatTagBestAuto:
        default:                 return @"best";
    }
}

static FormatTag tagForFormatString(NSString *format)
{
    if ([format isEqualToString:@"bestaudio/best"])           return FormatTagBestAudio;
    if ([format isEqualToString:@"best/best"])                return FormatTagBestVideo;
    if ([format isEqualToString:@"best[height<=1080]/best"])  return FormatTag1080p;
    if ([format isEqualToString:@"best[height<=720]/best"])   return FormatTag720p;
    if ([format isEqualToString:@"best[height<=480]/best"])   return FormatTag480p;
    if ([format isEqualToString:@"best[height<=360]/best"])   return FormatTag360p;
    if ([format isEqualToString:@"worst"])                     return FormatTagWorst;
    return FormatTagBestAuto;
}

// ---------------------------------------------------------------------------
// PreferencesController
// ---------------------------------------------------------------------------
@implementation PreferencesController

// -----------------------------------------------------------------------
// Class-level helpers (read from UserDefaults)
// -----------------------------------------------------------------------
+ (NSString *)selectedFormat
{
    NSString *fmt = [[NSUserDefaults standardUserDefaults] stringForKey:PrefKeyYTDLPFormat];
    return fmt ? fmt : kDefaultFormat;
}

+ (NSTimeInterval)fadeDuration
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL enabled = [defaults objectForKey:PrefKeyFadeEnabled] == nil
        || [defaults boolForKey:PrefKeyFadeEnabled];
    return enabled ? kFadeDuration : 0.0;
}

+ (NSString *)ytdlpPath
{
    NSString *p = [[NSUserDefaults standardUserDefaults] stringForKey:PrefKeyYTDLPPath];
    return p ? p : kDefaultPath;
}

// -----------------------------------------------------------------------
// Lifecycle
// -----------------------------------------------------------------------
- (instancetype)init
{
    self = [super init];
    if (self) {
        // Build the panel lazily in showPreferencesWindow:
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_panel release];
    [_fadeCheckbox release];
    [super dealloc];
}

// -----------------------------------------------------------------------
// Build the panel
// -----------------------------------------------------------------------
- (void)_buildPanel
{
    if (_panel) return;

    // Content dimensions computed from AppearanceMetrics
    CGFloat margin = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat topMargin = METRICS_CONTENT_TOP_MARGIN;
    CGFloat bottomMargin = METRICS_CONTENT_BOTTOM_MARGIN;
    CGFloat btnH = METRICS_BUTTON_HEIGHT;
    CGFloat inputH = METRICS_TEXT_INPUT_FIELD_HEIGHT;
    CGFloat gap = METRICS_SPACE_16;   // Between control groups
    CGFloat labelW = 100.0;
    CGFloat panelW = 420.0;
    CGFloat popUpW = panelW - 2 * margin - labelW - METRICS_SPACE_8;

    // Row heights: fade checkbox + gap + format popup + gap + path field + gap
    // + check row + bottom margin
    CGFloat checkboxH = 18.0;
    CGFloat contentH = topMargin + checkboxH + gap + btnH + gap + inputH + gap + btnH
        + bottomMargin;
    NSRect panelRect = NSMakeRect(0, 0, panelW, contentH);

    _panel = [[NSPanel alloc] initWithContentRect:panelRect
                                        styleMask:(NSTitledWindowMask |
                                                   NSClosableWindowMask |
                                                   NSUtilityWindowMask)
                                          backing:NSBackingStoreBuffered
                                            defer:YES];
    [_panel setTitle:@"Preferences"];
    [_panel setFloatingPanel:YES];
    [_panel setHidesOnDeactivate:NO];

    // End modal session when window closes via titlebar close button
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_closePanel:)
                                                 name:NSWindowWillCloseNotification
                                               object:_panel];

    NSView *content = [_panel contentView];
    CGFloat y = contentH - topMargin - checkboxH;

    // ---- Fading ----
    NSTextField *soundLabel = [[[NSTextField alloc] initWithFrame:
        NSMakeRect(margin, y, labelW, checkboxH)] autorelease];
    [soundLabel setStringValue:@"Sound:"];
    [soundLabel setBezeled:NO];
    [soundLabel setDrawsBackground:NO];
    [soundLabel setEditable:NO];
    [soundLabel setSelectable:NO];
    [soundLabel setAlignment:NSRightTextAlignment];
    [soundLabel setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [content addSubview:soundLabel];

    _fadeCheckbox = [[NSButton alloc] initWithFrame:
        NSMakeRect(margin + labelW + METRICS_SPACE_8, y, popUpW, checkboxH)];
    [_fadeCheckbox setButtonType:NSSwitchButton];
    [_fadeCheckbox setTitle:@"Fade in and out, cross-fade radio stations"];
    [_fadeCheckbox setState:[PreferencesController fadeDuration] > 0 ? NSOnState : NSOffState];
    [_fadeCheckbox setTarget:self];
    [_fadeCheckbox setAction:@selector(_fadeChanged:)];
    [content addSubview:_fadeCheckbox];

    y -= gap + btnH;

    // ---- Format quality ----
    NSTextField *fmtLabel = [[[NSTextField alloc] initWithFrame:
        NSMakeRect(margin, y, labelW, btnH)] autorelease];
    [fmtLabel setStringValue:@"Stream quality:"];
    [fmtLabel setBezeled:NO];
    [fmtLabel setDrawsBackground:NO];
    [fmtLabel setEditable:NO];
    [fmtLabel setSelectable:NO];
    [fmtLabel setAlignment:NSRightTextAlignment];
    [fmtLabel setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [content addSubview:fmtLabel];

    _formatPopUp = [[NSPopUpButton alloc] initWithFrame:
        NSMakeRect(margin + labelW + METRICS_SPACE_8, y, popUpW, btnH) pullsDown:NO];
    [_formatPopUp addItemWithTitle:@"Best (auto)"];
    [[_formatPopUp lastItem] setTag:FormatTagBestAuto];
    [_formatPopUp addItemWithTitle:@"Best Audio only"];
    [[_formatPopUp lastItem] setTag:FormatTagBestAudio];
    [_formatPopUp addItemWithTitle:@"Best Video+Audio"];
    [[_formatPopUp lastItem] setTag:FormatTagBestVideo];
    [_formatPopUp addItemWithTitle:@"1080p max"];
    [[_formatPopUp lastItem] setTag:FormatTag1080p];
    [_formatPopUp addItemWithTitle:@"720p max"];
    [[_formatPopUp lastItem] setTag:FormatTag720p];
    [_formatPopUp addItemWithTitle:@"480p max"];
    [[_formatPopUp lastItem] setTag:FormatTag480p];
    [_formatPopUp addItemWithTitle:@"360p max"];
    [[_formatPopUp lastItem] setTag:FormatTag360p];
    [_formatPopUp addItemWithTitle:@"Worst"];
    [[_formatPopUp lastItem] setTag:FormatTagWorst];

    // Select current preference
    FormatTag currentTag = tagForFormatString([PreferencesController selectedFormat]);
    [_formatPopUp selectItemWithTag:currentTag];
    if (![_formatPopUp selectedItem]) {
        [_formatPopUp selectItemWithTag:FormatTagBestAudio];
    }
    [_formatPopUp setTarget:self];
    [_formatPopUp setAction:@selector(_formatChanged:)];
    [content addSubview:_formatPopUp];

    y -= gap + inputH;

    // ---- yt-dlp path ----
    NSTextField *pathLabel = [[[NSTextField alloc] initWithFrame:
        NSMakeRect(margin, y, labelW, inputH)] autorelease];
    [pathLabel setStringValue:@"yt-dlp path:"];
    [pathLabel setBezeled:NO];
    [pathLabel setDrawsBackground:NO];
    [pathLabel setEditable:NO];
    [pathLabel setSelectable:NO];
    [pathLabel setAlignment:NSRightTextAlignment];
    [pathLabel setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [content addSubview:pathLabel];

    _pathField = [[NSTextField alloc] initWithFrame:
        NSMakeRect(margin + labelW + METRICS_SPACE_8, y, popUpW, inputH)];
    [_pathField setStringValue:[PreferencesController ytdlpPath]];
    [_pathField setEditable:YES];
    [_pathField setSelectable:YES];
    [_pathField setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [_pathField setTarget:self];
    [_pathField setAction:@selector(_pathFieldAction:)];
    [content addSubview:_pathField];

    y -= gap + btnH;

    // ---- Check availability button ----
    CGFloat checkBtnW = 140.0;
    CGFloat checkBtnX = margin + labelW + METRICS_SPACE_8;
    _checkButton = [[NSButton alloc] initWithFrame:
        NSMakeRect(checkBtnX, y, checkBtnW, btnH)];
    [_checkButton setTitle:@"Check Availability"];
    [_checkButton setBezelStyle:NSRoundedBezelStyle];
    [_checkButton setTarget:self];
    [_checkButton setAction:@selector(_checkAvailability:)];
    [content addSubview:_checkButton];

    _statusLabel = [[NSTextField alloc] initWithFrame:
        NSMakeRect(checkBtnX + checkBtnW + METRICS_SPACE_8, y, popUpW - checkBtnW - METRICS_SPACE_8, btnH)];
    [_statusLabel setStringValue:@""];
    [_statusLabel setBezeled:NO];
    [_statusLabel setDrawsBackground:NO];
    [_statusLabel setEditable:NO];
    [_statusLabel setSelectable:NO];
    [_statusLabel setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [_statusLabel setTextColor:[NSColor grayColor]];
    [content addSubview:_statusLabel];
}

// -----------------------------------------------------------------------
// Actions
// -----------------------------------------------------------------------
- (IBAction)openPreferences:(id)sender
{
    [self showPreferencesWindow:[NSApp keyWindow]];
}

- (void)showPreferencesWindow:(NSWindow *)parentWindow
{
    [self _buildPanel];

    [_panel center];
    [_panel makeKeyAndOrderFront:self];
    [NSApp runModalForWindow:_panel];
}

- (void)_fadeChanged:(id)sender
{
    [[NSUserDefaults standardUserDefaults] setBool:([_fadeCheckbox state] == NSOnState)
                                            forKey:PrefKeyFadeEnabled];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)_formatChanged:(id)sender
{
    FormatTag tag = [[_formatPopUp selectedItem] tag];
    NSString *fmt = formatStringForTag(tag);
    [[NSUserDefaults standardUserDefaults] setObject:fmt forKey:PrefKeyYTDLPFormat];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)_pathFieldAction:(id)sender
{
    NSString *p = [_pathField stringValue];
    if ([p length] == 0) {
        p = kDefaultPath;
        [_pathField setStringValue:p];
    }
    [[NSUserDefaults standardUserDefaults] setObject:p forKey:PrefKeyYTDLPPath];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)_checkAvailability:(id)sender
{
    NSString *path = [[_pathField stringValue] length] > 0
        ? [_pathField stringValue] : kDefaultPath;

    [_checkButton setEnabled:NO];
    [_statusLabel setStringValue:@"Checking…"];
    [_statusLabel setTextColor:[NSColor grayColor]];

    PlayerRunInBackground(^{
        BOOL available = NO;
        @try {
            NSTask *task = [[[NSTask alloc] init] autorelease];
            [task setLaunchPath:path];
            [task setArguments:@[@"--version"]];
            NSPipe *pipe = [[[NSPipe alloc] init] autorelease];
            [task setStandardOutput:pipe];
            [task setStandardError:pipe];
            [task launch];
            [task waitUntilExit];
            available = ([task terminationStatus] == 0);
        } @catch (NSException *e) {
            available = NO;
        }

        PlayerRunOnMainThread(^{
            [_checkButton setEnabled:YES];
            if (available) {
                [_statusLabel setStringValue:@"✓ Available"];
                [_statusLabel setTextColor:[NSColor colorWithCalibratedRed:0.2 green:0.6 blue:0.2 alpha:1.0]];
            } else {
                [_statusLabel setStringValue:@"✗ Not found"];
                [_statusLabel setTextColor:[NSColor redColor]];
            }
        });
    });
}

- (void)_closePanel:(id)sender
{
    [NSApp stopModal];
    [_panel orderOut:self];
}

@end
