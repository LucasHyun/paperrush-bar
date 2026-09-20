## Add 12 data mining, IR, and AI conferences

This adds WWW, WSDM, ICDM, CIKM, ECML PKDD, SIGIR, RecSys, COLM, UAI, ACM MM, AAMAS and ECAI.

The dataset already covers vision, NLP, core ML and robotics well, but the data mining / information
retrieval side is currently represented only by KDD, and COLM — now a major venue for language-model
work — is missing entirely. These twelve are the gaps I kept hitting.

### What's in here

- `scripts/scraper.py`: eight new entries in `CONFERENCES`. Each has a stable year-templated official
  domain, so the scraper can follow them across editions: WWW, SIGIR, ECML PKDD, COLM, UAI, ECAI,
  ACM MM, WSDM.
- `scripts/conference_metadata.json`: `fullName` / `category` / `brandColor` for all twelve.
  Colors were checked against the existing palette so none collide.
- `.github/workflows/update-deadlines.yml`: the new ids appended to `ALL_CONFERENCES`.
- `js/data.js`: manual entries for **ICDM, CIKM, AAMAS and RecSys**, which move to a new host every
  edition (per-institution sites, or RecSys's two-digit `recsys27` path) and so can't be expressed as
  a `{year}` template. Happy to drop these from the PR if you'd rather keep `data.js` fully generated.

### Data provenance

Every date was taken from the official CFP or the conference's own important-dates page, and each
deadline carries its `sourceUrl`. Where the next edition's CFP is not out yet, the entry is inferred
from the previous cycle and marked `"estimated": true` with `"isEstimated": true` on the conference
and a note saying so — nothing inferred is presented as confirmed.

Confirmed from published CFPs: WWW 2027, AAMAS 2027, ECAI 2027, SIGIR 2027.
Inferred from the previous cycle: COLM 2027, UAI 2027, RecSys 2027, ICDM 2027, CIKM 2027,
ECML PKDD 2027, ACM MM 2027, WSDM 2028.

### Notes

- AoE deadlines are written with a `-12:00` offset, matching the existing entries.
- ECML PKDD has two journal-track cycles plus the research track; each is a separate deadline.
- WSDM's entry is for **2028**, because WSDM 2027 (Hong Kong) closed submissions on 24 Aug 2026.
- Categories: the data mining / IR venues use `ml`, COLM uses `nlp`, ACM MM uses `cv`.

These came out of [PaperRush Bar](https://github.com/LucasHyun/paperrush-bar), a macOS menu bar app
that reads this dataset. Thanks for maintaining it — the schema made this easy to build on.
