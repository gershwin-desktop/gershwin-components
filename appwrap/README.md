# appwrap

`appwrap` is a CLI tool that creates GNUstep application bundles from freedesktop `.desktop` files. This allows you to wrap any desktop application into a GNUstep app bundle that can be launched from the system.

## Usage

```bash
appwrap [OPTIONS] /path/to/application.desktop [output_directory]
appwrap [OPTIONS] -c|--command "command to run" [-i|--icon /path/to/icon.png] [output_directory]
```

### Arguments

- `/path/to/application.desktop` - Path to a freedesktop .desktop file (default mode)
- `-c, --command "command"` - Provide a command line to execute instead of a .desktop file
- `-i, --icon /path/to/icon` - (Optional) Explicit path to an icon file to use for the bundle
- `[output_directory]` - (Optional) Directory where the app bundle will be created. 
  - If not specified for non-root users: `~/Applications` (created if it doesn't exist)
  - If not specified for root: `/Local/Applications` (created if it doesn't exist)

### Options

- `-f, --force` - Overwrite existing app bundle without asking for confirmation
- `-c, --command` - Provide a command line to execute instead of a .desktop file (accepts additional unquoted args)
- `-i, --icon` - Use the specified icon file (overrides desktop Icon lookup)
- `-N, --name` - Explicit application name to use for the bundle (overrides auto-derivation)
- `-a, --append-arg ARG` - Append an argument to the command (can be used multiple times)
- `-p, --prepend-arg ARG` - Prepend an argument to the command (can be used multiple times)
- `-h, --help` - Show this help message

Note: If your command contains tokens that look like appwrap options (for example `-N` or `-i`), either quote the full `--command` value or use `--` to stop option parsing. Example:

```bash
# Using -- to stop option parsing and pass -n to the command
appwrap --command /bin/echo -- -n hello /tmp

# Or quote the full command
appwrap --command "/bin/echo -n hello" /tmp

# Examples using append/prepend args to build a VS Code launcher that forces --no-sandbox
appwrap -c /home/user/VSCode-linux-x64/bin/code -a --no-sandbox -N "Visual Studio Code"
# Or with prepend (rare):
appwrap -c /usr/bin/env -p "DISPLAY=:0" -a --someflag -N "My Env App"
```
## Examples

Create a Chromium app bundle in the default location (~Applications as non-root):
```bash
appwrap /usr/share/applications/chromium.desktop
```

Create a Firefox app bundle in a custom directory:
```bash
appwrap /usr/share/applications/firefox.desktop /opt/applications
```

Create a bundle that runs an arbitrary command, using a specific icon:
```bash
appwrap --command "/usr/bin/firefox --new-window" --icon /usr/share/icons/hicolor/256x256/apps/firefox.png
```

Overwrite an existing app bundle without confirmation:
```bash
appwrap -f /usr/share/applications/chromium.desktop
appwrap --force /home/user/Applications/myapp.app
```

### Overwrite Behavior

- If an app bundle already exists at the destination, `appwrap` will prompt you for confirmation
- You can bypass this prompt by using the `-f` or `--force` flag
- When overwriting, the entire existing bundle is deleted and replaced with a fresh one

## What It Does

`appwrap` parses a freedesktop `.desktop` file and creates a GNUstep application bundle with the following structure:

```
ApplicationName.app/
├── ApplicationName           (launcher script)
└── Resources/
    ├── Info.plist           (GNUstep metadata)
    └── [AppName].[ext]      (icon file, if found)
```

### Features

- **Parses .desktop files** - Extracts Name, Exec, Icon, Version and StartupWMClass information
- **Window class** - StartupWMClass becomes `GSX11WindowClass` in Info.plist, which Workspace and the Dock use to find the program's windows
- **Creates proper GNUstep bundles** - Generates valid Info.plist and executable structure
- **Icon support** - Automatically searches for and copies application icons from standard locations
- **Launcher script** - Creates a shell wrapper that executes the original application command
- **Works with any app** - Compatible with any application that has a .desktop file

## Building

```bash
cd appwrap
gmake
```

The compiled binary will be available at `obj/appwrap`.

### Installation

To install appwrap system-wide:

```bash
cd appwrap
sudo -E gmake install
```

The tool will be installed to `/Local/Library/Tools/appwrap`. Make sure this directory is in your PATH, or you can use the full path to invoke it.

## Icon Resolution

`appwrap` searches for application icons in the following locations:

- `/usr/share/icons/hicolor/256x256/apps`
- `/usr/local/share/icons/hicolor/256x256/apps`
- `$HOME/.local/share/icons/hicolor/256x256/apps`
- `/usr/share/icons/hicolor/128x128/apps`
- `/usr/local/share/icons/hicolor/128x128/apps`
- `$HOME/.local/share/icons/hicolor/128x128/apps`
- `/usr/share/icons/hicolor/96x96/apps`
- `/usr/local/share/icons/hicolor/96x96/apps`
- `$HOME/.local/share/icons/hicolor/96x96/apps`
- `/usr/share/icons/hicolor/64x64/apps`
- `/usr/local/share/icons/hicolor/64x64/apps`
- `$HOME/.local/share/icons/hicolor/64x64/apps`
- `/usr/share/icons/hicolor/48x48/apps`
- `/usr/local/share/icons/hicolor/48x48/apps`
- `$HOME/.local/share/icons/hicolor/48x48/apps`
- `/usr/share/pixmaps`
- `/usr/local/share/pixmaps`
- `$HOME/.local/share/pixmaps`

Supported icon formats: `.png`, `.svg`, `.xpm`, or no extension.

If an icon cannot be found, the bundle is created without an icon and a warning is displayed.