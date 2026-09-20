#!/bin/bash
# Copies the built app into /Applications and launches it.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="PaperRushBar"
SRC="build/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"

if [ ! -d "${SRC}" ]; then
	echo "Run ./build.sh first."
	exit 1
fi

# "Launch at login" only sticks if the app lives in a stable location.
pkill -x "${APP_NAME}" 2>/dev/null || true
rm -rf "${DEST}"
cp -R "${SRC}" "${DEST}"
xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true

echo "==> Installed to ${DEST}"
open "${DEST}"
echo "    Look for the hourglass item on the right side of the menu bar."
echo "    Turn on \"Launch at login\" from its gear menu."
