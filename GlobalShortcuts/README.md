# GlobalShortcuts Preference Pane

A GNUstep preference pane for configuring global keyboard shortcuts, which Workspace carries out.

## Features

- View all configured global shortcuts
- Add new keyboard shortcuts with commands
- Edit existing shortcuts
- Delete shortcuts
- Automatic configuration management via GlobalShortcuts
- Workspace reloads the shortcuts as soon as they change

## Building

```sh
gmake
```

## Installing

```sh
sudo gmake install
```

This installs the preference pane to `/System/Library/Bundles/GlobalShortcuts.prefPane`.

## Testing

After building and installing, run SystemPreferences:

```sh
/System/Applications/SystemPreferences.app/SystemPreferences
```

The "Global Shortcuts" pane should appear in the preferences window.

## Usage

1. **Adding Shortcuts**: Click the "Add" button to create a new keyboard shortcut. Enter the key combination (e.g., "ctrl+shift+t") and the command to execute (e.g., "xterm").

2. **Editing Shortcuts**: Select a shortcut from the list and click "Edit" to modify the key combination or command.

3. **Deleting Shortcuts**: Select a shortcut and click "Delete" to remove it.

4. **Key Combination Format**: Use this format:
   - Modifiers: `ctrl`, `shift`, `alt`, `cmd`, `mod1-mod5`
   - Keys: `a-z`, `0-9`, `f1-f24`, `space`, `return`, `tab`, etc.
   - Multimedia keys: `volume_up`, `volume_down`, `volume_mute`, etc.
   - Examples: `ctrl+shift+t`, `alt+f2`, `volume_up`

5. **Configuration Storage**: All shortcuts are saved to GlobalShortcuts and applied automatically.

6. **Workspace Integration**: The preference pane posts a distributed notification when shortcuts change, and Workspace reloads them.

## Requirements

- GNUstep development environment
- PreferencePanes framework
- Workspace (carries out the shortcuts)

## Configuration Storage

The preference pane manages shortcuts via the GlobalShortcuts domain. The format is a dictionary where keys are the key combinations and values are the commands:

```
GlobalShortcuts = {
    "ctrl+shift+t" = "Terminal";
    "volume_up" = "amixer set Master 5%+";
}
```

You can also set shortcuts manually using the defaults command:

```sh
# Set individual shortcuts
defaults write GlobalShortcuts ctrl+shift+t Terminal
```

Changes made through the preference pane are immediately written to GlobalShortcuts and Workspace is notified to reload them.