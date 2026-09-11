#!/usr/bin/env bash
# watchdog.sh — ensures continuous_runner.sh is always running. Run this from
# cron every few minutes (and @reboot) rather than relying on a human to
# notice a silent death. Previously the only way we found out the runner had
# died was the user asking "is this continuing or not" — this closes that gap.
#
# Safe to run concurrently with itself (flock) and idempotent: does nothing
# if the runner is already alive.

set -uo pipefail

WAR_ROOM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$WAR_ROOM_DIR/scripts"
LOG="$WAR_ROOM_DIR/logs/watchdog.log"
RUNNER_PATTERN="continuous_runner.sh"

mkdir -p "$WAR_ROOM_DIR/logs"
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# Prevent two watchdog invocations (e.g. cron overlap) from racing to launch
# two copies of the runner.
#
# Caught live: a watchdog invocation held this lock for 14+ hours straight
# (spanning a laptop suspend/resume) with nothing to show for it, and every
# 5-minute cron tick in between exited silently right here on the old `exit
# 0` — so the runner sat dead the whole time with zero trace in this log.
# Log every time the lock is contended, including how long it's been held
# and by which PID, so a repeat of this is visible instead of silent.
LOCK_FILE="/tmp/warroom-watchdog.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  held_since="unknown age"
  if lock_mtime="$(stat -c %Y "$LOCK_FILE" 2>/dev/null)"; then
    held_since="$(( $(date +%s) - lock_mtime ))s"
  fi
  holder_pid="$(fuser "$LOCK_FILE" 2>/dev/null | tr -d ' ')"
  log "lock contended (held ~${held_since}, holder pid(s): ${holder_pid:-unknown}) — skipping this tick"
  exit 0
fi
# Now that we hold it, stamp the lock file's mtime to now so the age check
# above is meaningful for whoever contends next.
touch "$LOCK_FILE" 2>/dev/null || true

# Log rotation: this runs every 5 minutes forever, so logs/ grows without
# bound otherwise. Compress anything untouched for 7+ days, delete compressed
# logs older than 30 days. Cheap enough to run every invocation.
find "$WAR_ROOM_DIR/logs" -type f -name "*.log" -mtime +7 ! -name "*.gz" -exec gzip {} \; 2>/dev/null
find "$WAR_ROOM_DIR/logs" -type f -name "*.gz" -mtime +30 -delete 2>/dev/null

# pgrep -f matches the full command line; excludes this watchdog process and
# any grep itself.
if pgrep -f "bash .*${RUNNER_PATTERN}" >/dev/null 2>&1; then
  exit 0
fi

# The one prior real incident this session was the machine crashing under
# memory pressure from concurrent heavy AI CLI processes. Relaunching into an
# already memory-starved system just reproduces that risk, so surface it
# loudly (still relaunch — a dead runner making zero progress is worse than a
# slow one) rather than silently trying again every 5 minutes with no signal.
if command -v free >/dev/null 2>&1; then
  avail_mb="$(free -m | awk '/^Mem:/{print $7}')"
  if [[ -n "$avail_mb" ]] && (( avail_mb < 500 )); then
    log "WARNING: only ${avail_mb}MB memory available — restarting anyway, but this machine may be under memory pressure (past cause of a full crash)"
  fi
fi

# gh auth broken (expired token, revoked key) makes every gh call in the
# pipeline silently degrade to '0'/empty via its `|| echo 0` fallbacks —
# run_queue.sh would then just report NO_OPEN_ISSUES for every repo forever,
# looking like healthy "nothing to do" instead of a broken credential. Catch
# it here where a human is more likely to see the log.
# timeout-wrapped: the leading theory for the 14-hour lock hold above is a
# network call (gh, here) stalling forever across a suspend/resume instead
# of erroring — nothing in this script previously had a hard ceiling.
if ! timeout 30 gh auth status >/dev/null 2>&1; then
  log "WARNING: gh auth status failed — GitHub calls will likely fail silently across the pipeline. Restarting runner anyway; check 'gh auth status' manually."
fi

log "continuous_runner.sh not running — restarting"
cd "$WAR_ROOM_DIR"
setsid nohup bash "$SCRIPT_DIR/continuous_runner.sh" >> "$WAR_ROOM_DIR/logs/continuous_runner_stdout.log" 2>&1 < /dev/null &
disown
sleep 2
if pgrep -f "bash .*${RUNNER_PATTERN}" >/dev/null 2>&1; then
  log "restart OK, pid=$(pgrep -f "bash .*${RUNNER_PATTERN}" | head -1)"
else
  log "restart FAILED — runner did not come up, check logs/continuous_runner_stdout.log"
fi
