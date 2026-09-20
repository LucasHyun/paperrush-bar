# Additions for the CONFERENCES dict in scripts/scraper.py of awsaf49/paperrush.
#
# These eight have stable, year-templated official sites, so the scraper can
# follow them from year to year. Four more conferences we track (ICDM, CIKM,
# AAMAS, RecSys) change host and URL every edition — their entries are in
# data.js.additions.json for manual addition instead.

    "www": {
        "name": "WWW",
        "base": "https://www{year}.thewebconf.org",
        "seeds": [
            "",  # Landing
            "important-dates/",
            "research-track-papers/",  # CFP + author guidelines
        ],
        "link_only": [
            "calls-for-papers/",
            "workshops/",
            "tutorials/",
        ],
    },
    "sigir": {
        "name": "SIGIR",
        "base": "https://sigir{year}.org",
        "seeds": [
            "",  # Landing carries "Important Dates"
            "pages/submit-tracks.html",
        ],
        "link_only": [
            "pages/calls.html",
        ],
    },
    "ecml-pkdd": {
        "name": "ECML PKDD",
        "base": "https://ecmlpkdd.org/{year}",
        "seeds": [
            "",
            "submissions-research-track/",
            "submissions-journal-track/",
        ],
        "link_only": [
            "submissions-applied-data-science-track/",
            "submissions-demo-track/",
        ],
    },
    "colm": {
        "name": "COLM",
        "base": "https://colm.cc/Conferences/{year}",
        "seeds": [
            "CallForPapers",
            "Dates",
        ],
        "link_only": [
            "ReviewerGuidelines",
        ],
    },
    "uai": {
        "name": "UAI",
        "base": "https://www.auai.org/uai{year}",
        "seeds": [
            "",
            "call_for_papers",
        ],
        "link_only": [
            "reviewer_guidelines",
        ],
    },
    "ecai": {
        "name": "ECAI",
        "base": "https://ecai{year}.org",
        "seeds": [
            "",  # Landing carries the key dates table
            "calls/main-track.html",
        ],
        "link_only": [
            "calls/workshops.html",
            "calls/tutorials.html",
        ],
    },
    "acm-mm": {
        "name": "ACM MM",
        "base": "https://{year}.acmmm.org",
        "seeds": [
            "",
            "site/important-dates.html",
            "site/cfp-guidelines.html",
        ],
        "link_only": [
            "site/cfp-workshops.html",
            "site/cfp-tutorials.html",
        ],
    },
    "wsdm": {
        "name": "WSDM",
        "base": "https://www.wsdm-conference.org/{year}",
        "seeds": [
            "",
            "cffp.html",
        ],
        "link_only": [
            "cfw.html",
        ],
    },
