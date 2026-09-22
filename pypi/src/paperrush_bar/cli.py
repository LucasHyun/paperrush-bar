"""Install, upgrade and remove PaperRush Bar from the terminal.

    paperrush-bar install [--version 1.2.0] [--dest DIR]
    paperrush-bar upgrade
    paperrush-bar status
    paperrush-bar uninstall

Standard library only, so it runs inside whatever environment is active.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

REPO = "LucasHyun/paperrush-bar"
APP_NAME = "PaperRushBar"
BUNDLE_ID = "com.lucashyun.paperrushbar"
API = f"https://api.github.com/repos/{REPO}/releases"
USER_AGENT = "paperrush-bar-installer (+https://github.com/LucasHyun/paperrush-bar)"
MIN_MACOS = 13


class InstallError(Exception):
    pass


# --------------------------------------------------------------------------- helpers

def say(msg: str) -> None:
    print(f"  {msg}")


def fail(msg: str, code: int = 1) -> int:
    print(f"error: {msg}", file=sys.stderr)
    return code


def require_macos() -> None:
    if sys.platform != "darwin":
        raise InstallError("PaperRush Bar is a macOS menu bar app; this machine is not running macOS.")
    major = platform.mac_ver()[0].split(".")[0]
    if major and int(major) < MIN_MACOS:
        raise InstallError(f"macOS {MIN_MACOS} (Ventura) or newer is required; this is {platform.mac_ver()[0]}.")


def get_json(url: str) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise InstallError("release not found") from e
        if e.code == 403:
            raise InstallError("GitHub API rate limit hit; try again in a few minutes") from e
        raise InstallError(f"GitHub returned HTTP {e.code}") from e
    except urllib.error.URLError as e:
        raise InstallError(f"could not reach GitHub: {e.reason}") from e


def download(url: str, dest: Path) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=60) as r, open(dest, "wb") as f:
        total = int(r.headers.get("Content-Length") or 0)
        done = 0
        while True:
            chunk = r.read(1 << 16)
            if not chunk:
                break
            f.write(chunk)
            done += len(chunk)
            if total and sys.stdout.isatty():
                print(f"\r  downloading {done * 100 // total:3d}%", end="", flush=True)
        if total and sys.stdout.isatty():
            print()


def parse_version(v: str) -> tuple:
    parts = []
    for piece in v.lstrip("v").split("."):
        digits = "".join(ch for ch in piece if ch.isdigit())
        parts.append(int(digits) if digits else 0)
    return tuple(parts)


def release(version: str | None) -> dict:
    return get_json(f"{API}/tags/v{version.lstrip('v')}" if version else f"{API}/latest")


def asset_url(rel: dict, suffix: str) -> str:
    for a in rel.get("assets", []):
        if a["name"].startswith(f"{APP_NAME}-") and a["name"].endswith(suffix):
            return a["browser_download_url"]
    raise InstallError(f"release {rel.get('tag_name')} has no *{suffix} asset")


def app_dirs() -> list[Path]:
    return [Path("/Applications"), Path.home() / "Applications"]


def installed_app() -> Path | None:
    for d in app_dirs():
        p = d / f"{APP_NAME}.app"
        if p.exists():
            return p
    return None


def installed_version(app: Path) -> str | None:
    try:
        with open(app / "Contents" / "Info.plist", "rb") as f:
            return plistlib.load(f).get("CFBundleShortVersionString")
    except Exception:
        return None


def quit_app() -> None:
    subprocess.run(["pkill", "-x", APP_NAME], check=False, capture_output=True)


# --------------------------------------------------------------------------- commands

def cmd_install(version: str | None, dest: Path | None, force: bool) -> int:
    require_macos()
    rel = release(version)
    tag = rel["tag_name"]
    current = installed_app()
    if current and not force:
        have = installed_version(current)
        if have and parse_version(have) >= parse_version(tag):
            say(f"{APP_NAME} {have} is already installed at {current} (latest is {tag}).")
            say("Use `paperrush-bar install --force` to reinstall.")
            return 0

    zip_url = asset_url(rel, ".zip")
    sha_url = asset_url(rel, ".zip.sha256")
    say(f"{APP_NAME} {tag}")

    target_dir = dest or (current.parent if current else None)
    if target_dir is None:
        target_dir = next((d for d in app_dirs() if os.access(d, os.W_OK)), None)
        if target_dir is None:
            target_dir = Path.home() / "Applications"
            target_dir.mkdir(exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        zip_path = tmp / "app.zip"
        download(zip_url, zip_path)

        # Verify against the checksum published with the release.
        expected = get_text(sha_url).split()[0].lower()
        actual = hashlib.sha256(zip_path.read_bytes()).hexdigest()
        if actual != expected:
            raise InstallError("checksum mismatch - the download does not match the release; nothing was installed")
        say("checksum verified")

        # `ditto` keeps symlinks, resource forks and permissions inside the bundle,
        # which Python's zipfile does not.
        extracted = tmp / "out"
        subprocess.run(["ditto", "-x", "-k", str(zip_path), str(extracted)], check=True)
        bundle = extracted / f"{APP_NAME}.app"
        if not bundle.exists():
            raise InstallError("archive did not contain the app bundle")

        quit_app()
        final = target_dir / f"{APP_NAME}.app"
        if final.exists():
            shutil.rmtree(final)
        shutil.move(str(bundle), str(final))

    # Nothing here should have set a quarantine flag, but a download is a download.
    subprocess.run(["xattr", "-dr", "com.apple.quarantine", str(final)], check=False, capture_output=True)
    subprocess.run(["open", str(final)], check=False)
    say(f"installed to {final}")
    say("Look for the hourglass in the menu bar. Turn on \"Launch at login\" from its gear menu.")
    return 0


def get_text(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read().decode("utf-8", "replace")


def cmd_upgrade() -> int:
    require_macos()
    current = installed_app()
    if not current:
        say("not installed; run `paperrush-bar install`")
        return 1
    have = installed_version(current) or "0"
    rel = release(None)
    if parse_version(have) >= parse_version(rel["tag_name"]):
        say(f"up to date ({have})")
        return 0
    say(f"{have} -> {rel['tag_name']}")
    return cmd_install(None, current.parent, force=True)


def cmd_status() -> int:
    current = installed_app()
    if current:
        say(f"installed: {installed_version(current) or '?'}  ({current})")
    else:
        say("installed: no")
    try:
        say(f"latest:    {release(None)['tag_name']}")
    except InstallError as e:
        say(f"latest:    unknown ({e})")
    return 0


def cmd_uninstall() -> int:
    require_macos()
    quit_app()
    removed = []
    current = installed_app()
    if current:
        shutil.rmtree(current, ignore_errors=True)
        removed.append(str(current))
    support = Path.home() / "Library" / "Application Support" / APP_NAME
    if support.exists():
        shutil.rmtree(support, ignore_errors=True)
        removed.append(str(support))
    subprocess.run(["defaults", "delete", BUNDLE_ID], check=False, capture_output=True)
    for r in removed:
        say(f"removed {r}")
    if not removed:
        say("nothing to remove")
    return 0


# --------------------------------------------------------------------------- main

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="paperrush-bar", description="Install PaperRush Bar, the menu bar countdown to AI conference deadlines.")
    sub = p.add_subparsers(dest="cmd")
    i = sub.add_parser("install", help="download the latest release into /Applications")
    i.add_argument("--version", help="a specific release, e.g. 1.2.0")
    i.add_argument("--dest", type=Path, help="install directory (default: /Applications, else ~/Applications)")
    i.add_argument("--force", action="store_true", help="reinstall even if this version is present")
    sub.add_parser("upgrade", help="install the latest release if it is newer than the installed one")
    sub.add_parser("status", help="show installed and latest versions")
    sub.add_parser("uninstall", help="remove the app, its cache and preferences")
    args = p.parse_args(argv)

    try:
        if args.cmd in (None, "install"):
            return cmd_install(getattr(args, "version", None), getattr(args, "dest", None), getattr(args, "force", False))
        if args.cmd == "upgrade":
            return cmd_upgrade()
        if args.cmd == "status":
            return cmd_status()
        if args.cmd == "uninstall":
            return cmd_uninstall()
    except InstallError as e:
        return fail(str(e))
    except subprocess.CalledProcessError as e:
        return fail(f"{e.cmd[0]} failed with exit code {e.returncode}")
    except KeyboardInterrupt:
        return fail("interrupted", 130)
    return 0


if __name__ == "__main__":
    sys.exit(main())
