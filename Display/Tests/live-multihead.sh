#!/bin/sh
#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause
#
# Live checks of the Display pane's layout code on an X server with several
# RandR outputs, without real monitors.
#
# Xvfb has a single RandR output, so this uses the Xorg "dummy" video driver
# (Debian/Devuan: xserver-xorg-video-dummy, FreeBSD/OpenBSD: xf86-video-dummy).
# Version 0.4 creates 16 outputs DUMMY0..DUMMY15 with one CRTC each; only
# DUMMY0 is connected at start.  An output becomes "connected" once a mode
# has been set on it, and stays connected after it is switched off again,
# which is exactly a monitor that was plugged in after X started: connected,
# no CRTC.  "plug" below does that.  "unplug" sets the output's non-desktop
# property: the server then reports it as disconnected to every client and
# sends the same output change event as a real unplug, and like on real
# hardware its CRTC keeps running until a client switches it off.  The dummy CRTCs support no RandR
# transforms, so mirroring with a scale transform cannot run here (the unit
# tests cover that plan); mirroring at a common mode does.
#
# Usage (DISPLAYNUM must be a free display you own, never :0):
#   live-multihead.sh start DISPLAYNUM [CONFDIR]   start the dummy Xorg as root
#   live-multihead.sh plug DISPLAYNUM OUTPUT        connect an output, no CRTC
#   live-multihead.sh unplug DISPLAYNUM OUTPUT      disconnect it again
#   live-multihead.sh run DISPLAYNUM                run the checks
#   live-multihead.sh stop DISPLAYNUM               stop the server started here
#
# "run" needs Tests/Live/obj/display-live (gmake in Tests/Live) and starts
# from a fresh server: DUMMY0 alone, DUMMY1 and DUMMY2 plugged.

set -u

here=$(cd "$(dirname "$0")" && pwd)
cmd=${1:-}
num=${2:-}
[ -n "$cmd" ] && [ -n "$num" ] || { sed -n '3,30p' "$0"; exit 2; }
[ "$num" = 0 ] && { echo "refusing to touch display :0" >&2; exit 2; }
DISPLAY=:$num
export DISPLAY

# CI containers run as root and have no sudo; a desktop user needs it.
SUDO=sudo
[ "$(id -u)" = 0 ] && SUDO=

# Debian's /usr/bin/Xorg is a wrapper that wants a console; the server
# binary itself runs without one.
XORG=/usr/lib/xorg/Xorg
[ -x "$XORG" ] || XORG=$(command -v Xorg)

start() {
  if [ -e /tmp/.X11-unix/X$num ] || [ -e /tmp/.X$num-lock ]; then
    echo "display :$num is in use" >&2
    exit 1
  fi
  confdir=${1:-$HOME/.cache/live-multihead}
  mkdir -p "$confdir"
  conf=$confdir/xorg-dummy-$num.conf
  cat > "$conf" <<'EOF'
Section "ServerFlags"
    Option "AutoAddDevices" "false"
    Option "AutoAddGPU" "false"
    Option "DontVTSwitch" "true"
EndSection
Section "Device"
    Identifier "dummy"
    Driver "dummy"
    VideoRam 256000
EndSection
Section "Monitor"
    Identifier "mon"
    HorizSync 5.0-1000.0
    VertRefresh 5.0-200.0
EndSection
Section "Screen"
    Identifier "screen"
    Device "dummy"
    Monitor "mon"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Virtual 8192 4096
    EndSubSection
EndSection
EOF
  chmod a+r "$conf"
  # Root, like the uitest session's Xvfb: an Xorg owned by the slot user
  # would die with the session script's pkill of that user.
  # The log sits next to the config so a caller that owns CONFDIR keeps it
  # (a failed CI start is otherwise undiagnosable).
  $SUDO "$XORG" ":$num" -noreset -nolisten tcp -ac -config "$conf" \
    -logfile "$confdir/xorg-dummy-$num.log" >/dev/null 2>&1 &
  i=0
  while [ $i -lt 50 ] && ! xrandr >/dev/null 2>&1; do sleep 0.2; i=$((i + 1)); done
  xrandr | grep -q '^DUMMY0 connected' || {
    echo "dummy Xorg did not start" >&2
    tail -n 30 "$confdir/xorg-dummy-$num.log" >&2 2>/dev/null
    exit 1
  }
  echo "dummy Xorg on :$num"
}

plug() {
  out=$1
  if xrandr --props | awk -v o="$out" '$1 == o { s = 1; next } /^[^ \t]/ { s = 0 } s && /non-desktop: 1/ { f = 1 } END { exit !f }'; then
    xrandr --output "$out" --set non-desktop 0
    xrandr | grep -q "^$out connected" || { echo "cannot plug $out" >&2; exit 1; }
    return
  fi
  xrandr --addmode "$out" 1024x768 2>/dev/null
  xrandr --output "$out" --mode 1024x768 --right-of DUMMY0 &&
  xrandr --output "$out" --off
  xrandr | grep -q "^$out connected" || { echo "cannot plug $out" >&2; exit 1; }
}

unplug() {
  out=$1
  xrandr --output "$out" --set non-desktop 1
  xrandr | grep -q "^$out disconnected" || { echo "cannot unplug $out" >&2; exit 1; }
}

stop() {
  pid=$(tr -d ' ' < /tmp/.X$num-lock 2>/dev/null)
  if [ -n "$pid" ] && ps -o args= -p "$pid" | grep -q "Xorg :$num "; then
    $SUDO kill "$pid"
  else
    echo "no dummy Xorg of ours on :$num" >&2
    exit 1
  fi
}

tool=$here/Live/obj/display-live
fails=0
passes=0

geom() {   # geometry of an output as xrandr prints it, "" when off
  xrandr | awk -v o="$1" '$1 == o { for (i = 3; i <= NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+/) { print $i; exit } }'
}

check() {  # check DESCRIPTION OUTPUT EXPECTED-GEOMETRY
  got=$(geom "$2")
  if [ "$got" = "$3" ]; then
    passes=$((passes + 1)); echo "PASS: $1 ($2 $got)"
  else
    fails=$((fails + 1)); echo "FAIL: $1 ($2 is '$got', expected '$3')"
  fi
}

check_true() {  # check_true DESCRIPTION COMMAND...
  d=$1; shift
  if "$@"; then passes=$((passes + 1)); echo "PASS: $d"
  else fails=$((fails + 1)); echo "FAIL: $d"; fi
}

step() {
  echo "== display-live $*"
  "$tool" "$@" || { fails=$((fails + 1)); echo "FAIL: display-live $* failed"; }
}

screen_is() { xrandr | grep -q "current $1,"; }
dpi_is() {  # dpi_is OUTPUT VALUE: the output's RandR "DPI" property
  [ "$(xrandr --prop | awk -v o="$1" '$1 == o { s = 1; next } /^[^ \t]/ { s = 0 } s && $1 == "DPI:" { print $2; exit }')" = "$2" ]
}
primary_is() { xrandr | grep -q "^$1 connected primary"; }

run() {
  [ -x "$tool" ] || { echo "build $tool first (gmake in Tests/Live)" >&2; exit 1; }
  check_true "DUMMY1 starts connected" sh -c "xrandr | grep -q '^DUMMY1 connected'"
  check "DUMMY1 starts without CRTC" DUMMY1 ""

  step enable DUMMY1
  check "a newly connected output gets a CRTC at its preferred mode" DUMMY1 2048x1536+2048+0
  check_true "the screen grew to cover it" screen_is "4096 x 1536"

  step mode DUMMY1 1280x1024
  check "smaller resolution" DUMMY1 1280x1024+2048+0
  check_true "the screen shrank" screen_is "3328 x 1536"

  step mode DUMMY0 1024x768
  step mode DUMMY0 2048x1536
  check "a larger mode on the left output" DUMMY0 2048x1536+0+0
  check "the right neighbor moved instead of overlapping" DUMMY1 1280x1024+2048+0

  step enable DUMMY2 1920x1080
  check "a second new output lands right of the arrangement" DUMMY2 1920x1080+3328+0

  step place DUMMY2 above DUMMY0
  check "placed above: on top" DUMMY2 1920x1080+0+0
  check "placed above: the primary below it" DUMMY0 2048x1536+0+1080
  check "placed above: the right output follows the primary" DUMMY1 1280x1024+2048+1080

  step place DUMMY1 left-of DUMMY0
  check "placed left: DUMMY1 at the left edge" DUMMY1 1280x1024+0+1080
  check "placed left: DUMMY0 right of it" DUMMY0 2048x1536+1280+1080

  step primary DUMMY1
  check_true "primary moved to DUMMY1" primary_is DUMMY1

  step mirror
  check "mirror: DUMMY0 at the origin" DUMMY0 2048x1536+0+0
  check "mirror: DUMMY1 same picture" DUMMY1 2048x1536+0+0
  check "mirror: DUMMY2 same picture" DUMMY2 2048x1536+0+0
  check_true "mirror: screen is one picture" screen_is "2048 x 1536"

  step unmirror
  check "unmirror: primary first" DUMMY1 2048x1536+0+0
  check "unmirror: then left to right" DUMMY0 2048x1536+2048+0
  check "unmirror: third output" DUMMY2 2048x1536+4096+0
  check_true "unmirror: primary kept" primary_is DUMMY1

  step off DUMMY2
  check "an output can be switched off" DUMMY2 ""
  check_true "the screen shrank after switching off" screen_is "4096 x 1536"

  # -GSScaleFactor is what the pane would have stored after the step
  # before (display-live prints it), so the user's own factor stays out.
  step scale DUMMY0 2 -GSScaleFactor 1
  check_true "scale: DUMMY0 publishes DPI 192" dpi_is DUMMY0 192
  check_true "scale: DUMMY1 keeps 1.0 as DPI 96" dpi_is DUMMY1 96
  check "scale: no CRTC change" DUMMY0 2048x1536+2048+0
  step scale DUMMY1 2 -GSScaleFactor 1
  check_true "scale: all equal, DUMMY1 192 too" dpi_is DUMMY1 192
  step scale DUMMY1 1 -GSScaleFactor 2
  check_true "scale: mixed again, DUMMY1 96" dpi_is DUMMY1 96
  check_true "scale: DUMMY0 stays at 192" dpi_is DUMMY0 192

  echo "$passes passed, $fails failed"
  [ $fails -eq 0 ]
}

case $cmd in
  start) start "${3:-}" ;;
  plug) plug "${3:?output}" ;;
  unplug) unplug "${3:?output}" ;;
  run) run ;;
  stop) stop ;;
  *) sed -n '3,30p' "$0"; exit 2 ;;
esac
