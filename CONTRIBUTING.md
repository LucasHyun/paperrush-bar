# Contributing

Thanks for taking a look. This is a small app on purpose — no Xcode project, no package manager,
one `swiftc` invocation. Please keep it that way.

## Build and run

```bash
./build.sh              # produces build/PaperRushBar.app
open build/PaperRushBar.app
```

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).
`./install.sh` copies the app into `/Applications`; `./uninstall.sh` removes it along with its
preferences and cache.

While iterating, `pkill -x PaperRushBar` before rebuilding so the old instance releases its menu bar slot.

## Where things live

| File | Responsibility |
|---|---|
| `Sources/Models.swift` | Data model, date parsing, categories |
| `Sources/Store.swift` | Networking, cache, favorites, notifications, login item |
| `Sources/L10n.swift` | Every user-facing string, in every language |
| `Sources/MenuView.swift` | The dropdown UI |
| `Sources/App.swift` | `MenuBarExtra` entry point, app delegate |

## Adding or fixing a translation

Everything is in `Sources/L10n.swift`.

1. Add a case to `AppLanguage` and to `Lang`, and give `Lang.localeIdentifier` a value
   (this also drives date formatting).
2. Add your language's column to every row of the `table` dictionary.
3. Optionally extend `deadlineLabels` — those are the English deadline names from the upstream
   dataset; anything you don't translate simply stays in English.

Keep strings short: the panel is 400 pt wide and the menu bar title has to stay unobtrusive.

## Conference data

The app does not contain deadlines — it downloads them from
[awsaf49/paperrush](https://github.com/awsaf49/paperrush). Wrong dates or missing conferences should
be reported and fixed there; this repository only needs a change if the *format* of `js/data.js`
changes, or if a deadline type is being displayed badly.

`Resources/conferences.json` is only a first-launch snapshot. Refresh it with:

```bash
curl -sL https://raw.githubusercontent.com/awsaf49/paperrush/main/js/data.js -o /tmp/data.js
python3 - <<'PY'
import json
js = open('/tmp/data.js').read()
i = js.index('{', js.index('CONFERENCES_DATA'))
obj, _ = json.JSONDecoder().raw_decode(js[i:])
json.dump(obj, open('Resources/conferences.json', 'w'), ensure_ascii=False, indent=1)
PY
```

## Pull requests

- One topic per PR, and a short description of what you observed before and after.
- UI changes: please attach a screenshot of the dropdown (light and dark mode if you touched colors).
- CI builds the app on macOS; make sure `./build.sh` is clean before pushing.
- By contributing you agree your work is released under the MIT license.
