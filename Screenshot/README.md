# Screenshot

Screenshot.app is a production-ready GNUstep application for taking screenshots. It allows you to:
- Click on a window to capture that window
- Select an area with the mouse to capture that region (press Space to pick a window instead)
- Capture the full screen

The application provides both a GUI interface and command-line operation.

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