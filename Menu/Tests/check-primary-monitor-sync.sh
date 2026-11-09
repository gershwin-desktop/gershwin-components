#!/bin/sh
#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause OR GPL-2.0-or-later
#
# Fails when the copy of PrimaryMonitor.[hm] (and its test) in
# gershwin-workspace differs from the one here.  The two repositories share
# no library, and the menu bar, the desktop icons and the Dock must pick the
# same monitor, so the files are kept identical by hand.
#
# Usage: sh check-primary-monitor-sync.sh <gershwin-workspace checkout>

set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
ws=${1:?usage: $0 <gershwin-workspace checkout>}
[ -d "$ws/Workspace/Desktop" ] || { echo "not a gershwin-workspace checkout: $ws" >&2; exit 2; }

rc=0
for f in PrimaryMonitor.h PrimaryMonitor.m; do
  cmp -s "$here/$f" "$ws/Workspace/Desktop/$f" || { echo "differs: $f"; rc=1; }
done

# The tests differ only in the include path and the line naming the other
# repository.
norm() {
  sed -e 's#"\.\./\.\./Workspace/Desktop/PrimaryMonitor\.h"#"PrimaryMonitor.h"#' \
      -e 's#"\.\./\.\./PrimaryMonitor\.h"#"PrimaryMonitor.h"#' \
      -e '/The same cases run in gershwin-/d' "$1"
}
norm "$here/Tests/Unit/t_PrimaryMonitor.m" > "${TMPDIR:-/tmp}/pm_gc.$$"
norm "$ws/Tests/Desktop/t_PrimaryMonitor.m" > "${TMPDIR:-/tmp}/pm_gw.$$"
cmp -s "${TMPDIR:-/tmp}/pm_gc.$$" "${TMPDIR:-/tmp}/pm_gw.$$" || { echo "differs: t_PrimaryMonitor.m"; rc=1; }
rm -f "${TMPDIR:-/tmp}/pm_gc.$$" "${TMPDIR:-/tmp}/pm_gw.$$"

[ $rc -eq 0 ] && echo "PrimaryMonitor copies are in sync"
exit $rc
