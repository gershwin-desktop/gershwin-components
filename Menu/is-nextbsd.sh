#!/bin/sh
#
# Is this NextBSD?
#
# Answers yes or no on stdout.  Menu uses this to leave D-Bus out of the
# build there: NextBSD ships no D-Bus, and a libdbus that turned up from
# somewhere else would only give the global menu a bus nobody is on.
#
# uname is no help, since NextBSD runs a FreeBSD kernel and says FreeBSD.
# So the system is recognised by what it ships instead, in the same ways
# the rest of Gershwin already does: /etc/os-release says ID=nextbsd (as
# gershwin-developer's bootstrap.sh reads it), /bin/nextbsd-version is
# there (as DirectoryServices checks), or /usr/lib/system, where the base
# system keeps its libraries, exists (as gershwin-developer's
# install-system-domain.sh checks).  macOS has /usr/lib/system too, but
# Menu is not built there.

if [ "$(uname -s 2>/dev/null)" = "NextBSD" ]; then
    echo yes
elif [ -f /etc/os-release ] && grep -Eq '^ID="?nextbsd"?$' /etc/os-release; then
    echo yes
elif [ -e /bin/nextbsd-version ] || [ -d /usr/lib/system ]; then
    echo yes
else
    echo no
fi
exit 0
