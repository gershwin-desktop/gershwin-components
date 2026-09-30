#!/bin/sh
#
# Is libdbus here, in a form Menu can actually use?
#
# Answers yes or no on stdout, and says why on stderr when asked to.  Menu
# uses this to decide whether to build and install the MediaExtra, which
# steers players over MPRIS2 and has nothing to steer with where there is no
# libdbus.  Being wrong in the "no" direction loses the extra from the build
# and from the installation without a word, so the answer has to be right
# before it is allowed to be quiet.
#
# A header on its own is not enough: the library has to be there to link
# against as well, since a program that only compiles is no use to anything
# that has to run.  So every attempt here both includes <dbus/dbus.h> and
# links.
#
# pkg-config knows where its own headers are, so it is asked first.  It is not
# relied on, though: a build running under sudo may not find it, and a hard
# fallback path is no help on a system that puts its headers somewhere else
# again.  So the header is also looked for where it actually is.

set -u

CC=${CC:-cc}
tmp=${TMPDIR:-/tmp}/gershwin-dbus-probe-$$
trap 'rm -f "$tmp" "$tmp".c' EXIT INT TERM

cat > "$tmp".c <<'EOF'
#include <dbus/dbus.h>
/* Taking the address of a function that lives in the library is what makes
   this a link test rather than a compile test, which is the point: a header
   that is installed without the library would otherwise pass. */
static DBusConnection *(*bus_get)(DBusBusType, DBusError *) = dbus_bus_get_private;
int main(void) { return bus_get == 0; }
EOF

verbose=${1:-}
extra_flags=${2:-}

# $1: extra flags for the compile
try() {
    # shellcheck disable=SC2086
    $CC -x c "$tmp".c $1 -o "$tmp" >/dev/null 2>&1
}

report() {
    # $1: yes or no.  $2: how it was decided, for the log.
    if [ "$verbose" = "-v" ]; then
        echo "has-libdbus: $1 ($2)" >&2
    fi
    echo "$1"
}

# 1. pkg-config, which knows its own paths.
if command -v pkg-config >/dev/null 2>&1; then
    if pkg_flags=$(pkg-config --cflags --libs dbus-1 2>/dev/null) && [ -n "$pkg_flags" ]; then
        if try "$pkg_flags"; then
            report yes "pkg-config"
            exit 0
        fi
    fi
fi

# 2. Whatever the makefile already worked out for itself.
try "$extra_flags"
if [ $? -eq 0 ]; then
    report yes "flags from the makefile: ${extra_flags:-none}"
    exit 0
fi

# 3. Nothing at all, for a system whose headers are on the default path.
try ""
if [ $? -eq 0 ]; then
    report yes "the default include path"
    exit 0
fi

# 4. Look for the header where distributions actually put it.  The include
#    directory is versioned per release and, on a multiarch system, carries
#    the architecture, so it is found rather than assumed.
for dir in /usr/include/dbus-1.0 /usr/local/include/dbus-1.0 \
           /usr/include/dbus /usr/local/include/dbus; do
    [ -f "$dir/dbus/dbus.h" ] || continue
    for libdir in /usr/lib/dbus-1.0 /usr/local/lib/dbus-1.0 \
                  /usr/lib/*/dbus-1.0 /usr/lib/*-linux-gnu*/dbus-1.0; do
        [ -d "$libdir" ] || continue
        try "-I$dir -I$libdir/include -L$libdir -ldbus-1"
        if [ $? -eq 0 ]; then
            report yes "found at $dir"
            exit 0
        fi
    done
done

# 5. Headers found, but nothing that links.  Say so, because this is the case
#    that is a broken installation rather than an absent library, and the
#    difference matters to whoever reads the log.
for dir in /usr/include/dbus-1.0 /usr/local/include/dbus-1.0; do
    if [ -f "$dir/dbus/dbus.h" ]; then
        report no "the header is at $dir but nothing links against it"
        exit 0
    fi
done

report no "no libdbus header anywhere"
exit 0
