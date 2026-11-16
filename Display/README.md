# Display Preference Pane

<img width="602" height="424" alt="image" src="https://github.com/user-attachments/assets/f9115f62-8ae3-43d3-9e90-972df5ee00cf" />

A GNUstep preference pane for managing display configuration through the X RandR extension.

> [!NOTE]
> Since the developer has no access to a multiple display setup, multiple display support might still need to be worked on. Contributions are welcome.

## Features

- Visual display arrangement with drag-and-drop support
- Primary display selection (menu bar location)
- Display resolution selection
- Mirror displays functionality (a common resolution, or a scaled picture when there is none)
- Switching a newly connected display on and off
- Per-display scale (100% to 300%), applied at once

## Requirements

- GNUstep development libraries
- libXrandr

## Building

```sh
gmake clean
gmake
sudo gmake install
```

The preference pane will be installed to `/System/Library/Bundles/Display.prefPane`.

## Usage

### Rearranging Displays

Drag the blue display rectangles in the arrangement view to change their relative positions, side by side or above each other. On drop the displays are snapped together so that their edges touch without overlapping.

### Setting Primary Display

Drag the white menu bar from one display to another to change which display is primary. The primary display is where the desktop environment's menu bar and main desktop appear.

### Resolution Changes

Use the Resolution popup to change the resolution of the currently selected display. A connected display that is off is drawn gray; choosing a resolution switches it on, "Off" switches a display off. Changes that alter resolutions ask for confirmation and are reverted after 15 seconds otherwise.

### Scale

The Scale pop-up sets how large the selected display draws everything. With one display it sets the global scale factor (GSScaleFactor), which applications pick up when they start. With several displays each one can have its own scale: the pane publishes it as the RandR output property `DPI` (96 per 100%) on every lit display, and running applications redraw at once when they move between displays or the scale changes. When all displays have the same scale, applications use the global factor instead, so the pane makes it that scale (running applications pick a changed global factor up when restarted); when they differ, the global factor is the primary display's scale, which fonts, the window manager and single-scale applications fall back to. The scales are saved with the arrangement and restored by `displayconfig apply`. Picking a scale resets a "looks like" RandR transform of that display (from earlier versions), since it would scale the display a second time; transforms saved without a scale are still applied.

### Mirror Displays

Check the "Mirror Displays" checkbox to mirror the primary display to all other connected displays.

## Technical Details

- `DisplayLayout.{h,m}` is the layout model (outputs with EDID identity, mode, position, primary, transform, mirror, scale factor). It is Foundation only and has a property list form, so a per-user display configuration can store and apply it.
- `DisplayArrangement.{h,m}` holds the pure decisions: mode selection from an output's own modes, arrangement without overlaps or gaps, the view mapping, screen size planning (grow first, shrink last), CRTC assignment and the scale factor range.
- `DisplayScaledResolution.{h,m}` computes "looks like" sizes (RandR transforms; no longer offered in the pane): framebuffer sizes rounded to even numbers, the per-axis transform that makes the server's 16.16 bounds exactly that size, and which size a transform read back from the server stands for.
- `DisplaySystemDefaults.{h,m}` reads and writes the system-wide scale (`GlobalDefaults/Display.plist`) for `displayconfig` and LoginWindow; `DisplayScaleHeuristic.{h,m}` recommends a scale from the panel's physical size.
- `X11DisplayManager.{h,m}` reads the RandR state, including each output's `DPI`, into the model and applies a model to the server; a `DPI` is only written where it differs, so an unchanged layout causes no events.

## Tests

- `Tests/Unit`: headless ObjectTesting tools (`gmake -j1`, then run `./obj/t_*`).
- `Tests/Live/display-live looks-like OUTPUT [WxH] -GSScaleFactor F` lists and applies "looks like" sizes. Transforms need a driver that has them: the Xorg dummy driver and Xephyr refuse them, the modesetting driver on a two-head virtio-gpu in a QEMU guest does.
- `Tests/Live/display-live scale OUTPUT S -GSScaleFactor F` sets a display's scale like the pane does.
- `Tests/live-multihead.sh`: live checks against the Xorg dummy driver, which provides several RandR outputs (see the script header for the recipe).
