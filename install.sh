#!/bin/bash
# Builds, then replaces /Applications/AVPriorityBar.app and relaunches it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
"$ROOT/build.sh"
echo "Installing to /Applications..."
pkill -x AVPriorityBar 2>/dev/null || true
sleep 1
rm -rf /Applications/AVPriorityBar.app
cp -R "$ROOT/dist/AVPriorityBar.app" /Applications/
open /Applications/AVPriorityBar.app
echo "AV Priority Bar is running - look for the speaker icon in the menu bar."
