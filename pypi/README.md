# paperrush-bar

Installer for **[PaperRush Bar](https://github.com/LucasHyun/paperrush-bar)** — a native macOS menu
bar app that counts down to the next AI conference deadline (`⏳ ICLR D-5`), keeps itself current,
and turns red when it matters.

This package contains no app code. It is a ~150-line, dependency-free installer that fetches the
signed release archive from GitHub, verifies its SHA-256, and puts `PaperRushBar.app` in
`/Applications`. It exists because the people who want this app already live in `pip`, not in
Homebrew — and because a download made this way carries no quarantine flag, so macOS does not
stop you at first launch.

```bash
pip install paperrush-bar
paperrush-bar install
```

or without touching your environment:

```bash
uvx paperrush-bar install        # or: pipx run paperrush-bar install
```

Other commands:

```bash
paperrush-bar status       # installed vs latest
paperrush-bar upgrade      # only if a newer release exists
paperrush-bar uninstall    # removes the app, cache and preferences
```

Requires macOS 13 (Ventura) or newer. The app itself is Swift and needs nothing from Python once
installed; you can `pip uninstall paperrush-bar` afterwards and it keeps running.
