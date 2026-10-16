# Gershwin Components Metapackage

This is a metapackage that installs all Gershwin Desktop Environment components.

## What it includes:

- **Preference Panes**: BootEnvironments, Display, GlobalShortcuts, StartupDisk
- **System Tools**: LoginWindow, SudoAskPass, initgfx, Menu, fontconfig
- **Assistant Framework**: Base framework for assistant applications
- **Assistant Applications**: BhyveAssistant, CreateLiveMediaAssistant, DebianRuntimeInstaller

## Installation:

Installing this metapackage will automatically install all individual Gershwin components:

```
pkg install gershwin-components
```

This metapackage has no files of its own - it simply depends on all the individual component packages.
