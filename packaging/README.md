# Homebrew

[`Casks/paperrush-bar.rb`](Casks/paperrush-bar.rb) is the cask. The release workflow renders a copy
with the real `version` and `sha256` filled in and attaches it to each GitHub release, so the file
here is the template and the release asset is the one to ship.

## Your own tap — works today

```bash
gh repo create homebrew-tap --public --clone     # once; the name must start with "homebrew-"
cd homebrew-tap && mkdir -p Casks
gh release download v1.2.0 --repo LucasHyun/paperrush-bar --pattern 'paperrush-bar.rb' --dir Casks
git add Casks && git commit -m "paperrush-bar 1.2.0" && git push
```

Then anyone installs with:

```bash
brew tap LucasHyun/tap
brew install --cask paperrush-bar
```

On each release, download the rendered cask into the tap again and push. `brew upgrade --cask` picks
it up from there.

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

## When the signing route is taken

Roughly what changes:

- `build.sh`: `codesign --sign "Developer ID Application: <name> (<team id>)" --options runtime --timestamp`
  instead of the ad-hoc `--sign -`.
- `release.yml`: import the certificate from a repository secret into a temporary keychain, sign,
  then `xcrun notarytool submit --wait` and `xcrun stapler staple` the app before zipping.
- The quarantine workaround in `install.sh` (`xattr -dr com.apple.quarantine`) becomes unnecessary.
