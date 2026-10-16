#!/bin/bash
# Is PaperRush Bar still being kept up to date? One command, run from anywhere:
#
#   ~/ai_conference_deadline/PaperRushBar/scripts/health_check.sh
#
# Checks, in order: the weekly refresh job, how many conferences it got answers
# for, how fresh the published overlay and the upstream dataset are, and whether
# the app on this Mac is current, running, and has synced recently.
set -uo pipefail

REPO="${REPO:-LucasHyun/paperrush-bar}"
APP="/Applications/PaperRushBar.app"
CACHE="${HOME}/Library/Application Support/PaperRushBar/conferences.json"
EXTRAS_URL="https://raw.githubusercontent.com/${REPO}/main/Resources/extras.json"
UPSTREAM_URL="https://raw.githubusercontent.com/awsaf49/paperrush/main/js/data.js"

WARNINGS=0
ok()   { printf '  OK    %s\n' "$*"; }
info() { printf '        %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }

# Whole days since an ISO-8601 timestamp, or "?" when it cannot be read.
days_since() {
	python3 -c 'import sys, datetime as d
try:
    t = d.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
    t = t if t.tzinfo else t.replace(tzinfo=d.timezone.utc)
    print((d.datetime.now(d.timezone.utc) - t).days)
except Exception:
    print("?")' "${1:-}"
}

# "lastUpdated" from a JSON or data.js body on stdin.
last_updated() {
	python3 -c 'import re, sys
m = re.search(r"\"lastUpdated\"\s*:\s*\"([^\"]+)\"", sys.stdin.read())
print(m.group(1) if m else "")'
}

echo "== Weekly refresh job (update-extras)"
if ! command -v gh >/dev/null 2>&1; then
	warn "gh is not installed; skipping the job checks (brew install gh)"
else
	RUN="$(gh run list -R "${REPO}" -w update-extras.yml -L 1 \
		--json databaseId,status,conclusion,createdAt,event \
		-q '.[0] | [.databaseId, .status, .conclusion, .createdAt, .event] | @tsv' 2>/dev/null || true)"
	if [ -z "${RUN}" ]; then
		warn "could not list runs (gh auth status?)"
	else
		IFS=$'\t' read -r RUN_ID STATUS CONCLUSION CREATED EVENT <<<"${RUN}"
		AGE="$(days_since "${CREATED}")"
		if [ "${STATUS}" != "completed" ]; then
			info "latest run ${RUN_ID} (${EVENT}) is still ${STATUS}, started ${AGE} day(s) ago"
		elif [ "${CONCLUSION}" = "success" ]; then
			ok "latest run ${RUN_ID} (${EVENT}) succeeded ${AGE} day(s) ago"
		else
			warn "latest run ${RUN_ID} (${EVENT}) ended '${CONCLUSION}' ${AGE} day(s) ago"
			info "see why: gh run view -R ${REPO} ${RUN_ID} --log-failed | tail -30"
		fi
		if [ "${AGE}" != "?" ] && [ "${AGE}" -gt 8 ]; then
			warn "no run in ${AGE} days; it is scheduled every Monday 06:30 UTC"
		fi

		TALLY="$(gh run view -R "${REPO}" "${RUN_ID}" --log 2>/dev/null \
			| grep -oE '[0-9]+/[0-9]+ answered[^)]*' | tail -1 || true)"
		if [ -n "${TALLY}" ]; then
			ANSWERED="${TALLY%%/*}"
			REST="${TALLY#*/}"
			ASKED="${REST%% *}"
			if [ "${ASKED}" -gt 0 ] && [ $((ANSWERED * 2)) -lt "${ASKED}" ]; then
				warn "Gemini: only ${TALLY}"
			else
				ok "Gemini: ${TALLY}"
			fi
		fi
	fi
fi

echo
echo "== Published data"
EXTRAS_AT="$(curl -fsSL --max-time 20 "${EXTRAS_URL}" 2>/dev/null | last_updated)"
if [ -n "${EXTRAS_AT}" ]; then
	ok "overlay (extras.json) last changed $(days_since "${EXTRAS_AT}") day(s) ago (${EXTRAS_AT})"
	info "it only changes when a conference page shows something new"
else
	warn "could not read ${EXTRAS_URL}"
fi

UP_AT="$(curl -fsSL --max-time 20 "${UPSTREAM_URL}" 2>/dev/null | last_updated)"
if [ -n "${UP_AT}" ]; then
	UP_AGE="$(days_since "${UP_AT}")"
	if [ "${UP_AGE}" != "?" ] && [ "${UP_AGE}" -gt 28 ]; then
		warn "upstream paperrush last changed ${UP_AGE} days ago; its own job may have stopped"
		info "check: https://github.com/awsaf49/paperrush/actions"
	else
		ok "upstream paperrush last changed ${UP_AGE} day(s) ago (${UP_AT})"
	fi
else
	warn "could not read upstream data.js"
fi

echo
echo "== The app on this Mac"
if [ -d "${APP}" ]; then
	INSTALLED="$(defaults read "${APP}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
	LATEST=""
	command -v gh >/dev/null 2>&1 && LATEST="$(gh release view -R "${REPO}" --json tagName -q .tagName 2>/dev/null || true)"
	LATEST="${LATEST#v}"
	if [ -n "${LATEST}" ] && [ "${INSTALLED}" != "${LATEST}" ]; then
		warn "installed ${INSTALLED}, latest release ${LATEST}: brew upgrade --cask paperrush-bar"
	else
		ok "installed version ${INSTALLED}${LATEST:+ (latest)}"
	fi
else
	warn "${APP} not found"
fi

PID="$(pgrep -x PaperRushBar | head -1)"
if [ -n "${PID}" ]; then
	RUNNING="$(ps -o command= -p "${PID}" | sed -E 's#(\.app)/Contents/MacOS/.*#\1#')"
	if [ "${RUNNING}" = "${APP}" ]; then
		ok "running"
	else
		# Usually the copy release.sh builds in the repo: brew cannot update it, and
		# the next build overwrites it while it runs.
		warn "running, but from ${RUNNING}"
		info "fix: osascript -e 'quit app \"PaperRushBar\"'; brew reinstall --cask paperrush-bar;"
		info "     open ${APP}; then switch 'Launch at login' off and on in its gear menu"
	fi
else
	warn "not running: open -a PaperRushBar  (and turn on 'Launch at login' in its gear menu)"
fi

if [ -f "${CACHE}" ]; then
	HOURS=$(( ( $(date +%s) - $(stat -f %m "${CACHE}") ) / 3600 ))
	if [ "${HOURS}" -gt 12 ]; then
		warn "last sync ${HOURS} h ago; it refetches every 6 h while running. Click refresh in the panel."
	else
		ok "last sync ${HOURS} h ago"
	fi
else
	info "no local cache yet (the app has not synced on this Mac)"
fi

echo
if [ "${WARNINGS}" -eq 0 ]; then
	echo "All good."
else
	echo "${WARNINGS} thing(s) to look at, above."
fi
