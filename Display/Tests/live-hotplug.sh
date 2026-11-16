#!/bin/sh
#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause
#
# Live check of the per-user display configuration with the WindowManager:
# a monitor plugged in gets the saved layout, a monitor unplugged gives its
# windows and the pointer back to the primary, plugging it in again restores
# the saved layout, and "displayconfig apply" on an unchanged server changes
# nothing (no RandR event, or the WindowManager would loop).
#
# Needs, on display :N of slot uitestN (never :0):
#   - the dummy Xorg of live-multihead.sh ("start N"), DUMMY0 alone,
#   - the uitest session on it, with the WindowManager under test started
#     with "-URSDisplayConfigTool $TOOL",
#   - Tests/Live/obj/display-live and the displayconfig tool built.
#
# Usage: live-hotplug.sh N TOOL

set -u
num=${1:?display number}
tool=${2:?path of displayconfig}
[ "$num" = 0 ] && { echo "refusing to touch display :0" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
DISPLAY=:$num
export DISPLAY
user=uitest$num
live=$here/Live/obj/display-live
harness=$here/live-multihead.sh
passes=0
fails=0

as_user() {
  sudo -u "$user" env DISPLAY=:$num HOME=/home/$user GNUSTEP_USER_ROOT=/home/$user/.GNUstep \
    sh -c '. /System/Library/Makefiles/GNUstep.sh; cd /tmp; "$@"' _ "$@"
}

geom() {   # geometry of an output as xrandr prints it, "" when off
  xrandr | awk -v o="$1" '$1 == o { for (i = 3; i <= NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+/) { print $i; exit } }'
}

pass() { passes=$((passes + 1)); echo "PASS: $1"; }
fail() { fails=$((fails + 1)); echo "FAIL: $1"; }

# expect DESCRIPTION OUTPUT GEOMETRY: waits up to 6 s, the WindowManager
# answers a hotplug after its debounce and the tool's run.
expect() {
  i=0
  while [ $i -lt 30 ]; do
    [ "$(geom "$2")" = "$3" ] && { pass "$1 ($2 $3)"; return; }
    sleep 0.2; i=$((i + 1))
  done
  fail "$1 ($2 is '$(geom "$2")', expected '$3')"
}

screen_is() { xrandr | grep -q "current $1,"; }
primary_is() { xrandr | grep -q "^$1 connected primary"; }

window_geometry() {  # x,y of the frame titled $1
  id=$(xdotool search --name "^$1\$" | head -1)
  [ -n "$id" ] || return 1
  xdotool getwindowgeometry "$id" | awk '/Position/ { sub(/ \(.*/, "", $2); print $2 }'
}

pointer() { xdotool getmouselocation | sed 's/x:\([0-9]*\) y:\([0-9]*\).*/\1,\2/'; }

randr_events_during() {  # count RandR events while running a command
  log=$(mktemp)
  xev -root -event randr > "$log" 2>&1 &
  xp=$!
  sleep 0.5
  "$@" > /dev/null
  sleep 1
  kill $xp 2>/dev/null
  wait $xp 2>/dev/null
  n=$(grep -c '^RR' "$log" || true)
  rm -f "$log"
  echo "$n"
}

[ -x "$live" ] || { echo "build $live first (gmake in Tests/Live)" >&2; exit 1; }
xrandr | grep -q '^DUMMY0 connected' || { echo "no dummy Xorg on :$num" >&2; exit 1; }
pgrep -u "$user" -x WindowManager > /dev/null || { echo "no WindowManager of $user" >&2; exit 1; }

echo "== a new monitor extends the desktop to the right"
sh "$harness" plug "$num" DUMMY1
expect "a monitor seen for the first time is lit to the right" DUMMY1 2048x1536+2048+0
primary_is DUMMY0 && pass "DUMMY0 stays primary" || fail "DUMMY0 stays primary"

echo "== the user arranges it and saves"
"$live" mode DUMMY1 1280x1024 > /dev/null
"$live" primary DUMMY1 > /dev/null
sleep 2
[ "$(geom DUMMY1)" = 1280x1024+2048+0 ] && primary_is DUMMY1 \
  && pass "the WindowManager leaves a change by the user alone" \
  || fail "the WindowManager undid the user's arrangement ($(geom DUMMY1), $(xrandr | grep primary))"
as_user "$tool" save
as_user "$tool" print --json | grep -q '"saved"' && pass "the layout is saved for these monitors" \
  || fail "the layout is saved for these monitors"

echo "== a window and the pointer on the monitor that goes away"
xmessage -title rescue-me -geometry 400x200+2200+300 "rescue me" &
xm=$!
sleep 2
xdotool mousemove 2500 500
before=$(window_geometry rescue-me)
echo "window frame at $before, pointer at $(pointer)"
sh "$harness" unplug "$num" DUMMY1
expect "the remaining monitor stays at 0,0" DUMMY0 2048x1536+0+0
i=0; while [ $i -lt 20 ] && ! primary_is DUMMY0; do sleep 0.2; i=$((i + 1)); done
primary_is DUMMY0 && pass "the remaining monitor becomes primary" \
  || fail "the remaining monitor becomes primary"
i=0; while [ $i -lt 20 ] && ! screen_is "2048 x 1536"; do sleep 0.2; i=$((i + 1)); done
screen_is "2048 x 1536" && pass "the screen shrinks to the remaining monitor" \
  || fail "the screen shrinks to the remaining monitor"
[ "$(geom DUMMY1)" = "" ] && pass "the CRTC of the unplugged monitor is switched off" \
  || fail "the CRTC of the unplugged monitor is switched off"
on_primary() {  # x,y of a 400x200 frame lies inside DUMMY0 at 0,0
  x=${1%,*}; y=${1#*,}
  [ -n "$1" ] && [ "$x" -ge 0 ] && [ "$y" -ge 0 ] && [ $((x + 400)) -le 2048 ] && [ $((y + 200)) -le 1536 ]
}
i=0; after=""
while [ $i -lt 25 ]; do
  after=$(window_geometry rescue-me)
  on_primary "$after" && break
  sleep 0.2; i=$((i + 1))
done
on_primary "$after" && pass "the window comes back onto the primary ($before -> $after)" \
  || fail "the window comes back onto the primary ($before -> $after)"
[ "$(pointer)" = "1024,768" ] && pass "the pointer is moved to the center of the primary" \
  || fail "the pointer is moved to the center of the primary (at $(pointer))"

echo "== plugging it in again restores the saved layout"
sh "$harness" plug "$num" DUMMY1
expect "the saved mode and place return" DUMMY1 1280x1024+2048+0
expect "the other monitor keeps its place" DUMMY0 2048x1536+0+0
i=0; while [ $i -lt 20 ] && ! primary_is DUMMY1; do sleep 0.2; i=$((i + 1)); done
primary_is DUMMY1 && pass "the saved primary returns" || fail "the saved primary returns"

echo "== apply on an unchanged server"
sleep 2
out=$(as_user "$tool" apply)
echo "$out" | grep -q '^unchanged' && pass "apply reports nothing to do" || fail "apply reports nothing to do ($out)"
n=$(randr_events_during as_user "$tool" apply)
[ "$n" = 0 ] && pass "a second apply sends no RandR event" || fail "a second apply sent $n RandR events"

kill $xm 2>/dev/null
echo "$passes passed, $fails failed"
[ $fails -eq 0 ]
