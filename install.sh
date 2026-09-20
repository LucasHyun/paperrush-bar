#!/bin/bash
# Copies the built app into /Applications and launches it.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="PaperRushBar"
SRC="build/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [ ! -d "${SRC}" ]; then
	echo "Run ./build.sh first."
	exit 1
fi

# "Launch at login" only sticks if the app lives in a stable location.
pkill -x "${APP_NAME}" 2>/dev/null || true
rm -rf "${DEST}"
cp -R "${SRC}" "${DEST}"
xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true

# Replacing a bundle in place leaves a stale LaunchServices record, which makes
# `open` fail with -600. Re-register before launching.
[ -x "${LSREGISTER}" ] && "${LSREGISTER}" -f "${DEST}" >/dev/null 2>&1 || true

echo "==> Installed to ${DEST}"

if open "${DEST}" 2>/dev/null; then
	echo "    Look for the hourglass item on the right side of the menu bar."
else
	echo "    'open' was refused (this happens over SSH or with a stale Launch Services record)."
	echo "    Starting the binary directly instead."
	"${DEST}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1 &
	disown
	sleep 1
	if pgrep -x "${APP_NAME}" >/dev/null; then
		echo "    Running. Look for the hourglass item in the menu bar."
	else
		echo "    Could not start it. Run this to see why:"
		echo "      ${DEST}/Contents/MacOS/${APP_NAME}"
	fi
fi

echo "    Turn on \"Launch at login\" from its gear menu."
