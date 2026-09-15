#!/usr/bin/env bash
# run_queue.sh — solve all open `war-room` issues on a repo, ONE AT A TIME.
# (Previously ran up to 3 concurrently across tools; that spiked memory
# enough to crash the machine — 3 heavy local-model CLI processes at once on
# a 15GB box was too much. Back to strictly sequential until this machine
# can be confirmed to handle more, or it's tested on beefier hardware.)
#
# Usage: run_queue.sh <repo_dir> <repo_slug>
#
# Reads open war-room issues via `gh issue list`, respects the daily cap in
# state/_daily_cap.json (checked once per batch, not per issue, to keep this
# simple — increments by however many issues are actually dispatched).

set -uo pipefail

REPO_DIR="$(cd "${1:?usage: run_queue.sh <repo_dir> <repo_slug>}" && pwd)"
REPO_SLUG="${2:?usage: run_queue.sh <repo_dir> <repo_slug>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Lock per repo dir — two run_queue.sh processes committing to the same local
# clone concurrently would corrupt the git index. Wait for any existing run
# on this repo to finish rather than running alongside it.
LOCK_FILE="/tmp/warroom-queue-lock-$(echo "$REPO_DIR" | md5sum | cut -d' ' -f1).lock"
exec 9>"$LOCK_FILE"
flock 9
WAR_ROOM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CAP_FILE="$WAR_ROOM_DIR/state/_daily_cap.json"
LOG_DIR="$WAR_ROOM_DIR/logs"

mkdir -p "$LOG_DIR"

# --- daily cap check ---
# A missing/corrupted/mid-write-truncated cap file used to feed empty strings
# straight into `(( CAP_LIMIT - CAP_COUNT ))`, which is a bash syntax error
# under `set -u` — this would silently kill run_queue.sh with no useful
# message and continuous_runner.sh would just see it as another failed batch,
# never actually reporting *why*. Validate as integers first; self-repair to
# a safe default (rather than crash) and log loudly so it's visible.
TODAY="$(date +%F)"
if ! [[ -s "$CAP_FILE" ]] || ! jq -e . "$CAP_FILE" >/dev/null 2>&1; then
  echo "WARNING: $CAP_FILE missing or corrupted — resetting to a safe default" >&2
  [[ -f "$CAP_FILE" ]] && cp "$CAP_FILE" "$CAP_FILE.corrupt-$(date +%s)" 2>/dev/null
  jq -n --arg d "$TODAY" '{daily_limit: 30, date: $d, count: 0}' > "$CAP_FILE"
fi
CAP_DATE="$(jq -r '.date // empty' "$CAP_FILE")"
CAP_LIMIT="$(jq -r '.daily_limit // empty' "$CAP_FILE")"
CAP_COUNT="$(jq -r '.count // empty' "$CAP_FILE")"
if ! [[ "$CAP_LIMIT" =~ ^[0-9]+$ ]] || ! [[ "$CAP_COUNT" =~ ^[0-9]+$ ]]; then
  echo "WARNING: $CAP_FILE has non-numeric daily_limit/count — resetting to a safe default" >&2
  cp "$CAP_FILE" "$CAP_FILE.corrupt-$(date +%s)" 2>/dev/null
  jq -n --arg d "$TODAY" '{daily_limit: 30, date: $d, count: 0}' > "$CAP_FILE"
  CAP_DATE="$TODAY"; CAP_LIMIT=30; CAP_COUNT=0
fi
if [[ "$CAP_DATE" != "$TODAY" ]]; then
  CAP_COUNT=0
  jq --arg d "$TODAY" '.date=$d | .count=0' "$CAP_FILE" > "$CAP_FILE.tmp" && mv "$CAP_FILE.tmp" "$CAP_FILE"
fi
REMAINING=$(( CAP_LIMIT - CAP_COUNT ))
if (( REMAINING <= 0 )); then
  echo "DAILY_CAP_HIT count=$CAP_COUNT limit=$CAP_LIMIT"
  exit 1
fi

# --- fetch open war-room issues ---
# Sorted ascending by issue number (not gh's default recency order): an issue
# that keeps failing accumulates comments/pushes and would otherwise keep
# bubbling to the top of a recency-sorted list, hogging every single slot
# once the daily cap is nearly exhausted (REMAINING==1) and starving every
# other open issue on the repo. Ascending-by-number gives fair rotation.
# Wrapped in timeout: this call has no other bound, and a network/API stall
# here previously hung the whole repo's lap for 7+ hours with nothing to
# kill it — every dispatch further down the chain is already timeout-wrapped,
# this was the one gap.
mapfile -t ISSUES < <(timeout 60 gh issue list --repo "$REPO_SLUG" --label war-room --state open --json number,title,body \
  --jq 'sort_by(.number) | .[] | "\(.number)\t\(.title)\t\(.body | gsub("\n";" "))"')

if (( ${#ISSUES[@]} == 0 )); then
  echo "NO_OPEN_ISSUES"
  exit 0
fi

# --- per-issue consecutive-failure tracking ---
# Without this, one chronically-failing issue can eat every dispatch slot
# forever (observed: cliq issue #6 burned 15+ cap extensions in a row on one
# issue while #2/#3/#4 sat untouched). After MAX_CONSECUTIVE_FAILS straight
# fails, skip it for the rest of today so other issues/repos get a turn —
# it stays open for a human to look at, nothing is lost.
FAIL_STATE="$WAR_ROOM_DIR/state/_issue_fail_counts.json"
if [[ ! -s "$FAIL_STATE" ]] || ! jq -e . "$FAIL_STATE" >/dev/null 2>&1; then
  [[ -f "$FAIL_STATE" ]] && cp "$FAIL_STATE" "$FAIL_STATE.corrupt-$(date +%s)" 2>/dev/null
  echo '{}' > "$FAIL_STATE"
fi
MAX_CONSECUTIVE_FAILS=3
fail_key() { echo "${REPO_SLUG}#${1}"; }
get_fail_count() { jq -r --arg k "$(fail_key "$1")" '.[$k] // 0' "$FAIL_STATE"; }
bump_fail_count() {
  jq --arg k "$(fail_key "$1")" '.[$k] = ((.[$k] // 0) + 1)' "$FAIL_STATE" > "$FAIL_STATE.tmp" && mv "$FAIL_STATE.tmp" "$FAIL_STATE"
}
reset_fail_count() {
  jq --arg k "$(fail_key "$1")" 'del(.[$k])' "$FAIL_STATE" > "$FAIL_STATE.tmp" && mv "$FAIL_STATE.tmp" "$FAIL_STATE"
}

# Filter out issues already at/over the fail cap before slicing to REMAINING,
# so a blocked issue doesn't consume the slot a healthy issue could use.
FILTERED=()
for line in "${ISSUES[@]}"; do
  NUM="$(cut -f1 <<<"$line")"
  if (( $(get_fail_count "$NUM") >= MAX_CONSECUTIVE_FAILS )); then
    continue
  fi
  FILTERED+=("$line")
done

if (( ${#FILTERED[@]} == 0 && ${#ISSUES[@]} > 0 )); then
  echo "ALL_REMAINING_ISSUES_BLOCKED (${#ISSUES[@]} open, all at $MAX_CONSECUTIVE_FAILS+ consecutive fails — needs human review)"
  exit 0
fi

TO_RUN=("${FILTERED[@]:0:REMAINING}")
echo "QUEUED: ${#TO_RUN[@]} issue(s), daily remaining before run: $REMAINING"

RESULTS_DIR="$(mktemp -d)"
# hermes dropped from rotation: disabled in dispatch.sh until NVIDIA_API_KEY
# is configured (every hermes call fails immediately otherwise).
TOOLS=(opencode agy)
i=0
for line in "${TO_RUN[@]}"; do
  NUM="$(cut -f1 <<<"$line")"
  TITLE="$(cut -f2 <<<"$line")"
  BODY="$(cut -f3 <<<"$line")"
  PROMPT="Issue #$NUM: $TITLE

$BODY"
  # Re-check live state before working on it — the TO_RUN list was snapshotted
  # once at the top of this script, so an issue already closed by an earlier
  # iteration (or a previous/parallel run) could still appear here stale.
  CURRENT_STATE="$(timeout 60 gh issue view "$NUM" --repo "$REPO_SLUG" --json state --jq '.state' 2>/dev/null)"
  if [[ "$CURRENT_STATE" == "CLOSED" ]]; then
    echo "RESULT=SKIPPED reason=\"issue #$NUM already closed\"" > "$RESULTS_DIR/$NUM.result"
    reset_fail_count "$NUM"
    continue
  fi
  # Rotate which tool is primary issue-to-issue (still one at a time, not
  # concurrently) so we're not always hammering the same tool first.
  PRIMARY_FOR_THIS="${TOOLS[$(( i % ${#TOOLS[@]} ))]}"
  i=$((i+1))
  PRIMARY="$PRIMARY_FOR_THIS" bash "$SCRIPT_DIR/solve_issue.sh" "$REPO_DIR" "$REPO_SLUG" "$NUM" "$PROMPT" \
    "$LOG_DIR/$(basename "$REPO_DIR")-$NUM" > "$RESULTS_DIR/$NUM.result" 2>&1
  RESULT_LINE="$(tail -1 "$RESULTS_DIR/$NUM.result")"
  if [[ "$RESULT_LINE" == RESULT=PASS* ]]; then
    reset_fail_count "$NUM"
  else
    bump_fail_count "$NUM"
  fi
done

# --- collect results, update cap counter ---
PASS_COUNT=0
FAIL_COUNT=0
for f in "$RESULTS_DIR"/*.result; do
  NUM="$(basename "$f" .result)"
  LINE="$(tail -1 "$f")"
  echo "issue #$NUM -> $LINE"
  case "$LINE" in
    RESULT=PASS*) PASS_COUNT=$((PASS_COUNT+1));;
    *) FAIL_COUNT=$((FAIL_COUNT+1));;
  esac
done
rm -rf "$RESULTS_DIR"

NEW_COUNT=$(( CAP_COUNT + ${#TO_RUN[@]} ))
jq --argjson c "$NEW_COUNT" '.count=$c' "$CAP_FILE" > "$CAP_FILE.tmp" && mv "$CAP_FILE.tmp" "$CAP_FILE"

echo "BATCH_DONE pass=$PASS_COUNT fail=$FAIL_COUNT cap_count_now=$NEW_COUNT/$CAP_LIMIT"
