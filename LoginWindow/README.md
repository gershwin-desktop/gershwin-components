# LoginWindow

A simple, minimalist login manager for GNUstep-based desktop environments.

## Installation

1. Build the application with `gmake`
2. Install with `gmake install`
3. Add the following line to `/etc/rc.conf` to enable LoginWindow:
   ```
   loginwindow_enable="YES"
   ```
4. Disable other display managers (gdm, lightdm, etc.) in `/etc/rc.conf`


## Enabling

Create the local preferences directory if it doesn't exist

```
sudo -A -E mkdir -p /Local/Library/Preferences
```

Create or update `/Local/Library/Preferences/LoginWindow.plist` with the auto-login user (replace `User`)

```
{
    autoLoginUser = User;
    lastLoggedInUser = User;
    lastSession = "/System/Library/Scripts/Gershwin.sh";
}'
```

To disable autologin, remove the key or the file.

## Chinese, Japanese and Korean fonts

When a session starts with a Chinese, Japanese or Korean locale (chosen in the
language menu or detected from the keyboard) and fontconfig has no font for it,
LoginWindow downloads the matching Sarasa Gothic font (SIL OFL 1.1) in the
background with `LoginWindow --install-cjk-font <locale>`: about 50 MB from
GitHub, checked against a pinned sha256 digest, of which only Regular and Bold
(about 26 MB) are unpacked into `/System/Library/Fonts/Sarasa`, together with
the license. Unpacking needs `bsdtar` from libarchive (package
`libarchive-tools` on Debian and Devuan) and about 192 MB of free memory.
OpenBSD is not supported. Without network the download fails with a `FATAL:`
line in the log and CJK text shows as boxes; on a Live system the font is
fetched again after every reboot.

## Logs

Logs are written to `/var/log/LoginWindow.log` if invoked from the rc script.

## Display scale

Before the first NSApplication call, LoginWindow asks RandR for the primary
output (or the first connected one) and registers the scale that
`GSDisplayScaleHeuristic` recommends for its pixel and millimeter size as
`GSScaleFactor`. Nothing is registered when a `GSScaleFactor` is configured
anywhere (user defaults or the system-wide file below).

The system-wide copy is a property list that every GNUstep process reads on its
own, because libs-base merges each plist in `GlobalDefaults` beside the system
`GNUstep.conf` (`/System/Library/Preferences/GlobalDefaults/Display.plist`)
into the config domain, which ranks below a user's own defaults. Format:
`{ GSScaleFactor = <real>; }`, owner root, mode 0644 (libs-base ignores files
that group or others can write). When no scale is configured, LoginWindow writes
this file once with the recommended value, so a new user's first session starts
with the same scale; it logs and goes on when the directory is read-only.
