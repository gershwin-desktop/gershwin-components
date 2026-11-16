#!/bin/sh
#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
#
# Renders a list of SVG icons the way appwrap does and compares each with a
# reference PNG rendered by ImageMagick, so that a lunasvg update or a change
# here cannot quietly make the icons look different. Not part of
# "gmake check" because the reference images are not in the repository.
#
# usage: Tests/regression.sh LIST REFDIR [OBJDIR [OUTDIR]]
#   LIST    lines of "name.png<TAB>/path/to/icon.svg"
#   REFDIR  holds the reference name.png for every line
#   OBJDIR  where svgconvert and svgconvert_pnginfo are (default ./obj,
#           built by "gmake check")
#   OUTDIR  keeps the renders (default: a temporary directory)
#
# Prints the PSNR per icon and fails if any icon is below 30 dB, except
# those lunasvg cannot match because they use filters or text, which
# svgconvert does not render.

set -u

list=${1:?usage: regression.sh LIST REFDIR [OBJDIR [OUTDIR]]}
ref=${2:?usage: regression.sh LIST REFDIR [OBJDIR [OUTDIR]]}
obj=${3:-./obj}
if [ $# -ge 4 ]; then
    out=$4
    mkdir -p "$out"
else
    out=$(mktemp -d "${TMPDIR:-/tmp}/svgconvert-regression.XXXXXX")
    trap 'rm -rf "$out"' EXIT
fi
threshold=30

# Icons whose drawing depends on <filter> or <text>.
expected_below() {
    case $1 in
        transmission-devel.svg|audacity.svg|org.inkscape.Inkscape.svg) echo filter ;;
        Bhyve_VM.svg|net.sourceforge.liferea.svg|filled-xterm.svg|mini.xterm.svg|xterm.svg) echo text ;;
        *) echo "" ;;
    esac
}

total=0
ok=0
known=0
bad=0
sizes=0
tab=$(printf '\t')
while IFS="$tab" read -r name svg; do
    [ -n "$name" ] || continue
    total=$((total + 1))
    if ! "$obj/svgconvert" "$svg" -background none -resize 256x256 "$out/$name" 2>"$out/stderr"; then
        bad=$((bad + 1))
        echo "FAIL  $name: $(cat "$out/stderr")"
        continue
    fi
    psnr=$("$obj/svgconvert_pnginfo" -psnr "$ref/$name" "$out/$name")
    note=""
    # Reference renders made through rsvg can be a pixel larger or smaller
    # than ImageMagick 7's own rounding, which svgconvert follows; render
    # those at the reference size so that the drawing itself is compared.
    case $psnr in
        size*)
            refsize=$("$obj/svgconvert_pnginfo" "$ref/$name" | tr ' ' x)
            "$obj/svgconvert" "$svg" -background none -resize "$refsize!" "$out/$name"
            psnr=$("$obj/svgconvert_pnginfo" -psnr "$ref/$name" "$out/$name")
            note=" (reference is $refsize, compared at that size)"
            sizes=$((sizes + 1))
            ;;
    esac
    reason=$(expected_below "$(basename "$svg")")
    if awk "BEGIN { exit !($psnr >= $threshold) }" 2>/dev/null; then
        ok=$((ok + 1))
        echo "ok    $name $psnr$note"
    elif [ -n "$reason" ]; then
        known=$((known + 1))
        echo "known $name $psnr ($reason)$note"
    else
        bad=$((bad + 1))
        echo "FAIL  $name $psnr$note"
    fi
done <"$list"

echo
echo "$total icons: $ok at or above $threshold dB, $known known below (filters, text), $bad failed; $sizes differ in size from the reference by rounding"
[ "$bad" -eq 0 ] && [ "$total" -gt 0 ]
