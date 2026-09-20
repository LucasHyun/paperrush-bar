<div align="center">

# PaperRush Bar ⏳

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
| **Menu bar countdown** | The nearest submission deadline as `ICLR D-5`, updated as the day rolls over |
| **Daily auto-update** | Checks every 30 min, re-downloads when the data is older than 6 h, and refreshes on wake |
| **Offline-friendly** | Last payload cached in Application Support; a snapshot ships inside the app for first launch |
| **D-7 / D-3 / D-1 alerts** | Native notifications at 09:00 — off / favorites / all |
| **Favorites** | Star a conference to pin it to the top, and optionally limit the menu bar and alerts to starred ones |
| **Click to open** | Any row opens the conference's official site |
| **Extra conferences** | 12 venues upstream doesn't cover yet, merged in locally — plus your own, in a file you can edit |
| **Launch at login** | One toggle, via `SMAppService` |
| **3 languages** | English · 한국어 · 中文, switchable live from the gear menu (follows system language by default) |

## Install

```bash
git clone https://github.com/LucasHyun/paperrush-bar.git
cd paperrush-bar
./build.sh && ./install.sh
```

Requirements: **macOS 13 (Ventura) or newer** and Xcode Command Line Tools
(`xcode-select --install` if `swiftc` is missing). There is no Xcode project and no package manager —
`build.sh` calls `swiftc` once and assembles the `.app` bundle itself.

Remove everything with `./uninstall.sh`.

> The build is ad-hoc signed (`codesign --sign -`), which is what notifications and the login item need.
> macOS may still ask you to confirm the first launch since there is no Developer ID signature.

## How it works

```
Sources/
├─ Models.swift    Conference & deadline models, date parsing, categories
├─ Store.swift     Download, cache, favorites, notification scheduling, login item
├─ L10n.swift      In-app translations (en / ko / zh) + localized date formats
├─ MenuView.swift  Dropdown UI: search, filters, list, settings
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

**Bundled** (`Resources/extras.json`, marked `Added` in the list): WWW, WSDM, ICDM, CIKM, ECML PKDD,
SIGIR, RecSys, COLM, UAI, ACM MM, AAMAS, ECAI. Dates that the next edition's CFP hasn't announced yet
are inferred from the previous cycle and carry an `Est.` badge — they are never presented as confirmed.

**Yours**: gear menu → *Added conferences* creates and reveals
`~/Library/Application Support/PaperRushBar/extras.json`. Same schema; it's re-read on every refresh,
so a save and a click on ↻ is the whole loop.

If a deadline is wrong or a conference is missing for everyone, the fix belongs upstream in
[awsaf49/paperrush](https://github.com/awsaf49/paperrush). [`upstream/`](upstream/) holds a ready
draft of that contribution for the twelve above. To point the app at your own fork instead, change
`Store.sourceURL`.

## License

[MIT](LICENSE). Conference data belongs to the paperrush project and its contributors.
