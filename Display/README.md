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
- Per-display "looks like" sizes (scaled resolutions)

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

### Looks Like (scaled resolutions)

Applications render at one scale factor (the Scale Factor slider). The "Looks Like" list offers, for the selected display, the sizes it can look like at that factor: the default runs the display's mode as it is, every other entry renders a larger or smaller picture and lets the X server scale it onto the panel with a RandR transform (bilinear). A 3840x2160 panel at scale factor 2 normally looks like 1920x1080; "2560x1440" gives it a 5120x2880 picture, and a 1920x1080 monitor next to it can look like 1920x1080 again with a 3840x2160 picture. The choice is saved with the arrangement and restored by `displayconfig apply`; it is reset to the default when the resolution changes. Drivers without transforms (the Xorg dummy driver, Xephyr) refuse it with a message. Scaled pictures are slightly softer, cost more memory, and must fit into the largest screen the X server allows; sizes that do not are not offered.

### Mirror Displays

Check the "Mirror Displays" checkbox to mirror the primary display to all other connected displays.

## Technical Details

- `DisplayLayout.{h,m}` is the layout model (outputs with EDID identity, mode, position, primary, transform, mirror, scale factor). It is Foundation only and has a property list form, so a per-user display configuration can store and apply it.
- `DisplayArrangement.{h,m}` holds the pure decisions: mode selection from an output's own modes, arrangement without overlaps or gaps, the view mapping, screen size planning (grow first, shrink last), CRTC assignment and the scale factor range.
- `DisplayScaledResolution.{h,m}` computes the "looks like" sizes: framebuffer sizes rounded to even numbers, the per-axis transform that makes the server's 16.16 bounds exactly that size, and which size a transform read back from the server stands for.
- `DisplaySystemDefaults.{h,m}` reads and writes the system-wide scale (`GlobalDefaults/Display.plist`) for `displayconfig` and LoginWindow; `DisplayScaleHeuristic.{h,m}` recommends a scale from the panel's physical size.
- `X11DisplayManager.{h,m}` reads the RandR state into the model and applies a model to the server.

## Tests

- `Tests/Unit`: headless ObjectTesting tools (`gmake -j1`, then run `./obj/t_*`).
- `Tests/Live/display-live looks-like OUTPUT [WxH] -GSScaleFactor F` lists and applies "looks like" sizes. Transforms need a driver that has them: the Xorg dummy driver and Xephyr refuse them, the modesetting driver on a two-head virtio-gpu in a QEMU guest does.
- `Tests/live-multihead.sh`: live checks against the Xorg dummy driver, which provides several RandR outputs (see the script header for the recipe).
