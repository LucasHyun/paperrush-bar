#!/bin/bash
# Point the personal Homebrew tap at a release.
#
# The cask is rendered here from packaging/Casks/paperrush-bar.rb, using the
# release's own checksum, rather than copied from the asset the release built.
# A fix to the template therefore reaches the tap on the next run, without
# waiting for another release.
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
TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Casks/${CASK}"
TAG="${1:-}"

if ! command -v gh >/dev/null 2>&1; then
	echo "ERROR: the gh CLI is required (brew install gh, then gh auth login)."
	exit 1
fi

if [ ! -f "${TEMPLATE}" ]; then
	echo "ERROR: cask template not found at ${TEMPLATE}"
	exit 1
fi

if [ -z "${TAG}" ]; then
	TAG="$(gh release view --repo "${REPO}" --json tagName -q .tagName)"
fi
echo "==> ${REPO} ${TAG} -> ${TAP}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

if ! gh release download "${TAG}" --repo "${REPO}" \
	--pattern "PaperRushBar-${TAG}.zip.sha256" --dir "${WORK}" --clobber; then
	echo "ERROR: release ${TAG} has no checksum asset."
	echo "       Releases from before the cask was added need a re-run:"
	echo "       gh workflow run release.yml -f tag=${TAG}"
	exit 1
fi

SHA="$(cut -d' ' -f1 "${WORK}/PaperRushBar-${TAG}.zip.sha256")"
if [ "${#SHA}" -ne 64 ]; then
	echo "ERROR: ${TAG} checksum does not look like a sha256: ${SHA}"
	exit 1
fi

# Same substitution the release workflow does, so the two never drift.
sed -e "s/^  version \".*\"/  version \"${TAG#v}\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"${SHA}\"/" \
    "${TEMPLATE}" > "${WORK}/${CASK}"

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
