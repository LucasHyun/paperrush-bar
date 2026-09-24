#!/bin/bash
# Cut a release in the only order that works:
#   clean tree -> build -> push main -> tag that commit -> wait for the release
#   workflow -> point the Homebrew tap at it.
#
# Each step refuses to run until the one before it has actually happened. Tagging
# before the commit is pushed is the mistake this exists to stop: the tag lands on
# the previous commit and the release ships the old code under the new number.
#
#   ./packaging/release.sh v1.5.1
set -euo pipefail

REPO="${REPO:-LucasHyun/paperrush-bar}"
TAG="${1:-}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

[[ "${TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: $0 vX.Y.Z"
command -v gh >/dev/null 2>&1 || fail "the gh CLI is required (brew install gh, then gh auth login)."

step "Checking the working tree"
[ -z "$(git status --porcelain)" ] || {
	git status --short
	fail "there are uncommitted changes. Commit them first -- a tag only carries what is committed."
}
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || fail "release from main (you are on $(git rev-parse --abbrev-ref HEAD))."
git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null && fail "tag ${TAG} already exists locally."
git fetch -q origin --tags
git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1 && fail "tag ${TAG} already exists on GitHub."

step "Building ${TAG#v}"
VERSION="${TAG#v}" ./build.sh

step "Pushing main"
git push origin main
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "origin/main is not this commit after the push."

step "Tagging $(git rev-parse --short HEAD) as ${TAG}"
git tag -a "${TAG}" -m "${TAG}"
git push origin "${TAG}"

step "Waiting for the release workflow"
RUN=""
for _ in $(seq 1 30); do
	RUN="$(gh run list --repo "${REPO}" --workflow release.yml --branch "${TAG}" --limit 1 \
		--json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
	[ -n "${RUN}" ] && break
	sleep 2
done
[ -n "${RUN}" ] || fail "no release run appeared for ${TAG}. Check: gh run list --workflow release.yml"
gh run watch "${RUN}" --repo "${REPO}" --exit-status || fail "the release workflow failed: gh run view ${RUN} --log-failed"
gh release view "${TAG}" --repo "${REPO}" >/dev/null || fail "the workflow passed but release ${TAG} is missing."

step "Updating the Homebrew tap"
./packaging/update-tap.sh "${TAG}"

echo
echo "==> ${TAG} is out."
