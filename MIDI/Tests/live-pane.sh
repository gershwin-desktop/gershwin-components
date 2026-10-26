#!/bin/sh
#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
#
# Live check of the MIDI pane against the simulation backend, driven with
# DriveUI in an isolated test session (gershwin-wm-headless-testing): never
# run it on the logged-in user's display.
#
# Before running, as the slot user on the slot display:
#   defaults write io.github.gershwin-desktop.MIDINetwork Backend simulation
#   SystemPreferences MIDI -NSLanguages '(English)'
# with MIDI.prefPane in that user's ~/Library/Bundles and the library on
# LD_LIBRARY_PATH if it is not installed.
#
# Usage: live-pane.sh <slot user> <display> <screenshot dir>

set -u
U=$1
D=$2
OUT=$3
mkdir -p "$OUT"
FAILS=0

P=$(pgrep -u "$U" -x SystemPreferenc) || { echo "System Preferences is not running for $U"; exit 1; }
du() { sudo -u "$U" env DISPLAY="$D" /System/Library/Tools/drive_ui --pid "$P" "$@"; }
tree() { du get_full_tree; }
field() { tree | awk -F'\t' -v c="$1" -v t="$2" -v n="${3:-1}" -v f="$4" '$2==c && $3==t {k++; if (k==n) {print $f; exit}}'; }
wid() { field "$1" "$2" "${3:-1}" 9; }
row() { tree | awk -F'\t' -v t="$1" '$2=="NSTableViewRow" && $3==t {print $9}' | tail -1; }
status() { tree | awk -F'\t' '$2=="NSTextField"' | tail -1 | cut -f3; }
check() {
    if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (got '$2', want '$3')"; FAILS=$((FAILS + 1)); fi
}
shot() { DISPLAY="$D" import -window root "$OUT/$1.png"; }
# X11 point at the centre of a widget's screen_frame, plus an x offset;
# DriveUI frames are y-up from the bottom of the screen.
point() {
    H=$(DISPLAY="$D" xdotool getdisplaygeometry | cut -d' ' -f2)
    echo "$1" | sed 's/[{}=;a-z]//g' | awk -v h="$H" -v dx="$2" '{printf "%d %d\n", $1 + (dx >= 0 ? dx : $3 / 2), h - ($2 + $4 / 2)}'
}
press_at() { DISPLAY="$D" xdotool mousemove $1 $2 sleep 0.3 mousedown 1 sleep 0.15 mouseup 1; sleep 1; }
# Pick item n (1 = the one below the current "None") of a pop-up whose
# menu opens with the selected item over the button, 22 px per item.
popup_pick() {
    set -- $(point "$(field NSPopUpButton "$1" "$2" 6)" -1) "$3"
    DISPLAY="$D" xdotool mousemove $1 $2 sleep 0.3 mousedown 1 sleep 1 mousemove $1 $(($2 + 22 * $3)) sleep 0.5 mouseup 1
    sleep 1
}

check "status names the simulation" "$(status)" "Simulated network MIDI service (for development)."
check "remove session starts disabled" "$(field NSButton - 1 8)" "0"

du click "$(wid NSButton + 1)"; sleep 1
du click "$(wid NSButton + 1)"; sleep 1
check "two sessions after two clicks on +" "$(field NSTextField 'Session 2' 1 3)" "Session 2"
check "the new session's port" "$(field NSTextField 5006 1 3)" "5006"
shot 01-two-sessions

du click "$(wid NSButton - 1)"; sleep 1
check "removing selects the remaining session" "$(field NSTextField 5004 1 3)" "5004"

press_at $(point "$(tree | awk -F'\t' '$2=="NSTableViewRow"{print $6; exit}')" 11)
check "the check box turns the session on" "$(tree | awk -F'\t' '$2=="NSTableViewRow"{print $3; exit}')" "1"

du click "$(row 'Studio Laptop')"; sleep 1
check "Connect is enabled for a selected host" "$(field NSButton Connect 1 8)" "1"
du click "$(wid NSButton Connect)"; sleep 2.5
check "the peer shows up as participant" "$(tree | awk -F'\t' '$2=="NSTableViewRow" && $3=="Studio Laptop"' | wc -l | tr -d ' ')" "2"
shot 02-connected

popup_pick None 1 1
popup_pick None 1 1
check "From routes the keyboard" "$(field NSPopUpButton 'USB Keyboard' 1 3)" "USB Keyboard"
check "To routes the synth" "$(field NSPopUpButton 'Software Synth' 1 3)" "Software Synth"
shot 03-routing

du click "$(row 'Busy Studio')"; sleep 1
du click "$(wid NSButton Connect)"; sleep 2.5
check "a declined invitation shows in the status line" "$(status)" "The other computer declined the invitation."
shot 04-declined

du click "$(row 'Studio Laptop')"; sleep 1
check "a participant can be disconnected" "$(field NSButton Disconnect 1 8)" "1"
du click "$(wid NSButton Disconnect)"; sleep 1
check "the participant is gone" "$(tree | awk -F'\t' '$2=="NSTableViewRow" && $3=="Studio Laptop"' | wc -l | tr -d ' ')" "1"

du click "$(wid NSButton + 1)"; sleep 1
F=$(wid NSTextField 5006)
du click "$F"; sleep 0.3
DISPLAY="$D" xdotool key End BackSpace BackSpace BackSpace BackSpace BackSpace BackSpace type 5005
du press; sleep 1
check "a clashing port is refused" "$(status)" "Another session already uses this port or the one above it."
check "and the field shows the stored port again" "$(du get "$F")" "5006"
shot 05-port-in-use

echo "$FAILS failed"
[ "$FAILS" -eq 0 ]
