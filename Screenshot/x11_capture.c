/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/select.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/keysym.h>
#include <X11/cursorfont.h>
#include <X11/extensions/shape.h>

#include "x11_capture.h"
#include "shadow_mask.h"

/* Right after the click that started a capture, the toolkit or the window
 * manager can still hold a grab for a moment, so grabs are retried for up to
 * GRAB_ATTEMPTS * GRAB_RETRY_USEC before giving up. */
#define GRAB_ATTEMPTS 20
#define GRAB_RETRY_USEC 50000

static Display *disp = NULL;
static Window root = None;
static int screen_number = 0;

static int x11_error_occurred = 0;
static int (*previous_error_handler)(Display *, XErrorEvent *) = NULL;

static int error_handler(Display *display, XErrorEvent *error)
{
    char text[256];
    XGetErrorText(display, error->error_code, text, sizeof(text));
    fprintf(stderr, "Screenshot: X11 error: %s (request %d)\n",
            text, error->request_code);
    x11_error_occurred = 1;
    return 0;
}

/* The Xlib error handler is process-wide and libs-back relies on its own,
 * so ours is installed only around our own requests. */
static void trap_errors(void)
{
    XSync(disp, False);
    x11_error_occurred = 0;
    previous_error_handler = XSetErrorHandler(error_handler);
}

static int untrap_errors(void)
{
    XSync(disp, False);
    XSetErrorHandler(previous_error_handler);
    return x11_error_occurred;
}

int x11_init(void)
{
    if (disp)
        return 1;
    disp = XOpenDisplay(NULL);
    if (!disp)
        return 0;
    screen_number = DefaultScreen(disp);
    root = RootWindow(disp, screen_number);
    return 1;
}

void x11_cleanup(void)
{
    if (disp) {
        XCloseDisplay(disp);
        disp = NULL;
    }
}

/* Input grabs */

static int grab_input(unsigned int event_mask, Cursor cursor)
{
    int status = GrabNotViewable;
    for (int i = 0; i < GRAB_ATTEMPTS; i++) {
        status = XGrabPointer(disp, root, False, event_mask,
                              GrabModeAsync, GrabModeAsync,
                              root, cursor, CurrentTime);
        if (status == GrabSuccess)
            break;
        usleep(GRAB_RETRY_USEC);
    }
    if (status != GrabSuccess) {
        fprintf(stderr, "Screenshot: pointer grab failed (%d)\n", status);
        return 0;
    }

    /* Without the keyboard grab Escape would reach the focused application
     * instead of cancelling the selection. */
    for (int i = 0; i < GRAB_ATTEMPTS; i++) {
        status = XGrabKeyboard(disp, root, False, GrabModeAsync,
                               GrabModeAsync, CurrentTime);
        if (status == GrabSuccess)
            return 1;
        usleep(GRAB_RETRY_USEC);
    }
    fprintf(stderr, "Screenshot: keyboard grab failed (%d)\n", status);
    XUngrabPointer(disp, CurrentTime);
    XFlush(disp);
    return 0;
}

static void ungrab_input(void)
{
    XUngrabKeyboard(disp, CurrentTime);
    XUngrabPointer(disp, CurrentTime);
    XSync(disp, False);
}

static void wait_for_event(XEvent *event)
{
    int fd = ConnectionNumber(disp);
    while (!XPending(disp)) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(fd, &fds);
        select(fd + 1, &fds, NULL, NULL, NULL);
    }
    XNextEvent(disp, event);
}

static int is_escape(XEvent *event)
{
    return event->type == KeyPress
        && XLookupKeysym(&event->xkey, 0) == XK_Escape;
}

/* Window lookup */

static int has_wm_state(Window window)
{
    Atom wm_state = XInternAtom(disp, "WM_STATE", False);
    Atom type = None;
    int format;
    unsigned long nitems, bytes_after;
    unsigned char *data = NULL;

    XGetWindowProperty(disp, window, wm_state, 0, 0, False, AnyPropertyType,
                       &type, &format, &nitems, &bytes_after, &data);
    if (data)
        XFree(data);
    return type != None;
}

/* The client is the window carrying WM_STATE (ICCCM); a reparenting window
 * manager puts it somewhere below the top-level frame. */
static Window find_client_below(Window window)
{
    Window root_return, parent_return, *children = NULL;
    unsigned int count = 0;
    Window client = None;

    if (!XQueryTree(disp, window, &root_return, &parent_return,
                    &children, &count))
        return None;
    for (unsigned int i = 0; i < count && client == None; i++) {
        if (has_wm_state(children[i]))
            client = children[i];
    }
    for (unsigned int i = 0; i < count && client == None; i++)
        client = find_client_below(children[i]);
    if (children)
        XFree(children);
    return client;
}

/* The title bar is the widest child along the top edge of the frame; it
 * can be wider than the frame itself, which shifts its rounded corners. */
static CaptureRect find_title_bar(Window frame, Window client)
{
    CaptureRect title = { 0, 0, 0, 0 };
    Window root_return, parent_return, *children = NULL;
    unsigned int count = 0;

    if (!XQueryTree(disp, frame, &root_return, &parent_return,
                    &children, &count))
        return title;
    for (unsigned int i = 0; i < count; i++) {
        XWindowAttributes attributes;
        if (children[i] == client
            || !XGetWindowAttributes(disp, children[i], &attributes)
            || attributes.map_state != IsViewable || attributes.y > 0
            || attributes.width <= title.width)
            continue;
        title.x = attributes.x;
        title.y = attributes.y;
        title.width = attributes.width;
        title.height = attributes.height;
    }
    if (children)
        XFree(children);
    return title;
}

static int get_root_geometry(Window window, CaptureRect *rect)
{
    XWindowAttributes attributes;
    Window child;
    int x, y;

    if (!XGetWindowAttributes(disp, window, &attributes))
        return 0;
    if (!XTranslateCoordinates(disp, window, root, 0, 0, &x, &y, &child))
        return 0;
    rect->x = x;
    rect->y = y;
    rect->width = attributes.width;
    rect->height = attributes.height;
    return 1;
}

/* Snapshot */

struct CaptureSnapshot {
    XImage *image;
};

CaptureStatus x11_snapshot_take(CaptureSnapshot **snapshot)
{
    if (!x11_init())
        return CaptureStatusNoDisplay;

    Visual *visual = DefaultVisual(disp, screen_number);
    if (visual->class != TrueColor && visual->class != DirectColor) {
        fprintf(stderr, "Screenshot: unsupported visual class %d\n",
                visual->class);
        return CaptureStatusReadFailed;
    }

    trap_errors();
    XImage *image = XGetImage(disp, root, 0, 0,
                              DisplayWidth(disp, screen_number),
                              DisplayHeight(disp, screen_number),
                              AllPlanes, ZPixmap);
    if (untrap_errors() || !image) {
        if (image)
            XDestroyImage(image);
        return CaptureStatusReadFailed;
    }

    *snapshot = malloc(sizeof(CaptureSnapshot));
    if (!*snapshot) {
        XDestroyImage(image);
        return CaptureStatusReadFailed;
    }
    (*snapshot)->image = image;
    return CaptureStatusOK;
}

void x11_snapshot_free(CaptureSnapshot *snapshot)
{
    if (!snapshot)
        return;
    XDestroyImage(snapshot->image);
    free(snapshot);
}

/* Covers the screen with the snapshot so the user selects on exactly the
 * pixels that get saved; menus or tooltips that close once we grab the
 * pointer stay visible and selectable. */
static Window map_frozen_overlay(CaptureSnapshot *snapshot)
{
    XImage *image = snapshot->image;
    Pixmap pixmap = XCreatePixmap(disp, root, image->width, image->height,
                                  DefaultDepth(disp, screen_number));
    GC gc = XCreateGC(disp, pixmap, 0, NULL);
    XPutImage(disp, pixmap, gc, image, 0, 0, 0, 0,
              image->width, image->height);
    XFreeGC(disp, gc);

    XSetWindowAttributes attributes;
    attributes.override_redirect = True;
    attributes.background_pixmap = pixmap;
    attributes.event_mask = ExposureMask;
    Window overlay = XCreateWindow(disp, root, 0, 0,
                                   image->width, image->height, 0,
                                   CopyFromParent, InputOutput, CopyFromParent,
                                   CWOverrideRedirect | CWBackPixmap | CWEventMask,
                                   &attributes);
    /* The window keeps its own reference to the background. */
    XFreePixmap(disp, pixmap);
    XMapRaised(disp, overlay);
    XSync(disp, False);
    return overlay;
}

/* Interactive selection */

/* The topmost visible window under the point, ignoring the overlay that
 * now covers everything and would otherwise always be hit. */
static Window toplevel_at(Window overlay, int x, int y)
{
    Window root_return, parent_return, *children = NULL;
    unsigned int count = 0;
    Window found = root;

    trap_errors();
    if (XQueryTree(disp, root, &root_return, &parent_return,
                   &children, &count)) {
        /* XQueryTree lists children bottom to top. */
        for (unsigned int i = count; i > 0 && found == root; i--) {
            Window child = children[i - 1];
            XWindowAttributes attributes;
            if (child == overlay
                || !XGetWindowAttributes(disp, child, &attributes)
                || attributes.map_state != IsViewable
                || attributes.class != InputOutput)
                continue;
            int extent = 2 * attributes.border_width;
            if (x >= attributes.x && x < attributes.x + attributes.width + extent
                && y >= attributes.y && y < attributes.y + attributes.height + extent)
                found = child;
        }
    }
    if (children)
        XFree(children);
    if (untrap_errors())
        return root;
    return found;
}

CaptureStatus x11_select_window(CaptureSnapshot *snapshot, int include_frame,
                                WindowSelection *selection)
{
    Window overlay = map_frozen_overlay(snapshot);
    Cursor cursor = XCreateFontCursor(disp, XC_crosshair);
    if (!grab_input(ButtonPressMask | ButtonReleaseMask, cursor)) {
        XFreeCursor(disp, cursor);
        XDestroyWindow(disp, overlay);
        XSync(disp, False);
        return CaptureStatusGrabFailed;
    }

    Window toplevel = None;
    unsigned int pressed_button = 0;
    int cancelled = 0;
    XEvent event;

    for (;;) {
        wait_for_event(&event);
        if (is_escape(&event)) {
            cancelled = 1;
            break;
        }
        if (event.type == ButtonPress && pressed_button == 0) {
            pressed_button = event.xbutton.button;
            toplevel = toplevel_at(overlay, event.xbutton.x_root,
                                   event.xbutton.y_root);
        } else if (event.type == ButtonRelease
                   && event.xbutton.button == pressed_button) {
            /* Keep the grab until release so the release does not reach
             * the window under the pointer as a stray click. */
            if (pressed_button == Button1)
                break;
            if (pressed_button == Button3) {
                cancelled = 1;
                break;
            }
            pressed_button = 0;
        }
    }

    XDestroyWindow(disp, overlay);
    ungrab_input();
    XFreeCursor(disp, cursor);
    if (cancelled)
        return CaptureStatusCancelled;
    trap_errors();
    /* Descendants are searched first because some window managers
     * (gershwin-windowmanager among them) also set WM_STATE on the frame. */
    Window client = toplevel;
    if (toplevel != root) {
        Window found = find_client_below(toplevel);
        if (found != None)
            client = found;
    }
    Window target = include_frame ? toplevel : client;
    int ok = get_root_geometry(target, &selection->rect);
    if (untrap_errors() || !ok)
        return CaptureStatusReadFailed;

    selection->shape_window = target;
    selection->decorated = (target != client);
    selection->title_rect = (CaptureRect){ 0, 0, 0, 0 };
    if (selection->decorated) {
        trap_errors();
        CaptureRect title = find_title_bar(target, client);
        if (!untrap_errors() && title.width > 0) {
            title.x += selection->rect.x;
            title.y += selection->rect.y;
            selection->title_rect = title;
        }
    }
    return CaptureStatusOK;
}

/* Erases the previous marquee by letting the server repaint those edges
 * from the overlay's background, which is cheaper and flicker-free compared
 * with redrawing the whole snapshot on every motion event. */
static void clear_marquee(Window overlay, int x, int y, int w, int h)
{
    if (w <= 0 || h <= 0)
        return;
    XClearArea(disp, overlay, x, y, w, 1, False);
    XClearArea(disp, overlay, x, y + h - 1, w, 1, False);
    XClearArea(disp, overlay, x, y, 1, h, False);
    XClearArea(disp, overlay, x + w - 1, y, 1, h, False);
}

static void draw_marquee(Window overlay, GC gc, int x, int y, int w, int h)
{
    if (w <= 0 || h <= 0)
        return;
    /* XDrawRectangle covers w+1 x h+1 pixels. */
    XDrawRectangle(disp, overlay, gc, x, y, w - 1, h - 1);
}

CaptureStatus x11_select_area(CaptureSnapshot *snapshot, CaptureRect *rect)
{
    Window overlay = map_frozen_overlay(snapshot);
    Cursor cursor = XCreateFontCursor(disp, XC_crosshair);
    if (!grab_input(ButtonPressMask | ButtonReleaseMask | PointerMotionMask,
                    cursor)) {
        XFreeCursor(disp, cursor);
        XDestroyWindow(disp, overlay);
        XSync(disp, False);
        return CaptureStatusGrabFailed;
    }

    /* Alternating black and white dashes stay visible on any content,
     * without tinting the area being selected. */
    XGCValues values;
    values.foreground = BlackPixel(disp, screen_number);
    values.background = WhitePixel(disp, screen_number);
    values.line_width = 0;
    values.line_style = LineDoubleDash;
    GC gc = XCreateGC(disp, overlay,
                      GCForeground | GCBackground | GCLineWidth | GCLineStyle,
                      &values);
    char dashes[] = { 4, 4 };
    XSetDashes(disp, gc, 0, dashes, 2);

    int start_x = 0, start_y = 0, end_x = 0, end_y = 0;
    int marquee_x = 0, marquee_y = 0, marquee_w = 0, marquee_h = 0;
    unsigned int pressed_button = 0;
    int cancelled = 0;
    XEvent event;

    for (;;) {
        wait_for_event(&event);
        if (is_escape(&event)) {
            cancelled = 1;
            break;
        }
        if (event.type == Expose && event.xexpose.count == 0) {
            draw_marquee(overlay, gc, marquee_x, marquee_y,
                         marquee_w, marquee_h);
        } else if (event.type == ButtonPress && pressed_button == 0) {
            pressed_button = event.xbutton.button;
            start_x = end_x = event.xbutton.x_root;
            start_y = end_y = event.xbutton.y_root;
        } else if (event.type == MotionNotify && pressed_button == Button1) {
            /* Only the latest pointer position matters. */
            while (XCheckTypedEvent(disp, MotionNotify, &event))
                ;
            end_x = event.xmotion.x_root;
            end_y = event.xmotion.y_root;
            clear_marquee(overlay, marquee_x, marquee_y, marquee_w, marquee_h);
            marquee_x = start_x < end_x ? start_x : end_x;
            marquee_y = start_y < end_y ? start_y : end_y;
            marquee_w = abs(end_x - start_x);
            marquee_h = abs(end_y - start_y);
            draw_marquee(overlay, gc, marquee_x, marquee_y,
                         marquee_w, marquee_h);
            XFlush(disp);
        } else if (event.type == ButtonRelease
                   && event.xbutton.button == pressed_button) {
            if (pressed_button == Button1) {
                end_x = event.xbutton.x_root;
                end_y = event.xbutton.y_root;
                break;
            }
            if (pressed_button == Button3) {
                cancelled = 1;
                break;
            }
            pressed_button = 0;
        }
    }

    XFreeGC(disp, gc);
    XDestroyWindow(disp, overlay);
    ungrab_input();
    XFreeCursor(disp, cursor);

    rect->x = start_x < end_x ? start_x : end_x;
    rect->y = start_y < end_y ? start_y : end_y;
    rect->width = abs(end_x - start_x);
    rect->height = abs(end_y - start_y);

    /* A click without dragging selects nothing, which the user reads as
     * "never mind" rather than as an error. */
    if (cancelled || rect->width == 0 || rect->height == 0)
        return CaptureStatusCancelled;
    return CaptureStatusOK;
}

/* Reading pixels */

typedef struct {
    unsigned long mask;
    int shift;
    unsigned long max;
} Channel;

static void channel_init(Channel *channel, unsigned long mask)
{
    channel->mask = mask;
    channel->shift = 0;
    while (mask && !(mask & 1)) {
        mask >>= 1;
        channel->shift++;
    }
    channel->max = mask;
}

static unsigned char channel_value(const Channel *channel, unsigned long pixel)
{
    unsigned long v = (pixel & channel->mask) >> channel->shift;
    if (channel->max == 255)
        return (unsigned char)v;
    return (unsigned char)((v * 255 + channel->max / 2) / channel->max);
}

static int clip_to_snapshot(const CaptureSnapshot *snapshot, CaptureRect *rect)
{
    int sw = snapshot->image->width;
    int sh = snapshot->image->height;
    int x0 = rect->x < 0 ? 0 : rect->x;
    int y0 = rect->y < 0 ? 0 : rect->y;
    int x1 = rect->x + rect->width > sw ? sw : rect->x + rect->width;
    int y1 = rect->y + rect->height > sh ? sh : rect->y + rect->height;
    if (x1 <= x0 || y1 <= y0)
        return 0;
    rect->x = x0;
    rect->y = y0;
    rect->width = x1 - x0;
    rect->height = y1 - y0;
    return 1;
}

static void convert_image(XImage *image, Visual *visual, CaptureRect rect,
                          unsigned char *out)
{
    if (image->bits_per_pixel == 32 && visual->red_mask == 0xFF0000
        && visual->green_mask == 0xFF00 && visual->blue_mask == 0xFF) {
        /* The common 24/32-bit layout; XGetPixel per pixel is several
         * times slower on large screens. */
        int r = image->byte_order == LSBFirst ? 2 : 1;
        int g = image->byte_order == LSBFirst ? 1 : 2;
        int b = image->byte_order == LSBFirst ? 0 : 3;
        for (int y = 0; y < rect.height; y++) {
            const unsigned char *in = (unsigned char *)image->data
                                    + (size_t)(rect.y + y) * image->bytes_per_line
                                    + (size_t)rect.x * 4;
            for (int x = 0; x < rect.width; x++, in += 4, out += 4) {
                out[0] = in[r];
                out[1] = in[g];
                out[2] = in[b];
                out[3] = 0xFF;
            }
        }
        return;
    }

    Channel red, green, blue;
    channel_init(&red, visual->red_mask);
    channel_init(&green, visual->green_mask);
    channel_init(&blue, visual->blue_mask);
    for (int y = 0; y < rect.height; y++) {
        for (int x = 0; x < rect.width; x++, out += 4) {
            unsigned long pixel = XGetPixel(image, rect.x + x, rect.y + y);
            out[0] = channel_value(&red, pixel);
            out[1] = channel_value(&green, pixel);
            out[2] = channel_value(&blue, pixel);
            out[3] = 0xFF;
        }
    }
}

/* Copies rect (clipped to the snapshot, rect is updated) as opaque RGBA. */
static unsigned char *read_snapshot(const CaptureSnapshot *snapshot,
                                    CaptureRect *rect)
{
    if (!clip_to_snapshot(snapshot, rect))
        return NULL;
    unsigned char *data = malloc((size_t)rect->width * rect->height * 4);
    if (data)
        convert_image(snapshot->image, DefaultVisual(disp, screen_number),
                      *rect, data);
    return data;
}

unsigned char *x11_capture_screen(const CaptureSnapshot *snapshot,
                                  int *width, int *height)
{
    CaptureRect rect = { 0, 0, snapshot->image->width,
                         snapshot->image->height };
    return x11_capture_area(snapshot, rect, width, height);
}

unsigned char *x11_capture_area(const CaptureSnapshot *snapshot,
                                CaptureRect rect, int *width, int *height)
{
    unsigned char *data = read_snapshot(snapshot, &rect);
    if (data) {
        *width = rect.width;
        *height = rect.height;
    }
    return data;
}

/* Window composition */

static void fill_coverage(unsigned char *coverage, int width, int height,
                          int x, int y, int w, int h)
{
    int x0 = x < 0 ? 0 : x;
    int y0 = y < 0 ? 0 : y;
    int x1 = x + w > width ? width : x + w;
    int y1 = y + h > height ? height : y + h;
    for (int row = y0; row < y1; row++)
        memset(coverage + (size_t)row * width + x0, 1, x1 > x0 ? x1 - x0 : 0);
}

/* Clears the corners of a strip the way gershwin-windowmanager does
 * (URSThemeIntegration.m): with cr the radius, a pixel in the left corner
 * square is outside when (x - (cr - 1))^2 + (dy)^2 > cr^2, in the right one
 * when (x - (width - cr))^2 + (dy)^2 > cr^2, dy counted from the row cr
 * away from the rounded edge.  top selects the strip's top or bottom edge. */
static void round_corners(unsigned char *coverage, int width, int height,
                          CaptureRect strip, int radius, int top)
{
    for (int i = 0; i < radius && i < strip.height; i++) {
        int y = top ? strip.y + i : strip.y + strip.height - 1 - i;
        if (y < 0 || y >= height)
            continue;
        int dy = i - radius;
        for (int j = 0; j < radius; j++) {
            int left_dx = j - (radius - 1);
            int right_dx = j;
            int left_x = strip.x + j;
            int right_x = strip.x + strip.width - radius + j;
            if (left_dx * left_dx + dy * dy > radius * radius
                && left_x >= 0 && left_x < width)
                coverage[(size_t)y * width + left_x] = 0;
            if (right_dx * right_dx + dy * dy > radius * radius
                && right_x >= 0 && right_x < width)
                coverage[(size_t)y * width + right_x] = 0;
        }
    }
}

/* Pixels inside the window outline stay opaque; everything else becomes
 * transparent or, with include_shadow, black with the compositor's Gaussian
 * shadow alpha, so rounded-off corners never show desktop remnants. */
static void compose_window(unsigned char *data, CaptureRect captured,
                           const WindowSelection *selection, int include_shadow,
                           float top_radius, float bottom_radius)
{
    int width = captured.width;
    int height = captured.height;
    CaptureRect body = selection->rect;
    int bx = body.x - captured.x;
    int by = body.y - captured.y;

    unsigned char *coverage = calloc((size_t)width * height, 1);
    if (!coverage)
        return;

    int shaped = 0;
    Bool clip_shaped;
    int ix, iy;
    unsigned int iw, ih;
    trap_errors();
    if (XShapeQueryExtents(disp, selection->shape_window, &shaped,
                           &ix, &iy, &iw, &ih, &clip_shaped,
                           &ix, &iy, &iw, &ih) && shaped) {
        int count = 0, ordering;
        XRectangle *rects = XShapeGetRectangles(disp, selection->shape_window,
                                                ShapeBounding, &count,
                                                &ordering);
        for (int i = 0; i < count; i++)
            fill_coverage(coverage, width, height, bx + rects[i].x,
                          by + rects[i].y, rects[i].width, rects[i].height);
        if (rects)
            XFree(rects);
    } else {
        shaped = 0;
    }
    if (untrap_errors())
        shaped = 0;
    if (!shaped)
        fill_coverage(coverage, width, height, bx, by, body.width, body.height);

    /* With a compositor the WM rounds its frames by alpha instead of a
     * shape, so the theme radii are applied here; only frames are rounded,
     * a bare client area is rectangular. */
    if (selection->decorated) {
        CaptureRect frame = { bx, by, body.width, body.height };
        CaptureRect title = frame;
        if (selection->title_rect.width > 0) {
            title = selection->title_rect;
            title.x -= captured.x;
            title.y -= captured.y;
        }
        if ((int)top_radius > 0)
            round_corners(coverage, width, height, title, (int)top_radius, 1);
        if ((int)bottom_radius > 0)
            round_corners(coverage, width, height, frame, (int)bottom_radius, 0);
    }

    int mask_width = 0, mask_height = 0;
    int mask_x = 0, mask_y = 0;
    uint8_t *mask = NULL;
    if (include_shadow) {
        int left, top, right, bottom;
        mask = shadow_make_mask(body.width, body.height,
                                &mask_width, &mask_height);
        shadow_padding(&left, &top, &right, &bottom);
        mask_x = bx - left;
        mask_y = by - top;
    }

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            unsigned char *pixel = data + ((size_t)y * width + x) * 4;
            if (coverage[(size_t)y * width + x])
                continue;
            uint8_t alpha = 0;
            int mx = x - mask_x;
            int my = y - mask_y;
            if (mask && mx >= 0 && mx < mask_width && my >= 0 && my < mask_height)
                alpha = mask[my * mask_width + mx];
            pixel[0] = pixel[1] = pixel[2] = 0;
            pixel[3] = alpha;
        }
    }

    free(mask);
    free(coverage);
}

unsigned char *x11_capture_window(const CaptureSnapshot *snapshot,
                                  const WindowSelection *selection,
                                  int include_shadow,
                                  float top_corner_radius,
                                  float bottom_corner_radius,
                                  int *width, int *height)
{
    CaptureRect rect = selection->rect;
    if (include_shadow) {
        int left, top, right, bottom;
        shadow_padding(&left, &top, &right, &bottom);
        rect.x -= left;
        rect.y -= top;
        rect.width += left + right;
        rect.height += top + bottom;
    }

    unsigned char *data = read_snapshot(snapshot, &rect);
    if (!data)
        return NULL;

    compose_window(data, rect, selection, include_shadow,
                   top_corner_radius, bottom_corner_radius);
    *width = rect.width;
    *height = rect.height;
    return data;
}
