/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ItemFlowView.h"
#import <AppKit/NSOpenGL.h>
#import <AppKit/NSScrollView.h>
#import <AppKit/NSClipView.h>
#import <GNUstepGUI/GSDisplayServer.h>
#import <GL/gl.h>
#import <X11/Xlib.h>
#import <math.h>

// Configuration Constants
#define COVER_SPACING 0.45f
#define CENTER_SPACING 1.3f
#define SIDE_ANGLE 70.0f
#define CAMERA_Z -3.8f
#define CAMERA_Y 0.3f
#define REFLECTION_OPACITY 0.4f
#define ITEM_WIDTH_PX 60.0f // Virtual pixels per item for scroll bar

// Track indices we've logged with missing textures to avoid spamming logs
static NSMutableIndexSet *gItemFlowMissingLogged = nil;
static dispatch_once_t onceTokenMissingLogged;

@interface ItemFlowView () {
    NSMutableArray *_textures; 
    GLuint _placeholderTexID;
    CGFloat _currentPosition;
    CGFloat _targetPosition;
    NSTimer *_animationTimer;
    NSTimeInterval _lastTime;
    BOOL _isSyncingScroll;
}
- (void)updateScrollFrame;
@end

static NSSet *ItemFlowChildWindows(Display *display, Window parent)
{
    Window root, parentOfParent, *children = NULL;
    unsigned int count = 0;
    NSMutableSet *result = [NSMutableSet set];

    if (XQueryTree(display, parent, &root, &parentOfParent, &children, &count)) {
        for (unsigned int i = 0; i < count; i++) {
            [result addObject:@(children[i])];
        }
        XFree(children);
    }
    return result;
}

@implementation ItemFlowView

@synthesize dataSource;
@synthesize delegate;

- (instancetype)initWithFrame:(NSRect)frame {
    NSOpenGLPixelFormatAttribute attrs[] = {
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFADepthSize, 24,
        0
    };
    NSOpenGLPixelFormat *pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
    if (!pf) {
        NSDebugLLog(@"gwcomp", @"Failed to create pixel format");
    }
    
    self = [super initWithFrame:frame pixelFormat:pf];
    if (self) {
        _textures = [NSMutableArray array];
        _currentPosition = 0.0f;
        _targetPosition = 0.0f;
        _isSyncingScroll = NO;
        dispatch_once(&onceTokenMissingLogged, ^{
            gItemFlowMissingLogged = [[NSMutableIndexSet alloc] init];
        });
    }
    return self;

// In drawItemAtIndex we'll detect missing textures and log them once per index.
}

// The backend draws the view in an X subwindow that it creates with a black
// background, so the X server paints it black on every resize before we can
// draw again, and a live window resize flickers black. The backend gives no
// handle to that subwindow, so attach the context here, where the subwindow
// is the one child window that appears meanwhile.
- (NSOpenGLContext *)openGLContext {
    NSWindow *window = [self window];
    if (window == nil || (glcontext != nil && [glcontext view] == self)) {
        return [super openGLContext];
    }

    Display *display = (Display *)[GSServerForWindow(window) serverDevice];
    Window parent = (Window)(uintptr_t)[window windowRef];
    NSSet *before = ItemFlowChildWindows(display, parent);

    NSOpenGLContext *context = [super openGLContext];
    if ([context view] != self) {
        [context setView:self];
    }

    NSMutableSet *added = [ItemFlowChildWindows(display, parent) mutableCopy];
    [added minusSet:before];
    NSAssert1([added count] == 1, @"Expected one new GL subwindow, found %lu",
              (unsigned long)[added count]);
    XSetWindowBackgroundPixmap(display, (Window)[[added anyObject] unsignedLongValue], None);
    return context;
}

- (void)viewDidMoveToSuperview {
    [super viewDidMoveToSuperview];
    if ([self superview] && [[self superview] isKindOfClass:[NSClipView class]]) {
        NSClipView *clipView = (NSClipView *)[self superview];
        [clipView setPostsBoundsChangedNotifications:YES];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(boundDidChange:)
                                                     name:NSViewBoundsDidChangeNotification
                                                   object:clipView];
    }
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self name:NSWindowDidDeminiaturizeNotification object:nil];
    [center removeObserver:self name:NSApplicationDidUnhideNotification object:nil];
    if ([self window]) {
        [center addObserver:self
                   selector:@selector(windowShownAgain:)
                       name:NSWindowDidDeminiaturizeNotification
                     object:[self window]];
        [center addObserver:self
                   selector:@selector(windowShownAgain:)
                       name:NSApplicationDidUnhideNotification
                     object:NSApp];
    }
}

// The picture lives in an X subwindow of its own, which the window's backing
// store does not hold: a window shown again after being minimized or hidden
// gets its own content back, the carousel has to draw itself anew.
- (void)windowShownAgain:(NSNotification *)notification {
    [self setNeedsDisplay:YES];
}

- (void)boundDidChange:(NSNotification *)notification {
    if (_isSyncingScroll) return;

    NSRect visibleRect = [self visibleRect];
    CGFloat contentWidth = visibleRect.size.width;
    CGFloat totalWidth = [self frame].size.width;
    
    if (totalWidth > contentWidth) {
        CGFloat maxScroll = totalWidth - contentWidth;
        CGFloat scrollPos = visibleRect.origin.x;
        CGFloat t = scrollPos / (maxScroll > 0 ? maxScroll : 1.0f);
        
        NSUInteger count = _textures.count;
        if (count > 1) {
             _targetPosition = t * (count - 1);
             [self startAnimation];
        }
    }
}

- (void)updateScrollFrame {
    if ([self superview] && [[self superview] isKindOfClass:[NSClipView class]]) {
        NSView *scrollView = [[self superview] superview];
        CGFloat minWidth = [scrollView bounds].size.width;
        NSUInteger count = _textures.count;
        CGFloat desiredWidth = MAX(minWidth, (CGFloat)count * ITEM_WIDTH_PX);
        
        NSRect frame = [self frame];
        if (frame.size.width != desiredWidth) {
            frame.size.width = desiredWidth;
            [self setFrame:frame];
        }
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_animationTimer invalidate];
    _animationTimer = nil;
    if (_placeholderTexID != 0) {
        glDeleteTextures(1, &_placeholderTexID);
    }
}

- (NSUInteger)selectedIndex {
    return (NSUInteger)round(_targetPosition);
}

- (void)setSelectedIndex:(NSUInteger)index {
    // Clamp
    if (_textures.count > 0 && index >= _textures.count) index = _textures.count - 1;
    if (_textures.count == 0) index = 0;
    
    if (_targetPosition != (CGFloat)index) {
        _targetPosition = (CGFloat)index;
        
        // Notify delegate about the INTENT to select
        if (delegate && [delegate respondsToSelector:@selector(itemFlowView:didSelectItemAtIndex:)]) {
            [delegate itemFlowView:self didSelectItemAtIndex:index];
        }
        
        [self startAnimation];
    }
}

#pragma mark - Animation

- (void)startAnimation {
    if (!_animationTimer) {
        _lastTime = [NSDate timeIntervalSinceReferenceDate];
        _animationTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/60.0 target:self selector:@selector(updateAnimation:) userInfo:nil repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:_animationTimer forMode:NSRunLoopCommonModes];
    }
}

- (void)updateAnimation:(NSTimer *)timer {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval dt = now - _lastTime;
    _lastTime = now;
    
    if (dt > 0.1) dt = 0.1; // Cap dt to prevent jumps
    
    CGFloat diff = _targetPosition - _currentPosition;
    
    // Spring/Lerp physics
    // Simple exponential ease-out
    CGFloat speed = 8.0f;
    CGFloat change = diff * speed * dt;
    
    if (fabs(diff) < 0.005f) {
        _currentPosition = _targetPosition;
        [_animationTimer invalidate];
        _animationTimer = nil;
    } else {
        _currentPosition += change;
    }

    // Sync scroll bar if not already syncing from scroll bar
    if ([self superview] && [[self superview] isKindOfClass:[NSClipView class]]) {
        _isSyncingScroll = YES;
        NSRect visibleRect = [self visibleRect];
        CGFloat totalWidth = [self frame].size.width;
        CGFloat contentWidth = visibleRect.size.width;
        NSUInteger count = _textures.count;
        if (count > 1 && totalWidth > contentWidth) {
            CGFloat t = _currentPosition / (CGFloat)(count - 1);
            CGFloat maxScroll = totalWidth - contentWidth;
            NSPoint scrollPoint = NSMakePoint(t * maxScroll, 0);
            [(NSClipView *)[self superview] scrollToPoint:scrollPoint];
            [(NSScrollView *)[[self superview] superview] reflectScrolledClipView:(NSClipView *)[self superview]];
        }
        _isSyncingScroll = NO;
    }
    
    [self setNeedsDisplay:YES];
}

#pragma mark - OpenGL Setup

- (void)prepareOpenGL {
    [super prepareOpenGL];
    
    glEnable(GL_DEPTH_TEST);
    glEnable(GL_TEXTURE_2D);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f); // Black background
    glHint(GL_PERSPECTIVE_CORRECTION_HINT, GL_NICEST);

    // Create a plain grey placeholder texture
    glGenTextures(1, &_placeholderTexID);
    glBindTexture(GL_TEXTURE_2D, _placeholderTexID);
    GLubyte data[4*4*4]; // 4x4 RGBA
    for (int i = 0; i < 4*4*4; i+=4) {
        data[i] = 180; data[i+1] = 180; data[i+2] = 180; data[i+3] = 255; // Grey
    }
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, data);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
}

- (void)reshape {
    [super reshape];
    NSRect bounds = [self bounds];
    // If we are in a scroll view, use the visible bounds for perspective aspect ratio
    if ([self superview] && [[self superview] isKindOfClass:[NSClipView class]]) {
        bounds = [[self superview] bounds];
    }
    GLsizei w = (GLsizei)bounds.size.width;
    GLsizei h = (GLsizei)bounds.size.height;
    // The GL surface is in device pixels, which differ from points when
    // the window is scaled (GSScaleFactor); window base coordinates are
    // device pixels.
    NSSize pixels = [self convertRect:[self bounds] toView:nil].size;
    glViewport(0, 0, (GLsizei)pixels.width, (GLsizei)pixels.height);
    
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    
    GLdouble aspect = (GLdouble)w / (GLdouble)(h ?: 1);
    
    // gluPerspective equivalent
    GLdouble fovY = 50.0;
    GLdouble zNear = 0.5;
    GLdouble zFar = 100.0;
    GLdouble fH = tan(fovY / 360.0 * M_PI) * zNear;
    GLdouble fW = fH * aspect;
    glFrustum(-fW, fW, -fH, fH, zNear, zFar);
    
    glMatrixMode(GL_MODELVIEW);
}

#pragma mark - Rendering

- (void)drawRect:(NSRect)dirtyRect {
    [[self openGLContext] makeCurrentContext];
    
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glLoadIdentity();
    
    // Offset camera so it's always centered in the visible part of the view
    NSRect visibleRect = [self visibleRect];
    CGFloat viewWidth = [self bounds].size.width;
    if (viewWidth > visibleRect.size.width) {
        CGFloat offsetX = NSMidX(visibleRect) - (viewWidth / 2.0f);
        float aspect = (float)visibleRect.size.width / (float)visibleRect.size.height;
        float h = tanf(50.0f / 360.0f * (float)M_PI) * fabsf(CAMERA_Z);
        float w = h * aspect;
        float glOffsetX = ((float)offsetX / (float)visibleRect.size.width) * (w * 2.0f);
        glTranslatef(glOffsetX, 0.0f, 0.0f);
    }

    glTranslatef(0.0f, CAMERA_Y, CAMERA_Z);
    
    [self drawItems];
    
    [[self openGLContext] flushBuffer];
}

- (void)drawItems {
    NSUInteger count = _textures.count;
    if (count == 0) return;
    
    // Sort items so we draw back-to-front for transparency handling (Painter's Algorithm)
    // The "Peak" is at _currentPosition.
    // Things left of peak (index < current) draw 0 -> floor(current)
    // Things right of peak (index > current) draw max -> ceil(current)
    
    NSInteger centerIdx = (NSInteger)(_currentPosition);
    if (centerIdx < 0) centerIdx = 0;
    
    // Draw Left Stack: 0 up to centerIdx-1
    for (NSInteger i = 0; i < centerIdx; i++) {
        [self drawItemAtIndex:i];
    }
    
    // Draw Right Stack: last down to centerIdx+1
    for (NSInteger i = count - 1; i > centerIdx; i--) {
        [self drawItemAtIndex:i];
    }
    
    // Draw the "middle" items (centerIdx and maybe centerIdx+1 if doing fractional transition)
    // Actually, just draw centerIdx last.
    // It's possible multiple items are 'near' center during transition.
    // Ideally we sort by Z distance.
    // But simplistic sorting:
    // 0..centerIdx (exclusive)
    // count..centerIdx (exclusive)
    // Then centerIdx itself.
    
    [self drawItemAtIndex:centerIdx];
}

- (void)drawItemAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_textures.count) return;
    
    glPushMatrix();
    
    float d = (float)index - _currentPosition;
    float absD = fabsf(d);
    
    float translateX = 0.0f;
    float translateZ = 0.0f;
    float rotateY = 0.0f;
    
    const float zCenter = 0.0f;
    const float zSide = -2.5f;
    
    if (absD < 1.0f) {
        // Transition Zone (0 to 1)
        float t = absD; // 0 is center, 1 is side
        
        // Linear or Ease-in/out
        // X moves from 0 to CENTER_SPACING
        float xDist = CENTER_SPACING * t;
        translateX = (d >= 0) ? xDist : -xDist;
        
        // Z moves from zCenter to zSide
        translateZ = zCenter * (1.0f - t) + zSide * t;
        
        // Rotation 0 to SIDE_ANGLE
        float angle = SIDE_ANGLE * t;
        rotateY = (d >= 0) ? -angle : angle;
        
    } else {
        // Side Zone (> 1)
        float normD = absD - 1.0f;
        float xBase = CENTER_SPACING;
        float xRest = normD * COVER_SPACING;
        
        float xTotal = xBase + xRest;
        translateX = (d >= 0) ? xTotal : -xTotal;
        
        translateZ = zSide;
        rotateY = (d >= 0) ? -SIDE_ANGLE : SIDE_ANGLE;
    }
    
    glTranslatef(translateX, 0.0f, translateZ);
    glRotatef(rotateY, 0.0f, 1.0f, 0.0f);
    
    GLuint texID = [_textures[index] unsignedIntValue];
    glBindTexture(GL_TEXTURE_2D, texID ? texID : _placeholderTexID);
    
    // 1. Draw Reflection w/ Gradient Alpha
    // Save state
    glPushMatrix();
    glTranslatef(0.0f, -2.0f, 0.0f); // Move down
    glScalef(1.0f, -1.0f, 1.0f);     // Flip Y
    
    // Draw Quad with Gradient
    glBegin(GL_QUADS);
    // Reflection Top (geometry bottom -1) -> Alpha REFLECTION_OPACITY
    glColor4f(1.0f, 1.0f, 1.0f, REFLECTION_OPACITY);
    glTexCoord2f(0.0f, 1.0f); glVertex3f(-1.0f, -1.0f, 0.0f);
    glTexCoord2f(1.0f, 1.0f); glVertex3f( 1.0f, -1.0f, 0.0f);
    
    // Reflection Bottom (geometry top +1) -> Alpha 0.0
    glColor4f(1.0f, 1.0f, 1.0f, 0.0f);
    glTexCoord2f(1.0f, 0.0f); glVertex3f( 1.0f,  1.0f, 0.0f);
    glTexCoord2f(0.0f, 0.0f); glVertex3f(-1.0f,  1.0f, 0.0f);
    glEnd();
    
    glPopMatrix();
    
    // 2. Draw Main Image
    // Optional: Darken based on distance
    float brightness = 1.0f;
    if (absD > 0.5f) {
        // Fade to grey slightly when on side
        float factor = (absD - 0.5f) * 0.3f;
        if (factor > 0.6f) factor = 0.6f;
        brightness = 1.0f - factor;
    }
    glColor3f(brightness, brightness, brightness);
    
    glBegin(GL_QUADS);
    glTexCoord2f(0.0f, 1.0f); glVertex3f(-1.0f, -1.0f, 0.0f);
    glTexCoord2f(1.0f, 1.0f); glVertex3f( 1.0f, -1.0f, 0.0f);
    glTexCoord2f(1.0f, 0.0f); glVertex3f( 1.0f,  1.0f, 0.0f);
    glTexCoord2f(0.0f, 0.0f); glVertex3f(-1.0f,  1.0f, 0.0f);
    glEnd();
    
    glPopMatrix();
}

#pragma mark - Data Loading

- (GLuint)createTextureFromImage:(NSImage *)image {
    if (!image) return 0;

    NSBitmapImageRep *bitmap = nil;
    for (NSImageRep *rep in [image representations]) {
        if ([rep isKindOfClass:[NSBitmapImageRep class]]) {
            bitmap = (NSBitmapImageRep *)rep;
            break;
        }
    }
    if (!bitmap) {
        NSData *tiff = [image TIFFRepresentation];
        if (tiff) {
            bitmap = [NSBitmapImageRep imageRepWithData:tiff];
            NSDebugLLog(@"gwcomp", @"[ItemFlow] createTextureFromImage: created bitmap rep from TIFF (bytes=%tu)", tiff ? tiff.length : 0);
        }
    }
    if (!bitmap) {
        NSDebugLLog(@"gwcomp", @"[ItemFlow] createTextureFromImage: failed to obtain NSBitmapImageRep for image size=%@", NSStringFromSize([image size]));
        return 0;
    }

    GLuint texID = 0;
    glGenTextures(1, &texID);
    glBindTexture(GL_TEXTURE_2D, texID);

    // Linear filtering ensures it looks okay when shrunk/rotated
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    // Clamp to edge to avoid border artifacts
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    unsigned char *data = [bitmap bitmapData];
    if (!data) {
        NSDebugLLog(@"gwcomp", @"[ItemFlow] createTextureFromImage: bitmap has no raw data, attempting to use TIFFRepresentation fallback");
        NSData *tiff = [image TIFFRepresentation];
        if (tiff) {
            NSBitmapImageRep *b2 = [NSBitmapImageRep imageRepWithData:tiff];
            data = [b2 bitmapData];
            bitmap = b2;
        }
    }
    if (data) {
        GLenum format = [bitmap hasAlpha] ? GL_RGBA : GL_RGB;
        NSInteger w = [bitmap pixelsWide];
        NSInteger h = [bitmap pixelsHigh];
        NSDebugLLog(@"gwcomp", @"[ItemFlow] createTextureFromImage: uploading texture w=%ld h=%ld alpha=%d", (long)w, (long)h, [bitmap hasAlpha]);

        // Use 1-byte unpack alignment so that RGB images (3 bytes/pixel) with
        // non-4-byte-multiple row widths upload correctly - without this,
        // the default GL_UNPACK_ALIGNMENT of 4 misaligns every row, causing
        // "interlaced" color artifacts (the "stripy" look on some icons).
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (GLsizei)w, (GLsizei)h,
                    0, format, GL_UNSIGNED_BYTE, data);
    } else {
        NSDebugLLog(@"gwcomp", @"[ItemFlow] createTextureFromImage: no pixel data available for image size=%@", NSStringFromSize([image size]));
    }

    NSDebugLLog(@"gwcomp", @"[ItemFlow] createTextureFromImage: created texID=%u", (unsigned)texID);
    return texID;
}

- (void)reloadData {
    [[self openGLContext] makeCurrentContext];
    for (NSNumber *texNum in _textures) {
        GLuint t = [texNum unsignedIntValue];
        if (t != 0) glDeleteTextures(1, &t);
    }
    [_textures removeAllObjects];
    
    if (dataSource) {
        NSUInteger count = [dataSource numberOfItemsInItemFlowView:self];
        NSDebugLLog(@"gwcomp", @"[ItemFlow] reloadData: count=%tu (fast path)", count);
        for (NSUInteger i = 0; i < count; i++) {
            [_textures addObject:@(0)];
        }
    }
    
    [self updateScrollFrame];
    
    // Reset positions? Only if out of bounds
    if (_textures.count > 0 && _targetPosition >= _textures.count) {
        _targetPosition = (CGFloat)(_textures.count - 1);
        _currentPosition = _targetPosition;
    } else if (_textures.count == 0) {
        _targetPosition = 0;
        _currentPosition = 0;
    }
    
    [self setNeedsDisplay:YES];
}

- (void)updateTexturesForIndices:(NSIndexSet *)indices {
    if (!indices || indices.count == 0) return;

    [[self openGLContext] makeCurrentContext];

    NSUInteger itemCount = _textures.count;
    if (itemCount == 0 && dataSource) {
        itemCount = [dataSource numberOfItemsInItemFlowView:self];
        while (_textures.count < itemCount) [_textures addObject:@(0)];
    }

    __block int uploadsThisTick = 0;
    static NSTimeInterval lastTick = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - lastTick > 0.15) {
        uploadsThisTick = 0;
        lastTick = now;
    }

    NSMutableIndexSet *pendingIndices = [NSMutableIndexSet indexSet];

    [indices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx >= _textures.count) return;

        NSImage *img = [dataSource itemFlowView:self imageAtIndex:idx];
        if (!img) {
            // No image available yet from data source
            return;
        }

        // Check if we already have a texture here that is NOT the placeholder
        GLuint currentTex = [_textures[idx] unsignedIntValue];
        if (currentTex != 0) {
            // We already have a real texture (presumably). 
            // In a more complex app we'd check if it changed, but for now skip.
            return;
        }

        if (uploadsThisTick >= 2) {
            [pendingIndices addIndex:idx];
            return;
        }

        GLuint t = [self createTextureFromImage:img];
        if (t != 0) {
            _textures[idx] = @(t);
            uploadsThisTick++;
            NSDebugLLog(@"gwcomp", @"[ItemFlow] updateTexturesForIndices: assigned texture=%u for index=%tu", (unsigned)t, idx);
        }
    }];

    if (pendingIndices.count > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            [self updateTexturesForIndices:pendingIndices];
        });
    }

    [self setNeedsDisplay:YES];
}

#pragma mark - Inputs

- (void)keyDown:(NSEvent *)event {
    NSString *chars = [event charactersIgnoringModifiers];
    if ([chars length] > 0) {
        unichar c = [chars characterAtIndex:0];
        if (c == NSLeftArrowFunctionKey) {
             [self moveSelectionBy:-1];
             return;
        } else if (c == NSRightArrowFunctionKey) {
             [self moveSelectionBy:1];
             return;
        }
    }
    [super keyDown:event];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    CGFloat width = NSWidth(self.bounds);
    
    if (p.x < width * 0.35) {
        [self moveSelectionBy:-1];
    } else if (p.x > width * 0.65) {
        [self moveSelectionBy:1];
    }
}

- (void)scrollWheel:(NSEvent *)event {
    CGFloat delta = [event deltaY];
    if (delta == 0) delta = [event deltaX];
    
    // Threshold to prevent over-sensitive scrolling
    if (fabs(delta) > 0.5) {
        if (delta > 0) [self moveSelectionBy:-1];
        else [self moveSelectionBy:1];
    }
}

- (void)moveSelectionBy:(NSInteger)delta {
    NSInteger newIndex = (NSInteger)round(_targetPosition) + delta;
    if (newIndex < 0) newIndex = 0;
    if (_textures.count > 0 && newIndex >= (NSInteger)_textures.count) newIndex = _textures.count - 1;
    
    [self setSelectedIndex:newIndex];
}

// Make sure we accept key events
- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)setItemCount:(NSUInteger)count {
    [[self openGLContext] makeCurrentContext];

    NSUInteger oldCount = [_textures count];
    if (count == oldCount) return;

    if (count > oldCount) {
        // Append placeholder entries - existing textures are untouched
        for (NSUInteger i = oldCount; i < count; i++) {
            [_textures addObject:@(0)];
        }
    } else {
        // Remove trailing entries, freeing their GL textures
        for (NSUInteger i = count; i < oldCount; i++) {
            GLuint t = [_textures[i] unsignedIntValue];
            if (t != 0) glDeleteTextures(1, &t);
        }
        [_textures removeObjectsInRange:NSMakeRange(count, oldCount - count)];
    }

    [self updateScrollFrame];

    if (_textures.count > 0 && _targetPosition >= _textures.count) {
        _targetPosition = (CGFloat)(_textures.count - 1);
        _currentPosition = _targetPosition;
    } else if (_textures.count == 0) {
        _targetPosition = 0;
        _currentPosition = 0;
    }

    [self setNeedsDisplay:YES];
}

@end
