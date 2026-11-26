#!/bin/sh
# Smoke test for the spike, run inside the image built from ./Dockerfile:
# opens a GTK4 window with a VTE terminal under Xvfb, runs a child that prints a marker, reads the marker back from
# the terminal's screen and exits 0 only if it is there and the child exited 0.
set -eu
cd "$(dirname "$0")"
swift build -c release 2>&1 | tail -3
BIN="$(swift build -c release --show-bin-path)/LinuxVteSpike"
out="$(xvfb-run -a -s '-screen 0 1024x768x24' "$BIN" --smoke 2>&1)" || { echo "FAIL: spike exited non-zero"; echo "$out"; exit 1; }
echo "$out"
echo "$out" | grep -q '^screen-has-marker: yes$' || { echo "FAIL: marker not read back from the VTE screen"; exit 1; }
echo "$out" | grep -q '^child-exit-status: 0$' || { echo "FAIL: child exit status not seen"; exit 1; }
echo "PASS: GTK4 window + VTE terminal ran a child and showed its output"
