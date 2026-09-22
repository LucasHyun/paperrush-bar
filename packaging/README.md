# Distribution

Three channels, all fed by the same tag push. Every release carries the same version number in the
app's `Info.plist`, the pip package and the cask, and the app checks GitHub once a day to offer the
next one.

| Channel | Command | Status |
|---|---|---|
| GitHub release | download zip | works |
| pip / uvx | `pip install paperrush-bar && paperrush-bar install` | works once PyPI is set up (below) |
| Homebrew tap | `brew tap LucasHyun/tap && brew install --cask paperrush-bar` | works once the tap repo exists (below) |
| Official homebrew-cask | `brew install --cask paperrush-bar` | blocked on notarization (below) |

## pip — the installer package

[`../pypi/`](../pypi/) is a dependency-free Python package whose only job is to fetch the release
zip, verify its SHA-256 against the published checksum, unpack it with `ditto` and open it. It is on
PyPI because the people who want this app already have `pip` and live in a terminal — and because a
download made through Python carries no quarantine flag, so macOS does not stop them at first launch.

The `pypi` job in `release.yml` publishes it on every tag using **trusted publishing** (no API token
in secrets). One-time setup on pypi.org, before the first tagged release:

1. Sign in → *Your account* → *Publishing* → **Add a new pending publisher**.
2. PyPI project name `paperrush-bar`, owner `LucasHyun`, repository `paperrush-bar`,
   workflow `release.yml`, environment `pypi`.
3. In the GitHub repo: *Settings → Environments → New environment* named `pypi` (no secrets needed).

The first publish claims the name; after that every tag updates it. `skip-existing` means a re-run
of an old tag is a no-op instead of a failure.

## Your own tap

Create the repository once — the name must start with `homebrew-`:

```bash
gh repo create homebrew-tap --public --description "Homebrew tap for LucasHyun's tools"
```

Then give the release workflow a way to push to it: a fine-grained personal access token scoped to
that one repository with *Contents: read and write*, stored in this repo as the secret `TAP_TOKEN`.
From then on every release copies the rendered cask into `Casks/paperrush-bar.rb` in the tap and
commits it. If the secret is absent the step is skipped, nothing else is affected.

Users install with:

```bash
brew tap LucasHyun/tap
brew install --cask paperrush-bar
```

and `brew upgrade --cask` follows the tap from there.

## The official homebrew-cask repository

`brew install --cask paperrush-bar` with no tap requires the cask to live in
[Homebrew/homebrew-cask](https://github.com/Homebrew/homebrew-cask). Two things stand between this
app and that, and the first is the hard one:

**1. Gatekeeper.** Acceptable Casks requires that "apps, installers and other executable artefacts
that Gatekeeper can assess must pass Homebrew's Gatekeeper checks". This app is **ad-hoc signed and
not notarized**, so it does not pass. Fixing that means a Developer ID certificate from the Apple
Developer Program (paid, yearly), signing the bundle with it, and submitting the zip to Apple's
notary service. That is a real change to `build.sh` and the release workflow, not a paperwork step.

**2. Notability.** Homebrew wants evidence that people beyond the author use the software. A newly
published repository with few stars is normally declined, though the policy allows further
consideration "when there is substantial, independently verifiable public interest".

So the honest order is: notarize first, gather users second, submit third. Until then the tap above
gives exactly the same install command apart from one `brew tap` line, and pip reaches the people
who never installed Homebrew at all.

## Updates

The app asks `api.github.com/repos/LucasHyun/paperrush-bar/releases/latest` once a day. When the tag
is newer than its own `CFBundleShortVersionString`, the gear icon fills in and the menu gains an
*Update available: x.y.z* item that opens the release page. `build.sh` stamps the version from the
`VERSION` environment variable (the workflow passes the tag) or the nearest git tag, so a local dev
build reports `0.0.0` and never nags.

## When the signing route is taken

Roughly what changes:

- `build.sh`: `codesign --sign "Developer ID Application: <name> (<team id>)" --options runtime --timestamp`
  instead of the ad-hoc `--sign -`.
- `release.yml`: import the certificate from a repository secret into a temporary keychain, sign,
  then `xcrun notarytool submit --wait` and `xcrun stapler staple` the app before zipping.
- The quarantine workaround in `install.sh` (`xattr -dr com.apple.quarantine`) becomes unnecessary.
