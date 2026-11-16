# Screenshot

Screenshot.app is a production-ready GNUstep application for taking screenshots. It allows you to:
- Click on a window to capture that window
- Select an area with the mouse to capture that region (press Space to pick a window instead)
- Capture the full screen
- Record an area of the screen as an animated GIF or APNG, or as a WebM or MP4 video

The application provides both a GUI interface and command-line operation.

## Recording the screen

"Record Area..." shows a frame on the screen. Move it by the bar underneath it
and resize it by its edges and corners, choose the format in the bar, and
press Record (or Return). The frame turns red while recording; Stop ends the
recording, which is then saved where you choose. Cancel (or Escape) closes the
frame. The delay set in the main window counts down before recording starts.

The frame and its bar lie outside the recorded area, so they are never part of
the recording. Preferences set the frame rate (10 to 60 frames per second),
the size (full, half or a third), whether the pointer is shown, and whether
sound is recorded (WebM and MP4 only: ALSA on Linux, OSS on FreeBSD, sndio on
OpenBSD).

Recording needs `ffmpeg` with X11 screen capture. GIF and APNG are recorded
losslessly first and then converted, with a palette made from the whole
recording.

## Usage

### GUI Mode

Launch the application without arguments to show the graphical interface.

### Command Line Mode

```bash
Screenshot.app/Screenshot [options] [output-file]
```

Options:
- `-h, --help`           Show help message
- `-a, --area`           Select an area to screenshot (interactive - click and drag; Space switches to picking a window)
- `-w, --window`         Select a window to screenshot (interactive - click on a window)
- `-s, --screen`         Capture the whole screen where the cursor is
- `-d, --delay SEC`      Wait SEC seconds before taking the screenshot
- `-o, --output FILE`    Save screenshot to FILE

Examples:
```bash
# Full screen screenshot (default)
Screenshot.app/Screenshot screenshot.png

# Window selection - you'll be prompted to click on a window
Screenshot.app/Screenshot -w window.png

# Interactive area selection - click and drag to select the area
Screenshot.app/Screenshot -a area.png
# or
Screenshot.app/Screenshot --area area.png

# Capture the screen where the cursor is
Screenshot.app/Screenshot -s screen.png

# Full screen with 5 second delay
Screenshot.app/Screenshot -d 5 delayed.png
```