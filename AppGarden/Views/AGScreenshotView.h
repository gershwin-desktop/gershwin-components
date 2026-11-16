/* Copyright (c) 2026 Simon Peter / SPDX-License-Identifier: BSD-2-Clause */

#import <AppKit/AppKit.h>

/*
 * The screenshot frame of the detail page: one image letterboxed on a light
 * mount with rounded corners and the card hairline, plus the two states it
 * can be in before and instead of an image.
 *
 * The view only presents. Fetching the picture is the controller's job, so
 * nothing here knows about the network or the image cache; the controller
 * assigns the image when it arrives and marks the failure when it does not.
 */

typedef NS_ENUM(NSInteger, AGScreenshotState) {
  /* Nothing fetched yet, or the fetch is running: centered spinner. */
  AGScreenshotStateLoading = 0,
  /* An image was assigned: drawn aspect-fit inside the mount. */
  AGScreenshotStateLoaded,
  /* The fetch failed or there is nothing to show: one line of grey text,
   * because a broken-picture glyph would promise art we do not have. */
  AGScreenshotStateFailed
};

@interface AGScreenshotView : NSView

/* Assigning a non-nil image moves this to Loaded by itself; assign Failed
 * when the fetch comes back empty, and Loading to start over. */
@property (nonatomic, assign) AGScreenshotState state;

/* Aspect-fit and centered on the mount. Assigning nil leaves the state
 * alone, so clearing an image cannot turn a reported failure into an
 * endless spinner. */
@property (nonatomic, strong) NSImage *image;

/* The height the detail page gives this view for a content width:
 * 9/16 of it, capped so a wide window does not produce a billboard. */
+ (CGFloat)heightForWidth:(CGFloat)width;

@end
