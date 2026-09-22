#!/bin/bash
# Copy a release's cask into the personal Homebrew tap.
#
# Run this after a release. It uses your own gh/git credentials, so there is no
# token to store, rotate or leak — the release workflow builds the cask, you
# decide when the tap points at it.
#
#   ./packaging/update-tap.sh            # the latest release
#   ./packaging/update-tap.sh v1.2.0     # a specific tag
set -euo pipefail

REPO="${REPO:-LucasHyun/paperrush-bar}"
TAP="${TAP:-LucasHyun/homebrew-tap}"
CASK="paperrush-bar.rb"
TAG="${1:-}"

if ! command -v gh >/dev/null 2>&1; then
	echo "ERROR: the gh CLI is required (brew install gh, then gh auth login)."
	exit 1
fi

if [ -z "${TAG}" ]; then
	TAG="$(gh release view --repo "${REPO}" --json tagName -q .tagName)"
fi
echo "==> ${REPO} ${TAG} -> ${TAP}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

if ! gh release download "${TAG}" --repo "${REPO}" --pattern "${CASK}" --dir "${WORK}" --clobber; then
	echo "ERROR: release ${TAG} has no ${CASK} asset."
	echo "       Releases from before the cask was added need a re-run:"
	echo "       gh workflow run release.yml -f tag=${TAG}"
	exit 1
fi

git clone --quiet "https://github.com/${TAP}.git" "${WORK}/tap" || {
	echo "ERROR: could not clone ${TAP}. Create it once with:"
	echo "       gh repo create homebrew-tap --public"
	exit 1
}

# A brand-new tap is an empty repository: the clone has no branch checked out,
# so name one explicitly rather than committing onto a detached or unborn HEAD.
if git -C "${WORK}/tap" rev-parse --verify --quiet origin/main >/dev/null; then
	git -C "${WORK}/tap" checkout -q -B main origin/main
else
	git -C "${WORK}/tap" checkout -q -b main
fi

mkdir -p "${WORK}/tap/Casks"
cp "${WORK}/${CASK}" "${WORK}/tap/Casks/${CASK}"

cd "${WORK}/tap"
if [ -z "$(git status --porcelain)" ]; then
	echo "==> tap already has ${TAG}, nothing to do"
	exit 0
fi

git add "Casks/${CASK}"
git commit -q -m "paperrush-bar ${TAG#v}"
# Explicit ref: a freshly created tap is empty and has no upstream branch yet.
git push --quiet origin HEAD:main
echo "==> pushed"
echo
echo "    brew update && brew install --cask paperrush-bar"
