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
`{ GSScaleFactor = <real>; GSScaleFactorSource = recommended | user; }`, owner
root, mode 0644 (libs-base ignores files that group or others can write).

- `recommended`: LoginWindow wrote it. It recomputes the scale from the primary
  output on every start and rewrites the file (also when it is absent or does
  not parse), so a first boot in a VM or on a projector does not pin the scale.
  With several monitors only the primary one counts; there is one scale for the
  whole desktop.
- `user`: the Display pane writes it through the privileged helper when the
  user picks a scale. LoginWindow never touches it. A file with a scale and no
  source is treated the same way.

The write goes through a temporary file and a rename. If the directory is
read-only, LoginWindow logs it and still uses the recommended scale itself.
