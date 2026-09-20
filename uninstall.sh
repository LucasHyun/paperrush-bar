#!/bin/bash
# Removes the app along with its cache and preferences.
set -euo pipefail

APP_NAME="PaperRushBar"
pkill -x "${APP_NAME}" 2>/dev/null || true
rm -rf "/Applications/${APP_NAME}.app"
rm -rf "${HOME}/Library/Application Support/PaperRushBar"
defaults delete com.lucashyun.paperrushbar 2>/dev/null || true
echo "==> Removed (including favorites and settings)"
