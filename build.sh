#!/bin/bash
# Builds PaperRushBar.app. No Xcode project, no package manager - one swiftc call.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="PaperRushBar"
BUILD_DIR="build"
APP="${BUILD_DIR}/${APP_NAME}.app"

if ! command -v swiftc >/dev/null 2>&1; then
	echo "ERROR: swiftc not found."
	echo "       Install the Xcode Command Line Tools first:  xcode-select --install"
	exit 1
fi

MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
if [ "${MACOS_MAJOR}" -lt 13 ]; then
	echo "ERROR: macOS 13 (Ventura) or newer is required. Found: ${MACOS_VERSION}"
	exit 1
fi

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos13.0"

echo "==> Building for ${TARGET}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

swiftc \
	-O \
	-swift-version 5 \
	-parse-as-library \
	-target "${TARGET}" \
	-framework SwiftUI -framework AppKit -framework UserNotifications -framework ServiceManagement \
	Sources/*.swift \
	-o "${APP}/Contents/MacOS/${APP_NAME}"

cp Info.plist "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# Stamp the version: VERSION env if set (the release workflow passes the tag),
# else the nearest git tag, else a dev marker. The in-app update check and the
# pip installer both compare against this.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${APP}/Contents/Info.plist"
echo "    version ${VERSION}"
for RESOURCE in conferences.json extras.json; do
	if [ -f "Resources/${RESOURCE}" ]; then
		cp "Resources/${RESOURCE}" "${APP}/Contents/Resources/${RESOURCE}"
	fi
done

# The icon is kept as PNGs in git and compiled here, so no binary blob is committed.
# It has no Dock presence (LSUIElement) but shows in Finder, notifications and Login Items.
if [ -d "Resources/AppIcon.iconset" ] && command -v iconutil >/dev/null 2>&1; then
	iconutil --convert icns "Resources/AppIcon.iconset" --output "${APP}/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature: notifications and the login item need the bundle to be signed.
if ! codesign --force --deep --sign - "${APP}" >/dev/null 2>&1; then
	echo "WARNING: ad-hoc signing failed (usually harmless)"
fi

echo "==> Built $(pwd)/${APP}"
echo "    Install to /Applications:  ./install.sh"
echo "    Or just run it:            open \"${APP}\""
