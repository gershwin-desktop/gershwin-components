#!/bin/sh
#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
#
# Runs the svgconvert unit tests and renders the fixtures through the real
# tool, reading the PNGs back to check sizes and pixels. Called by
# "gmake check" with the object directory as the only argument.

set -u

obj=${1:?usage: check.sh OBJDIR}
here=$(cd "$(dirname "$0")" && pwd)
sc=$obj/svgconvert
info=$obj/svgconvert_pnginfo
fixtures=$here/Fixtures
out=$(mktemp -d "${TMPDIR:-/tmp}/svgconvert-check.XXXXXX")
trap 'rm -rf "$out"' EXIT

passed=0
failed=0

pass() {
    passed=$((passed + 1))
    echo "Passed test:     $1"
}

fail() {
    failed=$((failed + 1))
    echo "FAILED test:     $1"
}

# expect DESCRIPTION EXPECTED COMMAND...
expect() {
    description=$1
    expected=$2
    shift 2
    actual=$("$@" 2>&1)
    if [ "$actual" = "$expected" ]; then
        pass "$description"
    else
        fail "$description (expected '$expected', got '$actual')"
    fi
}

# render DESCRIPTION OUTPUT ARGS... : svgconvert must succeed
render() {
    description=$1
    shift
    if "$sc" "$@" >"$out/stderr" 2>&1; then
        pass "$description renders"
    else
        fail "$description renders: $(cat "$out/stderr")"
    fi
}

# refuse DESCRIPTION NEEDLE ARGS... : svgconvert must fail naming NEEDLE
refuse() {
    description=$1
    needle=$2
    shift 2
    if "$sc" "$@" >"$out/stderr" 2>&1; then
        fail "$description fails"
    elif grep -q -- "$needle" "$out/stderr"; then
        pass "$description fails naming $needle"
    else
        fail "$description fails naming $needle: $(head -1 "$out/stderr")"
    fi
}

echo "== unit tests"
if "$obj/svgconvert_unit" >"$out/unit" 2>&1; then
    pass "unit tests ($(tail -1 "$out/unit"))"
else
    grep FAILED "$out/unit"
    fail "unit tests ($(tail -1 "$out/unit"))"
fi

echo "== rendering"
render "intrinsic size" "$fixtures/square.svg" "$out/a.png"
expect "intrinsic size is 16x16" "16 16" "$info" "$out/a.png"
expect "default background is opaque white" "16 16 255 255 255 255" "$info" "$out/a.png" 0 0
expect "the square is red" "16 16 255 0 0 255" "$info" "$out/a.png" 8 8

render "appwrap's command line" "$fixtures/square.svg" -background none -resize 256x256 "$out/b.png"
expect "-resize 256x256 on a square" "256 256" "$info" "$out/b.png"
expect "-background none leaves the margin transparent" "256 256 0 0 0 0" "$info" "$out/b.png" 2 2
expect "the drawing scales with the resize" "256 256 255 0 0 255" "$info" "$out/b.png" 70 70
expect "and stays inside its scaled box" "256 256 0 0 0 0" "$info" "$out/b.png" 60 60

render "wide icon fit" "$fixtures/wide.svg" -background none -resize 256x256 "$out/c.png"
expect "a wide icon keeps its aspect" "256 128" "$info" "$out/c.png"

render "wide icon padded" -background none "$fixtures/wide.svg" -resize 64x64 -gravity center -extent 64x64 "$out/d.png"
expect "-extent pads to a square" "64 64" "$info" "$out/d.png"
expect "the padding above is transparent" "64 64 0 0 0 0" "$info" "$out/d.png" 32 8
expect "the drawing is centred" "64 64 0 0 255 255" "$info" "$out/d.png" 32 32
expect "the padding below is transparent" "64 64 0 0 0 0" "$info" "$out/d.png" 32 56

render "padding with a colour" -background "#00ff00" "$fixtures/wide.svg" -gravity center -extent 40x40 "$out/e.png"
expect "-extent pads with the background colour" "40 40 0 255 0 255" "$info" "$out/e.png" 20 2

render "menu glyph" -background none "$fixtures/square.svg" -resize 18x18! -strip -quiet "$out/f.png"
expect "-resize 18x18! is exact" "18 18" "$info" "$out/f.png"

render "density" -density 192 "$fixtures/square.svg" "$out/g.png"
expect "-density 192 doubles the size" "32 32" "$info" "$out/g.png"

render "frame suffix and png: prefix" "$fixtures/square.svg[0]" "png:$out/h.img"
expect "png: writes PNG whatever the name" "16 16" "$info" "$out/h.img"

"$sc" -background none - png:- <"$fixtures/wide.svg" >"$out/i.png" 2>"$out/stderr"
expect "standard input to standard output" "40 20" "$info" "$out/i.png"

echo "== SVG features"
render "features" -background none "$fixtures/features.svg" "$out/j.png"
left=$("$info" "$out/j.png" 1 8 | cut -d' ' -f3)
right=$("$info" "$out/j.png" 14 8 | cut -d' ' -f3)
if [ "$left" -lt 64 ] && [ "$right" -gt 190 ]; then
    pass "a CSS-styled gradient runs dark to light ($left to $right)"
else
    fail "a CSS-styled gradient runs dark to light ($left to $right)"
fi
expect "use of a symbol" "32 32 0 255 0 255" "$info" "$out/j.png" 24 8
expect "inside the clip path" "32 32 0 0 255 255" "$info" "$out/j.png" 8 24
expect "outside the clip path" "32 32 0 0 0 0" "$info" "$out/j.png" 1 17
expect "inside the mask" "32 32 255 0 0 255" "$info" "$out/j.png" 20 24
expect "outside the mask" "32 32 0 0 0 0" "$info" "$out/j.png" 28 24

echo "== errors"
refuse "an unknown option" "-flatten" "$fixtures/square.svg" -flatten "$out/x.png"
refuse "a JPEG output" ".jpg" "$fixtures/square.svg" "$out/x.jpg"
refuse "a missing input" "nothere.svg" "$out/nothere.svg" "$out/x.png"
printf 'not svg' >"$out/bad.svg"
refuse "a file that is not SVG" "bad.svg" "$out/bad.svg" "$out/x.png"
refuse "an unwritable output" "cannot write" "$fixtures/square.svg" "$out/no/such/dir/x.png"
refuse "a missing output" "output" "$fixtures/square.svg"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
