/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef x11_capture_h
#define x11_capture_h

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int x, y, width, height;
} CaptureRect;

typedef enum {
    CaptureStatusOK = 0,
    CaptureStatusCancelled,
    /* Space was pressed during an area selection before a drag started;
     * the user wants to pick a window on the same snapshot instead. */
    CaptureStatusWindowRequested,
    CaptureStatusNoDisplay,
    CaptureStatusReadFailed
} CaptureStatus;

/* A window picked by the user.  shape_window is the X window whose
 * bounding shape describes the visible outline of rect; decorated is set
 * when rect is a window manager frame rather than the bare client, and
 * title_rect is then the frame's title bar (root coordinates). */
typedef struct {
    CaptureRect rect;
    unsigned long shape_window;
    int decorated;
    CaptureRect title_rect;
} WindowSelection;

/* Opens the X connection used for grabs and reads; idempotent. */
int x11_init(void);
void x11_cleanup(void);

/* The whole screen frozen at one moment; selections are made on it and
 * captures are cut from it, so a delayed capture shows what was on screen
 * when the delay ran out. */
typedef struct CaptureSnapshot CaptureSnapshot;

CaptureStatus x11_snapshot_take(CaptureSnapshot **snapshot);
void x11_snapshot_free(CaptureSnapshot *snapshot);

/* Interactive selection on the snapshot shown full screen.  Both block
 * until the user clicks/drags (left button) or cancels (Escape or right
 * button).  The area selection also returns when Space is pressed before
 * dragging (CaptureStatusWindowRequested).  The snapshot stays on screen
 * between selections until it is freed. */
CaptureStatus x11_select_window(CaptureSnapshot *snapshot, int include_frame,
                                WindowSelection *selection);
CaptureStatus x11_select_area(CaptureSnapshot *snapshot, CaptureRect *rect);

/* Captures return a malloc'd buffer of *width x *height non-premultiplied
 * RGBA pixels, or NULL.  Free with free(). */
unsigned char *x11_capture_screen(const CaptureSnapshot *snapshot,
                                  int *width, int *height);
unsigned char *x11_capture_area(const CaptureSnapshot *snapshot,
                                CaptureRect rect, int *width, int *height);
/* Window pixels outside the window outline become transparent (or the drop
 * shadow when include_shadow is set); corners are rounded with the radii. */
unsigned char *x11_capture_window(const CaptureSnapshot *snapshot,
                                  const WindowSelection *selection,
                                  int include_shadow,
                                  float top_corner_radius,
                                  float bottom_corner_radius,
                                  int *width, int *height);

#ifdef __cplusplus
}
#endif

#endif /* x11_capture_h */
