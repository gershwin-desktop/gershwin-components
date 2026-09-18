/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ScreenshotCapture.h"
#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSTheme.h>

/* Long enough to be noticed, short enough not to be in the way. */
static const NSTimeInterval kFlashDuration = 0.15;

static NSString * const kIncludeWindowFrameKey = @"ScreenshotIncludeWindowTitle";
static NSString * const kIncludeWindowShadowKey = @"ScreenshotIncludeWindowShadow";

// Optional theme methods (implemented by some themes, e.g. Eau); queried
// with respondsToSelector: like the window manager does.
@interface NSObject (ScreenshotThemeCornerRadii)
- (CGFloat)titlebarCornerRadius;
- (CGFloat)windowBottomCornerRadius;
@end

@implementation ScreenshotPreferences

+ (void)initialize
{
    if (self == [ScreenshotPreferences class]) {
        [[NSUserDefaults standardUserDefaults] registerDefaults:
            [NSDictionary dictionaryWithObjectsAndKeys:
                [NSNumber numberWithBool:YES], kIncludeWindowFrameKey,
                [NSNumber numberWithBool:YES], kIncludeWindowShadowKey,
                nil]];
    }
}

+ (BOOL)includeWindowFrame
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:kIncludeWindowFrameKey];
}

+ (void)setIncludeWindowFrame:(BOOL)flag
{
    [[NSUserDefaults standardUserDefaults] setBool:flag forKey:kIncludeWindowFrameKey];
}

+ (BOOL)includeWindowShadow
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:kIncludeWindowShadowKey];
}

+ (void)setIncludeWindowShadow:(BOOL)flag
{
    [[NSUserDefaults standardUserDefaults] setBool:flag forKey:kIncludeWindowShadowKey];
}

@end

@implementation ScreenshotCapture

+ (NSBitmapImageRep *)captureWithMode:(ScreenshotMode)mode
                         includeFrame:(BOOL)includeFrame
                        includeShadow:(BOOL)includeShadow
                               status:(CaptureStatus *)status
{
    CaptureSnapshot *snapshot = NULL;
    *status = x11_snapshot_take(&snapshot);
    if (*status != CaptureStatusOK)
        return nil;

    unsigned char *pixels = NULL;
    int width = 0, height = 0;

    switch (mode) {
    case ScreenshotModeWindow: {
        WindowSelection selection;
        *status = x11_select_window(snapshot, includeFrame, &selection);
        if (*status != CaptureStatusOK)
            break;
        // Match the corners the window manager draws for the current theme
        id theme = [GSTheme theme];
        float topRadius = 0, bottomRadius = 0;
        if ([theme respondsToSelector:@selector(titlebarCornerRadius)])
            topRadius = [theme titlebarCornerRadius];
        if ([theme respondsToSelector:@selector(windowBottomCornerRadius)])
            bottomRadius = [theme windowBottomCornerRadius];
        pixels = x11_capture_window(snapshot, &selection, includeShadow,
                                    topRadius, bottomRadius, &width, &height);
        break;
    }
    case ScreenshotModeArea: {
        CaptureRect rect;
        *status = x11_select_area(snapshot, &rect);
        if (*status != CaptureStatusOK)
            break;
        pixels = x11_capture_area(snapshot, rect, &width, &height);
        break;
    }
    case ScreenshotModeScreen:
        pixels = x11_capture_screen(snapshot, &width, &height);
        break;
    }
    x11_snapshot_free(snapshot);

    if (*status != CaptureStatusOK)
        return nil;
    if (!pixels) {
        *status = CaptureStatusReadFailed;
        return nil;
    }

    NSBitmapImageRep *imageRep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:width
                      pixelsHigh:height
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace
                    bitmapFormat:NSAlphaNonpremultipliedBitmapFormat
                     bytesPerRow:width * 4
                    bitsPerPixel:32];
    memcpy([imageRep bitmapData], pixels, (size_t)width * height * 4);
    free(pixels);
    *status = CaptureStatusOK;
    return [imageRep autorelease];
}

+ (NSString *)messageForStatus:(CaptureStatus)status
{
    switch (status) {
    case CaptureStatusNoDisplay:
        return NSLocalizedString(@"The X11 display could not be opened.", @"");
    case CaptureStatusReadFailed:
        return NSLocalizedString(@"The screen contents could not be read.", @"");
    case CaptureStatusOK:
    case CaptureStatusCancelled:
        break;
    }
    return nil;
}

+ (NSData *)PNGDataForImageRep:(NSBitmapImageRep *)imageRep
{
    return [imageRep representationUsingType:NSPNGFileType
                                  properties:[NSDictionary dictionary]];
}

+ (NSString *)defaultFilePath
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd-HHmmss"];
    NSString *name = [NSString stringWithFormat:@"Screenshot-%@.png",
                      [formatter stringFromDate:[NSDate date]]];
    [formatter release];

    NSArray *desktops = NSSearchPathForDirectoriesInDomains(NSDesktopDirectory,
                                                            NSUserDomainMask, YES);
    return [[desktops objectAtIndex:0] stringByAppendingPathComponent:name];
}

+ (void)flashScreen
{
    NSWindow *flash = [[NSWindow alloc] initWithContentRect:[[NSScreen mainScreen] frame]
                                                  styleMask:NSBorderlessWindowMask
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    [flash setBackgroundColor:[NSColor whiteColor]];
    [flash setLevel:NSScreenSaverWindowLevel + 1];
    [flash setIgnoresMouseEvents:YES];
    [flash orderFrontRegardless];
    [flash display];
    // Blocking on purpose: running the run loop here would let queued clicks
    // start actions in the middle of a capture.  Ordering and displaying
    // already flush the requests to the X server.
    [NSThread sleepForTimeInterval:kFlashDuration];
    [flash orderOut:nil];
    [flash release];
}

@end
