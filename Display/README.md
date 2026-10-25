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

### Mirror Displays

Check the "Mirror Displays" checkbox to mirror the primary display to all other connected displays.

## Technical Details

- `DisplayLayout.{h,m}` is the layout model (outputs with EDID identity, mode, position, primary, transform, mirror, scale factor). It is Foundation only and has a property list form, so a per-user display configuration can store and apply it.
- `DisplayArrangement.{h,m}` holds the pure decisions: mode selection from an output's own modes, arrangement without overlaps or gaps, the view mapping, screen size planning (grow first, shrink last), CRTC assignment and the scale factor range.
- `X11DisplayManager.{h,m}` reads the RandR state into the model and applies a model to the server.

## Tests

- `Tests/Unit`: headless ObjectTesting tools (`gmake -j1`, then run `./obj/t_*`).
- `Tests/live-multihead.sh`: live checks against the Xorg dummy driver, which provides several RandR outputs (see the script header for the recipe).
