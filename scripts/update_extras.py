#!/usr/bin/env python3
"""Refresh Resources/extras.json from the conferences' own pages using Gemini.

The overlay is hand-written, which means its estimated dates go stale the moment a
CFP is published. This re-reads each deadline's `sourceUrl` (plus the conference's
official site), asks Gemini to extract the current schedule, and writes back only
what it can verify.

Conventions follow upstream paperrush (gemini-2.5-flash, GEMINI_API_KEY), so this
stays easy to port there.

    pip install -r scripts/requirements.txt
    export GEMINI_API_KEY=...
    python scripts/update_extras.py --dry-run
    python scripts/update_extras.py --conferences www,sigir
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from html.parser import HTMLParser
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parent.parent
EXTRAS = ROOT / "Resources" / "extras.json"

MODEL = "gemini-2.5-flash"
USER_AGENT = "PaperRushBar-extras-updater/1.0 (+https://github.com/LucasHyun/paperrush-bar)"

PAGE_CHAR_LIMIT = 18_000
TOTAL_CHAR_LIMIT = 60_000
FETCH_TIMEOUT = 20

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2}))?$")
TYPES = {"abstract", "paper", "supplementary", "rebuttal", "notification",
         "camera", "conference", "workshop", "tutorial", "event"}
MONTHS = ["January", "February", "March", "April", "May", "June",
          "July", "August", "September", "October", "November", "December"]


# --------------------------------------------------------------------------- fetch

class _TextExtractor(HTMLParser):
    SKIP = {"script", "style", "noscript", "svg"}

    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []
        self._skip_depth = 0

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self._skip_depth += 1

    def handle_endtag(self, tag):
        if tag in self.SKIP and self._skip_depth:
            self._skip_depth -= 1

    def handle_data(self, data):
        if not self._skip_depth:
            text = data.strip()
            if text:
                self.parts.append(text)


def page_text(html: str) -> str:
    parser = _TextExtractor()
    try:
        parser.feed(html)
    except Exception:
        pass
    return re.sub(r"\n{3,}", "\n\n", "\n".join(parser.parts))


BINARY_HINTS = ("pdf", "image/", "octet-stream", "zip", "font")
MIN_USEFUL_CHARS = 200


def fetch(url: str) -> str | None:
    """Page text, or None with a reason printed. Never raises."""
    try:
        response = requests.get(url, timeout=FETCH_TIMEOUT, headers={"User-Agent": USER_AGENT})
    except requests.RequestException as error:
        print(f"  unreachable {url}  ({type(error).__name__})")
        return None

    if response.status_code != 200:
        print(f"  HTTP {response.status_code} {url}")
        return None

    content_type = response.headers.get("content-type", "").lower()
    if any(hint in content_type for hint in BINARY_HINTS):
        print(f"  skipped {url}  ({content_type.split(';')[0]})")
        return None

    text = page_text(response.text)[:PAGE_CHAR_LIMIT]
    if len(text) < MIN_USEFUL_CHARS:
        # Usually a client-rendered page: the dates exist, but only after JS runs.
        print(f"  too little text at {url}  ({len(text)} chars, likely JS-rendered)")
        return None
    return text


def source_urls(conference: dict) -> list[str]:
    """Every page that might state this conference's dates, best first."""
    urls: list[str] = []
    for deadline in conference.get("deadlines", []):
        if deadline.get("sourceUrl"):
            urls.append(deadline["sourceUrl"])
    for key in ("official", "dates", "submission", "authorGuide"):
        if conference.get("links", {}).get(key):
            urls.append(conference["links"][key])
    if conference.get("website"):
        urls.append(conference["website"])
    seen, ordered = set(), []
    for url in urls:
        if url not in seen and url.startswith("http"):
            seen.add(url)
            ordered.append(url)
    return ordered


# --------------------------------------------------------------------------- verify

def date_is_on_page(date: str, text: str) -> bool:
    """A date we accept has to be legible on the page we cite, in some common spelling.

    Guards against the model confidently inventing a plausible deadline, which is the
    one failure this tool must not have.
    """
    year, month, day = date[:4], int(date[5:7]), int(date[8:10])
    if year not in text:
        return False
    name = MONTHS[month - 1]
    spellings = [
        f"{name} {day}", f"{name} {day:02d}", f"{name[:3]} {day}", f"{name[:3]}. {day}",
        f"{day} {name}", f"{day} {name[:3]}",
        f"{month}/{day}/{year}", f"{month:02d}/{day:02d}/{year}",
        f"{year}-{month:02d}-{day:02d}", f"{day}.{month}.{year}", f"{day:02d}.{month:02d}.{year}",
    ]
    lowered = text.lower()
    return any(s.lower() in lowered for s in spellings)


def valid_deadline(deadline: dict, allowed_urls: set[str]) -> str | None:
    """Returns an error string, or None when the deadline is usable."""
    for key in ("type", "label", "date", "sourceUrl"):
        if not deadline.get(key):
            return f"missing {key}"
    if deadline["type"] not in TYPES:
        return f"type {deadline['type']}"
    if not DATE_RE.match(deadline["date"]):
        return f"date {deadline['date']}"
    if deadline.get("endDate") and not DATE_RE.match(deadline["endDate"]):
        return f"endDate {deadline['endDate']}"
    if deadline["sourceUrl"] not in allowed_urls:
        return f"sourceUrl not among the fetched pages: {deadline['sourceUrl']}"
    return None


# --------------------------------------------------------------------------- model

PROMPT = """You are reading the official pages of one academic conference and extracting its schedule.

Today is {today}.

Here is the entry we currently hold for it:

```json
{current}
```

Here are the pages, as plain text:

{pages}

Return JSON only, shaped exactly like this:

{{
  "deadlines": [
    {{
      "type": "abstract|paper|supplementary|rebuttal|notification|camera|conference|workshop|tutorial|event",
      "label": "Paper Submission",
      "date": "2027-02-08T23:59:00-12:00",
      "endDate": null,
      "status": "upcoming",
      "estimated": false,
      "timeUnknown": false,
      "sourceUrl": "<the exact URL of the page this date is printed on>"
    }}
  ],
  "location": {{"city": "...", "country": "...", "flag": "<emoji>", "venue": null}},
  "website": "https://...",
  "notes": ["at most two short factual sentences"]
}}

Rules:
- Only report a date that is printed on one of the pages above, and set `sourceUrl` to that page's
  URL exactly as given. Never carry a date over from your own knowledge.
- Anywhere on Earth (AoE) means a -12:00 offset. Use the real offset when one is stated.
- When a date has no time of day, write it as "YYYY-MM-DD" and set "timeUnknown": true.
- Set "estimated": false for a date printed on the page. If a date in the current entry is marked
  estimated and the pages do not confirm it, keep it as it is, still marked estimated.
- Keep the deadlines from the current entry that the pages neither confirm nor replace.
- Cover the conference's own cycles: if it has two submission cycles, report both, and say which is
  which in each label, e.g. "Paper Submission (Cycle 2)".
- `notes` should say what is still unannounced, or what changed. Do not repeat the dates in it.
"""


def ask_gemini(client, conference: dict, pages: dict[str, str], today: str) -> dict | None:
    from google.genai import types

    rendered = []
    budget = TOTAL_CHAR_LIMIT
    for url, text in pages.items():
        chunk = text[:budget]
        budget -= len(chunk)
        rendered.append(f"--- PAGE: {url} ---\n{chunk}")
        if budget <= 0:
            break

    current = json.dumps(
        {k: conference[k] for k in ("id", "name", "year", "website", "location", "deadlines") if k in conference},
        ensure_ascii=False, indent=1,
    )
    prompt = PROMPT.format(today=today, current=current, pages="\n\n".join(rendered))

    config = types.GenerateContentConfig(
        temperature=0.1,
        max_output_tokens=16384,
        response_mime_type="application/json",
    )
    for attempt in range(3):
        try:
            response = client.models.generate_content(
                model=MODEL,
                contents=[types.Content(role="user", parts=[types.Part.from_text(text=prompt)])],
                config=config,
            )
            text = (response.text or "").strip()
            text = re.sub(r"^```json?\s*\n?", "", text)
            text = re.sub(r"\n?```\s*$", "", text)
            return json.loads(text)
        except Exception as error:  # transient API or JSON trouble
            print(f"    model attempt {attempt + 1} failed: {error}")
            time.sleep(2 * (attempt + 1))
    return None


# --------------------------------------------------------------------------- merge

def days_between(a: str, b: str) -> int:
    from datetime import date
    return abs((date.fromisoformat(a[:10]) - date.fromisoformat(b[:10])).days)


def supersedes(confirmed: list[dict], estimate: dict) -> bool:
    """True when a confirmed deadline is obviously the same milestone as this estimate."""
    return any(d["type"] == estimate["type"] and days_between(d["date"], estimate["date"]) < 45
               for d in confirmed)


def merge_conference(conference: dict, proposal: dict, pages: dict[str, str]) -> tuple[dict, list[str]]:
    """Apply a proposal on top of the current entry, keeping anything unverified."""
    log: list[str] = []
    allowed = set(pages)
    existing = {(d["type"], d["label"]): d for d in conference["deadlines"]}
    accepted: dict[tuple[str, str], dict] = {}

    for candidate in proposal.get("deadlines", []) or []:
        problem = valid_deadline(candidate, allowed)
        if problem:
            log.append(f"rejected '{candidate.get('label', '?')}': {problem}")
            continue

        key = (candidate["type"], candidate["label"])
        was = existing.get(key)

        if not candidate.get("estimated"):
            if not date_is_on_page(candidate["date"], pages[candidate["sourceUrl"]]):
                log.append(f"rejected '{candidate['label']}' {candidate['date'][:10]}: not printed on {candidate['sourceUrl']}")
                continue
        elif was:
            # An estimate can only restate what we already had.
            candidate = dict(was)

        clean = {
            "type": candidate["type"],
            "label": candidate["label"],
            "date": candidate["date"],
            "endDate": candidate.get("endDate"),
            "status": candidate.get("status", "upcoming"),
            "estimated": bool(candidate.get("estimated")),
        }
        if candidate.get("timeUnknown"):
            clean["timeUnknown"] = True
        if candidate.get("sourceUrl"):
            clean["sourceUrl"] = candidate["sourceUrl"]

        if was and was["date"] != clean["date"]:
            log.append(f"{clean['label']}: {was['date'][:10]} -> {clean['date'][:10]}"
                       + ("  (now confirmed)" if was.get("estimated") and not clean["estimated"] else ""))
        elif not was:
            log.append(f"new: {clean['label']} {clean['date'][:10]}"
                       + ("  [est]" if clean["estimated"] else ""))
        accepted[key] = clean

    # Nothing is dropped silently: whatever the model did not replace stays. The one
    # exception is an estimate that a confirmed date has clearly overtaken - a CFP often
    # renames the milestone as it publishes it ("Paper Submission (Cycle 2)" becoming
    # "Cycle 2 Paper Deadline"), which would otherwise leave both rows in the list.
    confirmed = [d for d in accepted.values() if not d.get("estimated")]
    for key, deadline in existing.items():
        if key in accepted:
            continue
        if deadline.get("estimated") and supersedes(confirmed, deadline):
            log.append(f"dropped estimate '{deadline['label']}' {deadline['date'][:10]}: superseded by a confirmed date")
            continue
        accepted[key] = deadline

    updated = dict(conference)
    updated["deadlines"] = sorted(accepted.values(), key=lambda d: d["date"])
    updated["isEstimated"] = any(d.get("estimated") for d in updated["deadlines"])

    location = proposal.get("location") or {}
    if location.get("city") and conference["location"].get("city") in (None, "", "TBD"):
        updated["location"] = {
            "city": location.get("city") or "TBD",
            "country": location.get("country") or "TBD",
            "flag": location.get("flag") or conference["location"].get("flag") or "🌍",
            "venue": location.get("venue"),
        }
        log.append(f"location: {updated['location']['city']}, {updated['location']['country']}")

    notes = proposal.get("notes")
    if isinstance(notes, list) and notes and all(isinstance(n, str) for n in notes):
        updated["notes"] = notes[:2]

    updated["datesTBD"] = not any(d["type"] in ("abstract", "paper") and not d.get("estimated")
                                  for d in updated["deadlines"])
    return updated, log


# --------------------------------------------------------------------------- main

def main() -> int:
    parser = argparse.ArgumentParser(description="Refresh extras.json from the conferences' own pages.")
    parser.add_argument("--conferences", "-c", help="comma-separated ids or names; default is all")
    parser.add_argument("--dry-run", "-n", action="store_true", help="report what would change, write nothing")
    parser.add_argument("--extras", default=str(EXTRAS), help="path to extras.json")
    args = parser.parse_args()

    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print("GEMINI_API_KEY is not set.")
        return 2
    from google import genai
    client = genai.Client(api_key=api_key)

    path = Path(args.extras)
    document = json.loads(path.read_text())
    conferences = document["conferences"]

    wanted = None
    if args.conferences:
        wanted = {w.strip().lower() for w in args.conferences.split(",") if w.strip()}

    today = time.strftime("%Y-%m-%d")
    changed_any = False

    for index, conference in enumerate(conferences):
        if wanted and conference["id"].lower() not in wanted and conference["name"].lower() not in wanted:
            continue

        print(f"\n{conference['name']} {conference['year']} ({conference['id']})")
        pages: dict[str, str] = {}
        for url in source_urls(conference)[:5]:
            text = fetch(url)
            if text:
                pages[url] = text
                print(f"  fetched {url} ({len(text)} chars)")
        if not pages:
            print("  no readable pages, left untouched")
            continue

        proposal = ask_gemini(client, conference, pages, today)
        if not proposal:
            print("  no usable response, left untouched")
            continue

        updated, log = merge_conference(conference, proposal, pages)
        for line in log:
            print(f"  {line}")
        if updated != conference:
            conferences[index] = updated
            changed_any = True
        else:
            print("  no change")

    if not changed_any:
        print("\nNothing changed.")
        return 0

    if args.dry_run:
        print("\nDry run: extras.json left alone.")
        return 0

    document["lastUpdated"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    document["conferences"] = sorted(conferences, key=lambda c: (c["name"], c["year"]))
    path.write_text(json.dumps(document, ensure_ascii=False, indent=1) + "\n")
    print(f"\nWrote {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
