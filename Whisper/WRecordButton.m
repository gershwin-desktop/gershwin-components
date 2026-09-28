/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WRecordButton.h"
#import "AppearanceMetrics.h"

/* The stop square: how much of the button's picture it fills, and how much of
   its own side the corner rounding takes. */
#define WRECORD_STOP_INSET  0.26
#define WRECORD_STOP_RADIUS 0.20

/* The record red, the same one the desktop uses for a recording indicator. */
static NSColor *
WRecordRed(void)
{
  static NSColor *red = nil;

  if (red == nil)
    {
      red = [[NSColor colorWithCalibratedRed: 0.78
                                       green: 0.15
                                        blue: 0.15
                                       alpha: 1.0] retain];
    }
  return red;
}

@interface WRecordButton ()
- (void)commonInit;
- (NSImage *)applicationIcon;
- (NSImage *)stopImage;
- (void)drawStopSquare:(NSCustomImageRep *)rep;
@end

@implementation WRecordButton

/* The application icon, as the Info dictionary names it.  Reading it from the
   bundle is the fallback for a session without a Dock icon
   (GSSuppressAppIcon), where there is no application icon image. */
- (NSImage *) applicationIcon
{
  NSImage *icon = [NSApp applicationIconImage];
  NSString *path;

  if (icon == nil)
    {
      path = [[NSBundle mainBundle] pathForResource: @"Whisper"
                                             ofType: @"png"];
      if (path != nil)
        {
          icon = [[[NSImage alloc] initWithContentsOfFile: path] autorelease];
        }
    }
  return icon;
}

/* The stop square that stands in for the icon while recording.  It is drawn
   when the cell asks for it rather than pre-rendered into a bitmap, which is
   how a generated picture is made everywhere else in the desktop (see
   PRAppearance).  -draw is sent the representation rather than a rectangle,
   so the square is laid out from the representation's own size. */
- (void) drawStopSquare: (NSCustomImageRep *)rep
{
  NSSize size = [rep size];
  CGFloat inset = size.width * WRECORD_STOP_INSET;
  NSRect square = NSInsetRect(NSMakeRect(0.0, 0.0, size.width, size.height),
                              inset, inset);
  CGFloat radius = square.size.width * WRECORD_STOP_RADIUS;

  [WRecordRed() set];
  [[NSBezierPath bezierPathWithRoundedRect: square
                                    xRadius: radius
                                    yRadius: radius] fill];
}

- (NSImage *) stopImage
{
  NSSize square = NSMakeSize(METRICS_ICON_BUTTON_SIDE,
                             METRICS_ICON_BUTTON_SIDE);
  NSImage *image = [[[NSImage alloc] initWithSize: square] autorelease];
  NSCustomImageRep *rep = [[[NSCustomImageRep alloc]
                             initWithDrawSelector: @selector(drawStopSquare:)
                             delegate: self] autorelease];

  [rep setSize: square];
  [image addRepresentation: rep];
  return [image retain];
}

- (void) commonInit
{
  recording = NO;

  /* An ordinary themed button: the desktop draws the bezel, the pressed and
     disabled states and the image, exactly as it does for every other button.
     Only the title is hidden - it names the control for accessibility and for
     the UI tests, and the image says it on screen. */
  [self setBezelStyle: NSRoundedBezelStyle];
  [self setImagePosition: NSImageOnly];
  [self setTitle: @"Record"];
  [self setToolTip: @"Start recording"];

  /* The cell draws an image at its own size, so the application icon - a
     500pt canvas - has to be scaled down into the button.  The cell draws
     images the right way up, so the icon does not come out mirrored. */
  [[self cell] setImageScaling: NSImageScaleProportionallyDown];
  [recordImage release];
  recordImage = [[self applicationIcon] retain];
  [stopImage release];
  stopImage = [[self stopImage] retain];
  [self setImage: recordImage];
}

- (id) initWithFrame: (NSRect)frame
{
  self = [super initWithFrame: frame];
  if (self != nil)
    {
      [self commonInit];
    }
  return self;
}

- (id) initWithCoder: (NSCoder *)coder
{
  self = [super initWithCoder: coder];
  if (self != nil)
    {
      [self commonInit];
    }
  return self;
}

- (void) dealloc
{
  [recordImage release];
  [stopImage release];
  [super dealloc];
}

#pragma mark - State

- (BOOL) isRecording
{
  return recording;
}

- (void) setRecording: (BOOL)flag
{
  if (recording == flag)
    {
      return;
    }
  recording = flag;
  [self setImage: flag ? stopImage : recordImage];
  [self setTitle: flag ? @"Stop" : @"Record"];
  [self setToolTip: flag ? @"Stop recording" : @"Start recording"];
}

- (void) resetCursorRects
{
  if ([self isEnabled])
    {
      [self addCursorRect: [self bounds]
                   cursor: [NSCursor pointingHandCursor]];
    }
}

@end
