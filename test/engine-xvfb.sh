#!/bin/sh
# Runs the Defold engine on a virtual display, for Linux CI:
#   DMENGINE=/path/to/dmengine test/engine-xvfb.sh <engine arguments>
# The headless engine has no http module, so the live test needs the full
# engine, and the full engine needs a display.
Xvfb :99 >/dev/null 2>&1 &
XVFB=$!
sleep 1
DISPLAY=:99 "$DMENGINE" "$@"
code=$?
kill "$XVFB" 2>/dev/null
exit "$code"
