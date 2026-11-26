#!/bin/sh
# Symbolizes the native backtrace of a Composer crash report (~/Library/Logs/Composer-crash-*.txt) offline.
# Usage: symbolize.sh <report.txt> [executable]
# The report lists "map" lines (address range, permissions, file offset, path) next to the backtrace frames written as
# "path(+0xoffset) [0xaddress]"; the address minus the lowest mapping of that file is what addr2line wants for a PIE or
# a shared library, so the load offset is accounted for here.
set -eu
report=${1:?usage: symbolize.sh report.txt [executable]}
exe=${2:-$(sed -n 's/^executable: //p' "$report" | head -n 1)}

# Only the first report in the file (a signal after an exception report appends a second one).
awk -v exe="$exe" '
  function hex(s,   i, c, v, d) {
    v = 0; s = tolower(s); sub(/^0x/, "", s)
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1); d = index("0123456789abcdef", c) - 1; v = v * 16 + d
    }
    return v
  }
  /^map / {
    split($2, range, "-"); path = $0; sub(/^.*[0-9a-f]+ [0-9a-f]+:[0-9a-f]+ [0-9]+ +/, "", path)
    if (!(path in base) || hex(range[1]) < base[path]) { base[path] = hex(range[1]) }
    n++; lo[n] = hex(range[1]); hi[n] = hex(range[2]); file[n] = path
  }
  /^faulting pc: / { pc[++frames] = $3 }
  /\[0x[0-9a-f]+\]$/ {
    addr = $NF; gsub(/[\[\]]/, "", addr); pc[++frames] = addr
  }
  END {
    for (f = 1; f <= frames; f++) {
      a = hex(pc[f]); found = ""
      for (i = 1; i <= n; i++) { if (a >= lo[i] && a < hi[i]) { found = file[i]; break } }
      if (found == "") { print pc[f], "?", ""; continue }
      printf "%s %s %x\n", pc[f], found, a - base[found]
    }
  }' "$report" | while read -r addr file offset; do
  if [ "$file" = "?" ]; then
    echo "$addr  (not in a mapped executable segment)"
    continue
  fi
  printf '%s %s: ' "$addr" "$(basename "$file")"
  addr2line -f -C -e "$file" "0x$offset" | tr '\n' ' '
  echo
done
