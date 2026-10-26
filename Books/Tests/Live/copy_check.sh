#!/bin/sh
#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause
#
# Live check: open a small book in Books, drag across two paragraphs, press
# Command-C and compare the pasteboard with the expected text.
#
# Runs against an isolated uitest slot only (gershwin-wm-headless-testing):
# the slot's session must be up, /tmp/uitest-session.<N>.owner must name
# uitest<N>, and the pasteboard read is that test user's, never the desktop
# user's clipboard.
#
#   sh Tests/Live/copy_check.sh <N> [Books.app]
#
set -eu
N=${1:?usage: copy_check.sh <slot-number> [Books.app]}
U=uitest$N
H=/home/$U
HERE=$(cd "$(dirname "$0")" && pwd)
APP=${2:-$HERE/../../Books.app}
DISPLAY=:$N
export DISPLAY

[ "$(cat /tmp/uitest-session.$N.owner 2>/dev/null)" = "$U" ] \
  || { echo "slot $N is not claimed by $U"; exit 1; }
xdpyinfo >/dev/null 2>&1 || { echo "display :$N is not up"; exit 1; }
pgrep -u "$U" -x Books >/dev/null && { echo "Books already runs in slot $N"; exit 1; }

WORK=$(sudo -u "$U" mktemp -d "$H/books-copy.XXXXXX")
cleanup() {
  P=$(pgrep -u "$U" -x Books || true)
  if [ -n "$P" ]; then
    sudo kill $P
    while sudo kill -0 $P 2>/dev/null; do sleep 0.2; done
  fi
  sudo rm -rf "$WORK"
}
trap cleanup EXIT

# The test user cannot read the developer's tree everywhere; give it copies.
T=$(mktemp -d)
(cd "$HERE/fixture" && zip -q -X0 "$T/copytest.epub" mimetype \
   && zip -q -Xr9 "$T/copytest.epub" META-INF OEBPS)
clang $(gnustep-config --objc-flags) -fobjc-arc "$HERE/pbread.m" -o "$T/pbread" \
  $(gnustep-config --gui-libs)
sudo cp -r "$APP" "$T/copytest.epub" "$T/pbread" "$WORK/"
sudo chown -R "$U" "$WORK"
rm -rf "$T"
# A fresh library, so the book opens at its first page.
sudo rm -f "$H/Library/ApplicationSupport/Books/currentbook.plist" \
           "$H/Library/ApplicationSupport/Books/library.plist"

AS="sudo -u $U env DISPLAY=$DISPLAY HOME=$H GNUSTEP_USER_ROOT=$H/.GNUstep \
  FONTCONFIG_FILE=/System/Library/Preferences/fonts.conf \
  DBUS_SESSION_BUS_ADDRESS=$(cat /tmp/uitest${N}_dbus.txt)"
$AS sh -c ". /System/Library/Makefiles/GNUstep.sh; cd $WORK; \
  exec $WORK/Books.app/Books -GSFilePath $WORK/copytest.epub" \
  >"/tmp/uitest${N}_books.log" 2>&1 &
P=
for i in $(seq 1 40); do
  P=$(pgrep -u "$U" -x Books || true)
  [ -n "$P" ] && [ -S /tmp/driveui.$P.sock ] && break
  sleep 0.5
done
[ -n "$P" ] || { echo "Books did not start"; exit 1; }
sleep 3

# The right-hand page's text view; screen_frame is bottom-up, X is top-down.
ROW=$($AS /System/Library/Tools/drive_ui --pid "$P" get_full_tree \
  | awk -F'\t' '$2=="BookPageTextView" && $7=="0" {r=$5 "|" $6} END {print r}')
FRAME=${ROW#*|}
PTW=$(echo "${ROW%%|*}" | sed 's/.*width = \([0-9.]*\);.*/\1/')
SH=$(xdpyinfo | awk '/dimensions:/ {split($2, d, "x"); print d[2]}')
# Line offsets (in points) of the fixture's first two paragraphs below the
# heading at the default font size, times the session's scale factor; the drag
# ends right of the second line's last letter.
set -- $(echo "$FRAME $PTW $SH" | sed 's/[{}=;a-z]/ /g' | awk '{
  x = $1; y = $2; w = $3; h = $4; ptw = $5; sh = $6; s = w / ptw
  top = sh - y - h
  printf "%d %d %d %d\n", x + 1, x + w - 4, top + 108 * s, top + 146 * s }')
LEFT=$1 RIGHT=$2 L1=$3 L2=$4

$AS sh -c ". /System/Library/Makefiles/GNUstep.sh; timeout 20 $WORK/pbread --clear" 2>/dev/null
xdotool mousemove "$LEFT" "$L1" sleep 0.3 mousedown 1 sleep 0.2 \
  mousemove $((LEFT + 200)) "$L1" sleep 0.2 mousemove "$RIGHT" "$L2" sleep 0.3 mouseup 1
sleep 1
xdotool keydown alt; xdotool key c; xdotool keyup alt
sleep 1

GOT=$($AS sh -c ". /System/Library/Makefiles/GNUstep.sh; timeout 20 $WORK/pbread" 2>/dev/null)
WANT='PLAIN<<Alpha paragraph has a complicated word and italic text in it.

Bravo paragraph follows the first one directly.>>'
FAIL=0
echo "$GOT" | grep -q "^RTFBYTES [1-9]" || { echo "FAIL: no RTF on the pasteboard"; FAIL=1; }
PLAIN=$(echo "$GOT" | sed -n '/^PLAIN<</,/>>$/p')
[ "$PLAIN" = "$WANT" ] || { echo "FAIL: plain text was:"; echo "$PLAIN"; FAIL=1; }
# The selection must still be there after mouse up (Highlight is enabled), and
# copying must not have turned it into a highlight annotation.
$AS /System/Library/Tools/drive_ui --pid "$P" menu \
  | awk -F'\t' '$3=="Highlight Selection" && $4=="1" {ok=1} END {exit ok ? 0 : 1}' \
  || { echo "FAIL: selection gone after mouse up"; FAIL=1; }
[ $FAIL = 0 ] && echo "PASS: two paragraphs copied as plain text and RTF"
exit $FAIL
