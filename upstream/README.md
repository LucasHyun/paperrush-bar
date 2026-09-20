# Upstream contribution draft

PaperRush Bar reads its data from [awsaf49/paperrush](https://github.com/awsaf49/paperrush).
Twelve conferences we wanted were not in that dataset, so they live in
[`../Resources/extras.json`](../Resources/extras.json) and are merged on top of upstream at runtime.

The right long-term home for them is upstream, where everyone benefits and the scraper keeps them
current. This folder holds the material for that pull request, kept in sync with `extras.json`.

| File | Goes into |
|---|---|
| `scraper_conferences.additions.py` | the `CONFERENCES` dict in `scripts/scraper.py` |
| `conference_metadata.additions.json` | `scripts/conference_metadata.json` |
| `data.js.additions.json` | `js/data.js` (manual method, for the four sites the scraper can't follow) |
| `kdd_cycle2.patch.json` | `js/data.js`, **merged into the existing `kdd-2027` entry** — not a new conference |
| `PR_BODY.md` | the pull request description |

Also append the new ids to `ALL_CONFERENCES` in `.github/workflows/update-deadlines.yml`:

```
www wsdm icdm cikm ecml-pkdd sigir recsys colm uai acm-mm aamas ecai
```

## Which ones the scraper can follow

Eight have a stable, year-templated official domain, so `base` with `{year}` works:
WWW (`www{year}.thewebconf.org`), SIGIR (`sigir{year}.org`), ECML PKDD (`ecmlpkdd.org/{year}`),
COLM (`colm.cc/Conferences/{year}`), UAI (`auai.org/uai{year}`), ECAI (`ecai{year}.org`),
ACM MM (`{year}.acmmm.org`), WSDM (`wsdm-conference.org/{year}`).

Four move to a new host every edition and cannot be templated:

- **ICDM** — per-edition university sites (e.g. `icdm2026.neu.edu.cn`); the series page `icdm.zhonghuapu.com` lists future host cities but not deadlines.
- **CIKM** — per-edition sites (e.g. `cikm2026.diag.uniroma1.it`).
- **AAMAS** — hosted by the organizing institution (e.g. `warwick.ac.uk/.../aamas2027`).
- **RecSys** — `recsys.acm.org/recsys27` uses a two-digit year, which `{year}` cannot express.

For those, the manual entries in `data.js.additions.json` are the practical route, unless the
scraper config grows a per-year URL override.

## The KDD patch

KDD runs two submission cycles a year, and `kdd-2027` upstream carries only Cycle 1 (abstract
19 Jul 2026, paper 26 Jul 2026). `kdd_cycle2.patch.json` holds the five Cycle 2 deadlines to append
to that entry's `deadlines` array. The KDD 2027 CFP says only "February 2027" for Cycle 2, so those
dates mirror the KDD 2026 Cycle 2 schedule and are marked `"estimated": true` — worth re-checking
right before the PR, and worth asking the maintainer whether the scraper should learn to pick up
both cycles from the research-track page.

## Before opening the PR

Re-verify the dates: the ones marked `"estimated": true` were inferred from the previous cycle at
the time of writing and several CFPs will have been published since. Run the scraper locally first,
as upstream's CONTRIBUTING asks:

```bash
python scripts/scraper.py --conferences www,sigir,colm --year 2027
```
