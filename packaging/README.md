# Distribution

Two channels. A tag push builds and publishes the release; one command then points the tap at it. Every release carries the same version number in the
app's `Info.plist` and the cask, and the app checks GitHub once a day to offer the
next one.

| Channel | Command | Status |
|---|---|---|
| GitHub release | download zip | works |
| Homebrew tap | `brew tap LucasHyun/tap && brew trust lucashyun/tap && brew install --cask paperrush-bar` | works; the tap is updated with one command after each release (below) |
| Official homebrew-cask | `brew install --cask paperrush-bar` | blocked on notarization (below) |

## Your own tap

Create the repository once — the name must start with `homebrew-`:

```bash
gh repo create homebrew-tap --public --description "Homebrew tap for LucasHyun's tools"
```

The release workflow renders `paperrush-bar.rb` with the tag's version and SHA-256 and attaches it to
the release. Pointing the tap at it is one command, run after a release:

```bash
./packaging/update-tap.sh            # the latest release
./packaging/update-tap.sh v1.2.0     # a specific tag
```

It downloads that release's cask, commits it to the tap and pushes, using your own `gh` and `git`
credentials. Re-running it for a release the tap already has does nothing.

This deliberately stays out of CI. Automating it would mean a personal access token living as a
repository secret — something to create, scope, rotate and worry about leaking — to save one command
a few times a year, on a step where a human pausing to look is worth more than the automation.

Users install with:

```bash
brew tap LucasHyun/tap
brew trust lucashyun/tap
brew install --cask paperrush-bar
```

`brew trust` is required once per tap: Homebrew refuses to load a cask from a tap outside its own
repositories until the user says so.

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
gives exactly the same install command apart from one `brew tap` line.

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
