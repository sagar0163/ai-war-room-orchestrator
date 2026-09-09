#!/usr/bin/env bash
# night_runner.sh — SUPERSEDED by continuous_runner.sh, kept only for
# reference; not invoked by anything live. If the daily cap is hit, raises
# daily_limit by +1 at a time (never a big jump) up to +20 total for the
# day, any time of day (no 7am cutoff), then keeps going. Once the +20
# budget is used, stops extending — but NEVER aborts a queue batch that's
# already running; run_queue.sh always finishes whatever it started before
# this loop re-checks anything.

set -uo pipefail

WAR_ROOM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$WAR_ROOM_DIR/scripts"
CAP_FILE="$WAR_ROOM_DIR/state/_daily_cap.json"
LOG="$WAR_ROOM_DIR/logs/night_runner.log"
MAX_EXTRA=20
extra_used=0

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

PILOT_REPOS=("llm-manager:sagar0163/llm-manager" "argus-pentest:sagar0163/argus-pentest" "apix-gateway:sagar0163/apix-gateway")

ensure_clone() {
  local name="$1" slug="$2"
  local candidates=(
    "$WAR_ROOM_DIR/../$name"
    "$WAR_ROOM_DIR/workspace/$name"
  )
  for c in "${candidates[@]}"; do
    if [[ -d "$c/.git" ]]; then echo "$c"; return 0; fi
  done
  local dest="$WAR_ROOM_DIR/workspace/$name"
  git clone "git@github.com:$slug.git" "$dest" >>"$LOG" 2>&1
  echo "$dest"
}

for entry in "${PILOT_REPOS[@]}"; do
  name="${entry%%:*}"; slug="${entry#*:}"
  repo_dir="$(ensure_clone "$name" "$slug")"
  log "=== repo: $slug (dir: $repo_dir) ==="

  # council + issue filing, only if no war-room issues exist yet on this repo
  existing="$(gh issue list --repo "$slug" --label war-room --state all --json number --jq 'length' 2>/dev/null || echo 0)"
  if [[ "$existing" == "0" ]]; then
    log "no war-room issues yet, running council_and_issues.sh"
    bash "$SCRIPT_DIR/council_and_issues.sh" "$repo_dir" "$slug" "$WAR_ROOM_DIR/logs/${name}-council.log" | tee -a "$LOG"
  fi

  # solve loop, extending the cap gradually overnight if needed
  while true; do
    OUT="$(bash "$SCRIPT_DIR/run_queue.sh" "$repo_dir" "$slug" 2>&1)"
    echo "$OUT" | tee -a "$LOG"

    if echo "$OUT" | grep -q "^NO_OPEN_ISSUES"; then
      log "$slug: queue empty, moving on"
      break
    fi

    if echo "$OUT" | grep -q "^DAILY_CAP_HIT"; then
      if (( extra_used >= MAX_EXTRA )); then
        log "cap hit and +$MAX_EXTRA extension budget used up — stopping for the night"
        exit 0
      fi
      # raise the limit by exactly 1 and retry (no time-of-day cutoff)
      jq '.daily_limit += 1' "$CAP_FILE" > "$CAP_FILE.tmp" && mv "$CAP_FILE.tmp" "$CAP_FILE"
      extra_used=$((extra_used+1))
      log "daily cap hit — raised daily_limit by 1 (extension $extra_used/$MAX_EXTRA), retrying"
      continue
    fi

    # batch completed normally (some pass/fail) — check if more issues remain
    remaining="$(gh issue list --repo "$slug" --label war-room --state open --json number --jq 'length' 2>/dev/null || echo 0)"
    if [[ "$remaining" == "0" ]]; then
      log "$slug: no issues left open, moving on"
      break
    fi
    # more issues remain and cap wasn't hit — loop again immediately
  done
done

log "night_runner finished all pilot repos"
