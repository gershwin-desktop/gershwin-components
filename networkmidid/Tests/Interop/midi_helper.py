#!/usr/bin/env python3
#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
#
# Helper for rtpmidid-interop.sh: writes the test MIDI file and checks what
# aseqdump printed on the receiving side.
#   midi_helper.py write <file.mid>
#   midi_helper.py check <aseqdump.txt>
import sys

# Bytes from F0 to F7: networkmidid sends it in two packets, rtpmidid in eight.
# Larger sysex sent by rtpmidid arrives split in two with two bytes lost
# (rtpmidid's ALSA input, seen on the wire), so it is not tested here.
SYSEX_LEN = 2000


def varlen(n):
    out = [n & 0x7F]
    n >>= 7
    while n:
        out.insert(0, 0x80 | (n & 0x7F))
        n >>= 7
    return bytes(out)


def sysex_body():
    return bytes([0x7D] + [i % 0x80 for i in range(SYSEX_LEN - 3)])


def write(path):
    ev = b""
    # Spread over time so the receiving side sees them in order.
    # One second of silence first: rtpmidid opens a network session for
    # each ALSA client that connects to its port, so the first event would
    # otherwise be sent before that session is up.
    ev += varlen(192) + bytes([0x90, 60, 100])
    ev += varlen(48) + bytes([0x80, 60, 0])
    ev += varlen(48) + bytes([0xB0, 7, 100])
    ev += varlen(48) + bytes([0xE0, 0x68, 0x47])  # pitch bend +1000
    data = sysex_body() + b"\xF7"
    ev += varlen(48) + b"\xF0" + varlen(len(data)) + data
    ev += varlen(96) + b"\xFF\x2F\x00"
    track = b"MTrk" + len(ev).to_bytes(4, "big") + ev
    hdr = b"MThd" + (6).to_bytes(4, "big") + (0).to_bytes(2, "big") \
        + (1).to_bytes(2, "big") + (96).to_bytes(2, "big")
    open(path, "wb").write(hdr + track)


def check(path):
    note_on = note_off = cc = bend = False
    sysex = bytearray()
    for line in open(path, errors="replace"):
        if "Note on" in line and "note 60" in line and "velocity 100" in line:
            note_on = True
        # aseqdump shows a note on with velocity 0 or a note off
        if ("Note off" in line and "note 60" in line) or \
           ("Note on" in line and "note 60" in line and "velocity 0" in line):
            note_off = True
        if "Control change" in line and "controller 7" in line \
           and "value 100" in line:
            cc = True
        if "Pitch bend" in line and "value 1000" in line:
            bend = True
        if "System exclusive" in line:
            hexes = line.split("System exclusive", 1)[1].split()
            sysex += bytes(int(h, 16) for h in hexes)
    want = b"\xF0" + sysex_body() + b"\xF7"
    results = {
        "note on": note_on,
        "note off": note_off,
        "control change": cc,
        "pitch bend": bend,
        "sysex %d bytes" % SYSEX_LEN: bytes(sysex) == want,
    }
    ok = True
    for k, v in results.items():
        print("  %-20s %s" % (k, "ok" if v else "MISSING"))
        ok = ok and v
    if not ok and sysex:
        print("  (received %d sysex bytes)" % len(sysex))
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("write", "check"):
        sys.exit("usage: midi_helper.py write|check <file>")
    sys.exit(write(sys.argv[2]) if sys.argv[1] == "write" else check(sys.argv[2]))
