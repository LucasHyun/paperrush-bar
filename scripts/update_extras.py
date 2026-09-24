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

# Tried in order until one answers; GEMINI_MODEL (comma-separated) overrides the list.
# Flash-Lite first: pulling dates out of a few pages is well within it. No 2.5 model:
# Google now serves those only to keys that used them before, so a new key gets a 404 --
# which this script used to swallow as "no usable response" and report as no change.
MODELS = [m.strip() for m in os.environ.get("GEMINI_MODEL", "").split(",") if m.strip()] or [
    "gemini-flash-lite-latest", "gemini-3.5-flash-lite", "gemini-3.1-flash-lite",
    "gemini-flash-latest", "gemini-3.6-flash", "gemini-3.8-flash",
]
EXCLUDED_MODEL_WORDS = ("preview", "exp", "image", "tts", "live", "audio", "embedding", "thinking", "native")
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
    # No digit may touch either end: a plain substring test let "october 1" match
    # inside "october 15" and "1 oct" inside "21 oct".
    if any(re.search(r"(?<!\d)" + re.escape(s.lower()) + r"(?!\d)", lowered) for s in spellings):
        return True
    # What those miss is how conferences write their own dates: day-first ranges
    # ("16-21 May 2027", "16th-21st May"), ordinals ("16th May", "May 16th") and
    # "Sept". A main conference is nearly always a range, which is why every
    # "Main Conference" used to come back as not printed.
    names = [name.lower(), name[:3].lower() + r"\.?"] + ([r"sept\.?"] if month == 9 else [])
    month_re = "(?:" + "|".join(names) + ")"
    ordinal = r"(?:st|nd|rd|th)?"
    day_first = (r"(?<!\d)0?" + str(day) + ordinal
                 + r"(?:\s*[-\u2013\u2014]\s*\d{1,2}" + ordinal + r")?\s+(?:of\s+)?" + month_re + r"(?![a-z])")
    month_first = r"(?<![a-z])" + month_re + r"\s+0?" + str(day) + ordinal + r"(?!\d)"
    return bool(re.search(day_first, lowered) or re.search(month_first, lowered))


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


MAX_SHIFT_DAYS = 180


def edition_problem(candidate: dict, was: dict | None, year: int, today: str) -> str | None:
    """Why this date cannot belong to the `year` edition, or None when it can.

    Being printed on the page is not enough. An entry for next year's edition cites last
    year's pages until the new site exists, and a date read from those is real, legible
    and wrong: that is how 3DV 2028 and AAAI 2028 once took their 2027 dates as
    "confirmed". Deadlines for a `year` edition fall between January of `year - 1` and
    the January after it (a late event such as a career site closing); the conference
    itself in `year`; and a real schedule change never moves a date by half a year.
    """
    if not year:
        return None
    date = candidate["date"][:10]
    held = int(date[:4])
    if candidate["type"] == "conference":
        if held != year:
            return f"the {year} edition is not held in {held}"
    elif not f"{year - 1}-01-01" <= date <= f"{year + 1}-01-31":
        return f"{date} is outside {year - 1}-01 to {year + 1}-01, where the {year} edition's dates fall"
    if was:
        if was["date"][:10] >= today > date:
            return f"would move {was['date'][:10]} into the past"
        shift = days_between(was["date"], date)
        if shift > MAX_SHIFT_DAYS:
            return f"would move the date by {shift} days"
    return None


# --------------------------------------------------------------------------- model

PROMPT = """You are reading the official pages of one academic conference and extracting its schedule.

Today is {today}.

This entry is for the {year} edition. Here is what we currently hold for it:

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
- Report only dates of the {year} edition. The pages may describe another edition, most often the
  previous one; if so, report none of that edition's dates, and not its location either.
- Anywhere on Earth (AoE) means a -12:00 offset. Use the real offset when one is stated.
- When a date has no time of day, write it as "YYYY-MM-DD" and set "timeUnknown": true.
- Set "estimated": false for a date printed on the page. If a date in the current entry is marked
  estimated and the pages do not confirm it, keep it as it is, still marked estimated.
- Keep the deadlines from the current entry that the pages neither confirm nor replace.
- Cover the conference's own cycles: if it has two submission cycles, report both, and say which is
  which in each label, e.g. "Paper Submission (Cycle 2)".
- `notes` should say what is still unannounced, or what changed. Do not repeat the dates in it.
"""


_models = list(MODELS)
_discovered = False

# The free tier allows 15 requests a minute per model. Staying under it costs a few
# minutes a week; running into it cost whole conferences, because the old retry waited
# two to six seconds when Google had asked for forty.
MIN_REQUEST_INTERVAL = 60 / 14
_last_request = 0.0


def _pace() -> None:
    global _last_request
    wait = _last_request + MIN_REQUEST_INTERVAL - time.monotonic()
    if wait > 0:
        time.sleep(wait)
    _last_request = time.monotonic()


def _rate_limit(error: Exception) -> tuple[str, float] | None:
    """("minute", seconds to wait) or ("day", 0) for a 429; None for anything else."""
    text = str(error)
    if getattr(error, "code", None) != 429 and "RESOURCE_EXHAUSTED" not in text:
        return None
    if "PerDay" in text:
        return ("day", 0.0)
    found = re.search(r"retry in ([\d.]+)s", text) or re.search(r"retryDelay'?: '(\d+)s", text)
    return ("minute", float(found.group(1)) if found else 30.0)


def _parse_json(text: str):
    """Models sometimes leave a comma before a closing brace, which JSON does not allow."""
    text = re.sub(r"^```json?\s*\n?", "", text.strip())
    text = re.sub(r"\n?```\s*$", "", text)
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return json.loads(re.sub(r",\s*([}\]])", r"\1", text))


def _not_found(error: Exception) -> bool:
    return getattr(error, "code", None) == 404 or "NOT_FOUND" in str(error)


def _next_model(client) -> str | None:
    """The model to use now. When every listed one has answered 404, ask the key once
    which Flash models it can call, Lite first and newest first."""
    global _discovered
    if not _models and not _discovered:
        _discovered = True
        try:
            names = []
            for model in client.models.list():
                name = (model.name or "").removeprefix("models/")
                actions = getattr(model, "supported_actions", None) or []
                if ("generateContent" in actions and name.startswith("gemini-") and "flash" in name
                        and not name.startswith(("gemini-1.", "gemini-2."))
                        and not any(word in name for word in EXCLUDED_MODEL_WORDS)):
                    names.append(name)
            names.sort(key=lambda n: (0 if "lite" in n else 1, [-int(x) for x in re.findall(r"\d+", n)]))
            _models.extend(names)
            print(f"    listed models to try: {', '.join(names[:5]) or 'none'}")
        except Exception as error:
            print(f"    could not list models: {error}")
    return _models[0] if _models else None


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
    prompt = PROMPT.format(today=today, year=conference.get("year") or "current", current=current,
                           pages="\n\n".join(rendered))

    # No temperature and no output cap: Google advises leaving temperature alone on the
    # 3.x models, and a cap can be spent on thinking before any JSON is written.
    config = types.GenerateContentConfig(response_mime_type="application/json")
    failures = waits = 0
    while failures < 3:
        model = _next_model(client)
        if model is None:
            print("    no Gemini model answered for this key")
            return None
        _pace()
        try:
            response = client.models.generate_content(
                model=model,
                contents=[types.Content(role="user", parts=[types.Part.from_text(text=prompt)])],
                config=config,
            )
            return _parse_json(response.text or "")
        except Exception as error:  # transient API or JSON trouble
            if _not_found(error):
                print(f"    {model} is not available to this key, moving on")
                _models.remove(model)
                continue
            limit = _rate_limit(error)
            if limit and limit[0] == "day":
                # Each model has its own daily quota, so the next one can carry on.
                print(f"    {model}: today's free quota is used up, moving on")
                _models.remove(model)
                continue
            if limit and waits < 4:
                waits += 1
                print(f"    {model}: rate limited, waiting {limit[1]:.0f}s as asked")
                time.sleep(min(limit[1] + 1, 90))
                continue
            failures += 1
            print(f"    {model} attempt {failures} failed: {str(error)[:300]}")
            time.sleep(2 * failures)
    return None


# --------------------------------------------------------------------------- merge

def days_between(a: str, b: str) -> int:
    from datetime import date
    return abs((date.fromisoformat(a[:10]) - date.fromisoformat(b[:10])).days)


def supersedes(confirmed: list[dict], estimate: dict) -> bool:
    """True when a confirmed deadline is obviously the same milestone as this estimate."""
    return any(d["type"] == estimate["type"] and days_between(d["date"], estimate["date"]) < 45
               for d in confirmed)


_LABEL_NOISE = {"the", "of", "and", "for", "a", "an", "deadline", "date", "dates", "due"}


def _label_words(label: str) -> set[str]:
    return {w for w in re.findall(r"[a-z0-9]+", label.lower()) if w not in _LABEL_NOISE}


def same_milestone(a: dict, b: dict) -> bool:
    """Same type, same day, and labels made of mostly the same words.

    The model words a milestone differently from one week to the next -- "Abstract
    Submission (Blue Sky Ideas)", then "Blue Sky Ideas Abstract Submission" -- and
    matching on the exact label added it again each time. Two milestones that merely
    share a day ("Paper Submission (Main)" and "(Blue Sky)") share too few words.
    """
    if a["type"] != b["type"] or a["date"][:10] != b["date"][:10]:
        return False
    wa, wb = _label_words(a["label"]), _label_words(b["label"])
    return bool(wa and wb) and len(wa & wb) / len(wa | wb) >= 0.6


def merge_conference(conference: dict, proposal: dict, pages: dict[str, str],
                     today: str | None = None) -> tuple[dict, list[str]]:
    """Apply a proposal on top of the current entry, keeping anything unverified."""
    today = today or time.strftime("%Y-%m-%d")
    year = conference.get("year") or 0
    verified = 0
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
        if was is None:
            # The same milestone reworded: keep the label we already have.
            twin = next((d for d in existing.values() if same_milestone(d, candidate)), None)
            if twin:
                key, was = (twin["type"], twin["label"]), twin
                candidate = dict(candidate, label=twin["label"])

        if not candidate.get("estimated"):
            if not date_is_on_page(candidate["date"], pages[candidate["sourceUrl"]]):
                log.append(f"rejected '{candidate['label']}' {candidate['date'][:10]}: not printed on {candidate['sourceUrl']}")
                continue
            problem = edition_problem(candidate, was, year, today)
            if problem:
                log.append(f"rejected '{candidate['label']}' {candidate['date'][:10]}: {problem}")
                continue
            verified += 1
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

    # Location and notes carry no date to check, so they are only taken from a proposal
    # that got at least one date past every guard -- evidence the pages are this edition's.
    location = (proposal.get("location") or {}) if verified else {}
    if location.get("city") not in (None, "", "TBD") and conference["location"].get("city") in (None, "", "TBD"):
        updated["location"] = {
            "city": location.get("city") or "TBD",
            "country": location.get("country") or "TBD",
            "flag": location.get("flag") or conference["location"].get("flag") or "🌍",
            "venue": location.get("venue"),
        }
        log.append(f"location: {updated['location']['city']}, {updated['location']['country']}")

    notes = proposal.get("notes") if verified else None
    if isinstance(notes, list) and notes and all(isinstance(n, str) for n in notes):
        updated["notes"] = notes[:2]

    updated["datesTBD"] = not any(d["type"] in ("abstract", "paper") and not d.get("estimated")
                                  for d in updated["deadlines"])
    # Derived flags can change with nothing else; without a line here such a change
    # was written with no trace in the log.
    for flag in ("isEstimated", "datesTBD"):
        if conference.get(flag) != updated.get(flag):
            log.append(f"{flag}: {conference.get(flag)} -> {updated.get(flag)}")
    return updated, log


# --------------------------------------------------------------------------- main

def main() -> int:
    parser = argparse.ArgumentParser(description="Refresh extras.json from the conferences' own pages.")
    parser.add_argument("--conferences", "-c", help="comma-separated ids or names; default is all")
    parser.add_argument("--dry-run", "-n", action="store_true", help="report what would change, write nothing")
    parser.add_argument("--extras", default=str(EXTRAS), help="path to extras.json")
    parser.add_argument("--changelog", help="write what changed, grouped by conference, to this file")
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
    asked = answered = 0
    skipped: list[str] = []
    changelog: list[str] = []

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

        asked += 1
        proposal = ask_gemini(client, conference, pages, today)
        if proposal:
            answered += 1
        else:
            skipped.append(conference["id"])
        if not proposal:
            print("  no usable response, left untouched")
            continue

        updated, log = merge_conference(conference, proposal, pages)
        for line in log:
            print(f"  {line}")
        if log:
            changelog.append(f"{conference['name']} {conference['year']} ({conference['id']})")
            changelog.extend(f"  {line}" for line in log)
        if updated != conference:
            conferences[index] = updated
            changed_any = True
        else:
            print("  no change")

    used = _models[0] if _models else "none"
    tally = f"{answered}/{asked} answered, model {used}" + (f"; skipped {', '.join(skipped)}" if skipped else "")
    if args.changelog:
        Path(args.changelog).write_text("\n".join(changelog + ["", tally]) + "\n")

    # Silence here would look exactly like a quiet week. Make it a failed run instead.
    if asked and not answered:
        print(f"\nGemini answered for none of the {asked} conferences it was asked about.")
        return 1

    if not changed_any:
        print(f"\nNothing changed ({tally}).")
        return 0

    if args.dry_run:
        print(f"\nDry run: extras.json left alone ({tally}).")
        return 0

    document["lastUpdated"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    document["conferences"] = sorted(conferences, key=lambda c: (c["name"], c["year"]))
    path.write_text(json.dumps(document, ensure_ascii=False, indent=1) + "\n")
    print(f"\nWrote {path} ({tally})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
