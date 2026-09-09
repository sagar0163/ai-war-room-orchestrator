#!/usr/bin/env bash
# continuous_runner.sh — runs the war room 24/7, strictly sequentially
# (one dispatch at a time — parallel dispatches crashed this machine once
# already, never again). Cycles through every non-skipped repo in
# repos.json, forever:
#   1. ensure the repo is cloned (reuse an existing clone, don't re-clone)
#   2. run council_and_issues.sh if it has no war-room issues yet
#   3. run_queue.sh until its open war-room issues are empty
#   4. move to the next repo; after the last repo, sleep briefly and loop
#      back to the first (a fresh council pass later catches what an
#      earlier pass missed, per the methodology's peer-review design —
#      but only re-run council on a repo whose last run is >24h old, so
#      it doesn't spam duplicate issues every lap)
#
# Daily dispatch cap: if hit, raise daily_limit by +1 at a time (never a
# jump) up to +20 above whatever it was at the start of today, then keep
# going. If a day's +20 extension budget is used up, this pauses dispatch
# until the date rolls over (cap resets), but keeps the loop alive.
# NEVER kills a batch that's already running — run_queue.sh always
# finishes whatever it started.

set -uo pipefail

# The orphan-prevention trap below only works if this process is its own
# process-group LEADER (pgid == pid) — `kill -TERM -- -$$` targets a process
# group, and if this script inherited its group from whatever shell launched
# it (true for a plain `nohup bash continuous_runner.sh &`, only false when
# launched via `setsid`, which watchdog.sh does but a manual restart might
# not), the group being killed doesn't actually contain this script's
# children — the kill silently no-ops and every dispatch orphans on exit
# exactly like before the trap existed. Caught live: a manually-started
# second instance left an orphaned run_queue.sh under init after being
# killed, because it was never its own group leader. Force it here so the
# guarantee holds no matter how this script is invoked.
#
# Guarded by an env var, not a `ps -o pgid=` comparison against $$: the ps-
# based check false-triggered even when already launched via `setsid`
# (observed live — likely a setsid/nohup/exec interaction that leaves pgid
# reporting stale for one tick), causing a redundant self-re-exec that left
# a harmless but confusing extra wrapper process sitting in `exec ... --wait`
# around the real worker. An env var inherited by the child can't misfire.
if [[ "${WARROOM_SESSION_LEADER:-0}" != "1" ]]; then
  export WARROOM_SESSION_LEADER=1
  exec setsid --wait "$0" "$@"
fi

WAR_ROOM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$WAR_ROOM_DIR/scripts"
CAP_FILE="$WAR_ROOM_DIR/state/_daily_cap.json"
REPOS_FILE="$WAR_ROOM_DIR/repos.json"
LOG="$WAR_ROOM_DIR/logs/continuous_runner.log"
MAX_EXTRA_PER_DAY=20
GITHUB_USER="sagar0163"

# Refuse to run a second instance. Nothing previously stopped this: the
# watchdog's own flock only guards against two watchdog *invocations* racing
# to launch a runner — it does nothing if a second runner is started some
# other way (a manual restart while one is already alive, a stale terminal,
# etc). Two live instances don't corrupt a single repo's git state directly
# (run_queue.sh already flocks per-repo), but the council-run duplicate-issue
# check and the daily-cap `jq += 1` update below are both racy read-modify-
# write sequences with no per-process lock, so two runners really did lose
# cap-file updates and could double-file council issues — caught live when a
# second instance ended up running for over an hour before being noticed.
RUNNER_LOCK="/tmp/warroom-runner-singleton.lock"
exec 8>"$RUNNER_LOCK"
if ! flock -n 8; then
  echo "[$(date '+%F %T')] another continuous_runner.sh instance already holds $RUNNER_LOCK — exiting" >&2
  exit 1
fi

# A plain `kill`/`pkill` against this top-level process (as opposed to -9,
# which can't be trapped) previously left an in-flight run_queue.sh ->
# solve_issue.sh -> dispatch.sh -> opencode/hermes/agy chain running as an
# orphan under init — still holding that repo's flock, blocking the very
# restart that's supposed to replace it, until its own 25-minute tool
# timeout eventually expired on its own. On a graceful termination signal,
# kill this whole process group so nothing is left behind.
cleanup_on_exit() {
  # Without this, a graceful TERM only killed the CURRENT batch's children —
  # the trap ran, but never called exit, so the main loop just kept going and
  # silently started a fresh lap with fresh children right after. Caught
  # live: `kill -TERM` was sent to stop the runner, the trap fired and logged
  # it, but new opencode dispatches for the next repo started seconds later
  # anyway — the process never actually died. Untrap first so the group-wide
  # TERM below (which we send to ourselves too, being in our own group)
  # doesn't re-enter this handler, then exit for real.
  trap - TERM INT
  log "received termination signal — killing process group $$ to avoid leaving orphaned dispatches, then exiting"
  kill -TERM -- -$$ 2>/dev/null
  exit 0
}
trap cleanup_on_exit TERM INT

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

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

extra_used_today=0
extra_date="$(date +%F)"

while true; do
  today="$(date +%F)"
  if [[ "$today" != "$extra_date" ]]; then
    extra_used_today=0
    extra_date="$today"
  fi

  mapfile -t REPO_NAMES < <(jq -r '.repos[] | select(.status != "skipped") | .name' "$REPOS_FILE")

  for name in "${REPO_NAMES[@]}"; do
    slug="$GITHUB_USER/$name"
    repo_dir="$(ensure_clone "$name" "$slug")"
    if [[ ! -d "$repo_dir/.git" ]]; then
      log "skip $slug: clone failed"
      continue
    fi
    log "=== repo: $slug ==="

    council_log="$WAR_ROOM_DIR/logs/${name}-council.log"
    existing="$(gh issue list --repo "$slug" --label war-room --state all --json number --jq 'length' 2>/dev/null || echo 0)"
    council_stale=true
    if [[ -f "$council_log" ]]; then
      age_sec=$(( $(date +%s) - $(stat -c %Y "$council_log") ))
      (( age_sec < 86400 )) && council_stale=false
    fi
    if [[ "$existing" == "0" && "$council_stale" == "true" ]]; then
      log "$slug: running council_and_issues.sh"
      bash "$SCRIPT_DIR/council_and_issues.sh" "$repo_dir" "$slug" "$council_log" 2>&1 | tee -a "$LOG"
    fi

    # A previously-blocked issue (3+ consecutive fails) otherwise stays
    # blocked forever with no re-evaluation path — nothing was clearing
    # state/_issue_fail_counts.json. Give it a fresh shot whenever this repo
    # gets any council/issue attention (i.e. whenever we reach this point,
    # not only on a genuinely fresh council run) but only once per >24h
    # window (reusing council_stale so this doesn't reset fail counts every
    # single 5-minute lap and defeat the point of the block).
    if [[ "$council_stale" == "true" ]]; then
      FAIL_STATE="$WAR_ROOM_DIR/state/_issue_fail_counts.json"
      if [[ -f "$FAIL_STATE" ]]; then
        jq --arg prefix "${slug}#" 'with_entries(select(.key | startswith($prefix) | not))' \
          "$FAIL_STATE" > "$FAIL_STATE.tmp" && mv "$FAIL_STATE.tmp" "$FAIL_STATE"
      fi
    fi

    # solve loop for this repo, extending the cap gradually if needed
    while true; do
      OUT="$(bash "$SCRIPT_DIR/run_queue.sh" "$repo_dir" "$slug" 2>&1)"
      echo "$OUT" | tee -a "$LOG"

      if echo "$OUT" | grep -q "^NO_OPEN_ISSUES"; then
        break
      fi

      if echo "$OUT" | grep -q "^ALL_REMAINING_ISSUES_BLOCKED"; then
        log "$slug: all remaining open issues are blocked (3+ consecutive fails each) — needs human review, moving on"
        break
      fi

      if echo "$OUT" | grep -q "^DAILY_CAP_HIT"; then
        if (( extra_used_today >= MAX_EXTRA_PER_DAY )); then
          # Recompute fresh here, not the stale $today captured at the top of
          # the outer lap loop — this inner solve-loop can run for many hours
          # (even past midnight) without ever returning to the outer loop, so
          # $today can be a day behind by the time we actually pause. Purely
          # cosmetic (extra_used_today itself is unaffected), but the log
          # printed the wrong date because of it.
          log "cap hit, +$MAX_EXTRA_PER_DAY budget used for $(date +%F) — pausing dispatch until date rolls over"
          # sleep until local midnight, then let the outer loop re-check
          now_ts=$(date +%s)
          midnight_ts=$(date -d "tomorrow 00:00:00" +%s)
          sleep $(( midnight_ts - now_ts > 0 ? midnight_ts - now_ts : 60 ))
          break
        fi
        jq '.daily_limit += 1' "$CAP_FILE" > "$CAP_FILE.tmp" && mv "$CAP_FILE.tmp" "$CAP_FILE"
        extra_used_today=$((extra_used_today+1))
        log "daily cap hit — raised daily_limit by 1 (extension $extra_used_today/$MAX_EXTRA_PER_DAY today), retrying"
        continue
      fi

      remaining="$(gh issue list --repo "$slug" --label war-room --state open --json number --jq 'length' 2>/dev/null || echo 0)"
      [[ "$remaining" == "0" ]] && break
    done
    log "$slug: done for this lap"
  done

  log "completed a full lap over ${#REPO_NAMES[@]} repos — sleeping 5 min before next lap"
  sleep 300
done
