<div align="center">

<img src="Resources/AppIcon.iconset/icon_256x256.png" width="120" alt="PaperRush Bar">

# PaperRush Bar

**AI conference deadlines, live in your macOS menu bar.**

`⏳ ICLR D-5` — always visible, always current, no browser tab required.

English · [한국어](README.ko.md) · [中文](README.zh.md)

![platform](https://img.shields.io/badge/macOS-13%2B-black)
![language](https://img.shields.io/badge/Swift-5-orange)
![license](https://img.shields.io/badge/license-MIT-blue)

</div>

---

## What it does

A tiny native menu bar app (no Electron, no Python, ~1 MB) that shows the countdown to your next
AI/ML conference submission deadline and keeps itself up to date in the background.

Deadline data comes from [**awsaf49/paperrush**](https://github.com/awsaf49/paperrush), which refreshes
its dataset through GitHub Actions — so this app follows upstream automatically, with nothing to maintain.

| | |
|---|---|
| **Menu bar countdown** | The nearest submission deadline as `ICLR D-5`; the hourglass's sand level shows how much of the last 30 days is left and turns yellow → orange → red from D-7, one grain falls when the day rolls over, and within D-3 the sand trickles on its own, faster as the deadline nears, with a restless little shake from D-1 (honours Reduce Motion) |
| **Daily auto-update** | Checks every 30 min, re-downloads when the data is older than 6 h, and refreshes on wake |
| **Offline-friendly** | Last payload cached in Application Support; a snapshot ships inside the app for first launch |
| **D-7 / D-3 / D-1 alerts** | Native notifications at 09:00 — off / favorites / all |
| **Favorites** | Star a conference to pin it to the top, and optionally limit the menu bar and alerts to starred ones |
| **Click to open** | Any row opens the conference's official site |
| **Extra conferences** | 18 venues upstream doesn't cover plus 7 it covers only partly, re-read from their own CFPs weekly — and your own, in a file you can edit |
| **Launch at login** | One toggle, via `SMAppService` |
| **3 languages** | English · 한국어 · 中文, switchable live from the gear menu (follows system language by default) |

## Install

```bash
brew tap LucasHyun/tap
brew trust lucashyun/tap
brew install --cask paperrush-bar
```

Homebrew asks you to trust any tap outside its own repositories before it will load a cask from
it - that is the middle line, and it is asked once per tap.

`brew upgrade --cask paperrush-bar` later — though the app also tells you itself when a new release
is out. Or download `PaperRushBar-vX.zip` from [Releases](https://github.com/LucasHyun/paperrush-bar/releases)
and drop the app into `/Applications` (right-click → Open the first time; the build is not notarized).

From source, with Xcode Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/LucasHyun/paperrush-bar.git
cd paperrush-bar
./build.sh && ./install.sh
```

There is no Xcode project and no package manager — `build.sh` calls `swiftc` once and assembles the
`.app` itself. Requires **macOS 13 (Ventura) or newer**. Remove with `./uninstall.sh` or
`brew uninstall --cask paperrush-bar`. How the channels are wired up is in [`packaging/`](packaging/README.md).

> The build is ad-hoc signed (`codesign --sign -`), which is what notifications and the login item need.
> macOS may still ask you to confirm the first launch since there is no Developer ID signature.

## How it works

```
Sources/
├─ Models.swift    Conference & deadline models, date parsing, categories
├─ Store.swift     Download, cache, favorites, notification scheduling, login item
├─ L10n.swift      In-app translations (en / ko / zh) + localized date formats
├─ MenuView.swift  Dropdown UI: search, filters, list, settings
├─ HourglassIcon.swift  Menu bar glyph drawn at runtime, sand level = time left
└─ App.swift       MenuBarExtra entry point
Resources/conferences.json   Offline snapshot for the very first launch
Info.plist                   LSUIElement = true (no Dock icon)
```

**Parsing `js/data.js`.** Upstream ships a JavaScript file, not JSON: `const CONFERENCES_DATA = {…};`
is followed by a `CATEGORIES` object and a `module.exports` block. `Store.extractJSONObject` walks the
text counting brace depth while skipping string literals and escapes, so exactly one object comes out —
currently 31 conferences and 225 deadlines, all parsed.

**Dates.** Two shapes appear in the feed: full ISO with an offset (`2026-09-25T23:59:00-12:00` — AoE
deadlines use `-12:00`) and date-only (`2027-04-06`, treated as 23:59 local). The D-day number is a
calendar-day difference in your local time zone, so it flips exactly at midnight.

**Notification budget.** macOS caps pending local notifications, so the app schedules the 20 nearest
submission deadlines × 3 reminders and recomputes the set on every data refresh.

## Adding a language

All strings live in one table in `Sources/L10n.swift`. To add a language: add a case to `AppLanguage`
and `Lang`, give it a locale identifier, and fill in the column. Nothing else in the app needs to change —
pull requests welcome.

## Conference data

Deadlines come from upstream. On top of that, the app merges an overlay so gaps in the dataset don't
mean waiting for a PR to land:

```
bundled extras.json  <  your extras.json  <  upstream paperrush
```

Upstream always wins on a shared `id`, so an overlay entry retires itself the moment paperrush ships
the same conference — nothing to clean up, no stale duplicate.

**The overlay** (marked `Added` in the list) holds 18 conferences upstream doesn't have — WWW, WSDM,
ICDM, CIKM, ECML PKDD, SIGIR, RecSys, COLM, UAI, ACM MM, AAMAS, ECAI, and the next editions of NAACL,
INTERSPEECH, ICRA, WACV, AAAI and 3DV — plus 7 patches that fill in what upstream has only partly:
KDD's second cycle, ICASSP 2027's whole schedule, and the ARR commitment deadlines for ACL, EACL and
COLING, which is the date those venues actually gate on. Dates the next edition's CFP hasn't announced
yet are inferred from the previous cycle and carry an `Est.` badge — never presented as confirmed.

It keeps itself current. `scripts/update_extras.py` runs weekly in Actions (Mondays 06:30 UTC, just
after upstream's own job): it re-reads each deadline's `sourceUrl`, asks **Gemini 2.5 Flash** to
extract the schedule, and commits what it can verify. Estimates become confirmed dates on their own
as CFPs appear. The app reads the published `Resources/extras.json` over the network, so those
updates land without a rebuild; the copy inside the app is only the offline fallback.

Nothing goes in unverified: a proposed date is accepted only when its `sourceUrl` is one of the pages
actually fetched **and** the date is legible in that page's text; an unverified date leaves the
existing entry untouched rather than replacing it, and the model can never promote its own guess from
`Est.` to confirmed. Setup is one secret, `GEMINI_API_KEY`, under *Settings → Secrets and variables →
Actions*. Without it the job fails loudly and everything else keeps working.

```bash
export GEMINI_API_KEY=...
python scripts/update_extras.py --dry-run          # see what would change
python scripts/update_extras.py -c www,sigir       # just these two
```

**Patches**: an overlay entry with `"mode": "patch"` and an upstream `id` doesn't replace that
conference — it adds the deadlines upstream is missing. KDD runs two submission cycles a year and
upstream tracks only the first, so `kdd-2027` is patched with Cycle 2. A patched deadline drops out
automatically once upstream publishes the same milestone, matched by type and date (within 45 days,
for one we only estimated).

**Yours**: gear menu → *Added conferences* creates and reveals
`~/Library/Application Support/PaperRushBar/extras.json`. Same schema; it's re-read on every refresh,
so a save and a click on ↻ is the whole loop.

**Check it yourself**: gear menu -> *Verify deadlines with Gemini...* opens a page where you paste your
own Gemini API key. It is stored in the macOS keychain and sent only to Google; a free key from
[aistudio.google.com](https://aistudio.google.com/apikey) is enough for a scan. *Start scan* reads every
conference's own site and lists the dates that disagree with the data, each with the page it came from
and the old date struck through. Nothing changes until you press *Apply*.

The same rule as the weekly job holds here: a date is proposed only when its `sourceUrl` is a page the
app actually fetched and the date is legible in that page's text. Applied dates are marked `Verified`,
stay on this Mac, and are re-laid over the downloads on every refresh - but a correction remembers the
date it replaced and retires itself once the source moves on, so a date you approved months ago can
never bury a newer published one.

If a deadline is wrong or a conference is missing for everyone, the fix belongs upstream in
[awsaf49/paperrush](https://github.com/awsaf49/paperrush). [`upstream/`](upstream/) holds a ready
draft of that contribution. To point the app at your own fork instead, change
`Store.sourceURL`.

## License

[MIT](LICENSE). Conference data belongs to the paperrush project and its contributors.
