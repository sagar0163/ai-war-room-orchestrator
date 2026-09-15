#!/usr/bin/env bash
# dispatch.sh — send one task to a local heavy-worker CLI, falling back down
# the chain if one is rate-limited/unavailable. Claude audits the result
# after this returns; this script never commits/pushes/touches GitHub.
#
# Usage:
#   dispatch.sh "<prompt text>" <log_file>              # plain coding task
#   COUNCIL=1 dispatch.sh "<question/context>" <log_file>  # run the llm-council
#     methodology (skills/llm-council-skill.md) inside whichever tool answers
#
# Models:
#   opencode -> opencode/big-pickle (deepseek-v4-flash, the user's original
#               pick, and every other NVIDIA passthrough model tested were
#               EOL/404/hanging on this account's opencode integration —
#               big-pickle is opencode's own hosted default and confirmed live)
#   hermes   -> nvidia/nemotron-3.5-lightning-30b-a3b
#   agy      -> gemini-3.1-pro-low, --effort low
#
# Exit 0 + prints which tool answered on success; exit 1 if all failed.
#
# Every tool call is wrapped in `timeout` (TOOL_TIMEOUT_SECS, default 25min).
# Without this, one hung backend call blocks forever — and since the whole
# pipeline runs strictly sequentially (no parallelism, per the crash lesson),
# a single stuck call stalls EVERY repo behind it indefinitely. This actually
# happened: an opencode call hung 30+ hours on 2026-09-06/07, freezing the
# entire war room until manually killed. A timed-out call now just falls
# through to the next tool in the chain like any other failure.

set -uo pipefail

TOOL_TIMEOUT_SECS="${TOOL_TIMEOUT_SECS:-1500}"

PROMPT="${1:?usage: dispatch.sh <prompt> <log_file>}"
LOG="${2:?usage: dispatch.sh <prompt> <log_file>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COUNCIL_SKILL="$SCRIPT_DIR/../skills/llm-council-skill.md"

FULL_PROMPT="$PROMPT"
if [[ "${COUNCIL:-0} " == "1 " ]]; then
  COUNCIL_INSTRUCTIONS="$(cat "$COUNCIL_SKILL")"
  FULL_PROMPT="Follow this council methodology yourself, end to end, in this single response (you don't have sub-agents, so run all 5 advisor perspectives, then peer-review, then chairman synthesis, sequentially in your own reasoning). Output the final COUNCIL VERDICT section clearly at the end.

--- METHODOLOGY ---
$COUNCIL_INSTRUCTIONS
--- END METHODOLOGY ---

--- QUESTION / CONTEXT FOR THE COUNCIL ---
$PROMPT
--- END QUESTION ---"
fi

# Signatures a tool prints when it degraded/gave up internally but still
# exits 0 — observed with hermes hitting its own payload-size ceiling
# ("Request payload too large... Cannot compress further") and then exiting
# success with effectively no real output. Treated as a failure requiring
# fallback to the next tool, not a false "OK".
FALSE_SUCCESS_PATTERNS='Request payload too large|Cannot compress further|max compression attempts'

try_tool() {
  local name="$1"; shift
  local out
  out="$(mktemp)"
  echo "=== trying: $name (timeout ${TOOL_TIMEOUT_SECS}s) ===" | tee -a "$LOG"
  if timeout --kill-after=30 "${TOOL_TIMEOUT_SECS}s" "$@" >"$out" 2>&1; then
    cat "$out" >> "$LOG"
    if grep -qE "$FALSE_SUCCESS_PATTERNS" "$out"; then
      echo "=== $name: exited 0 but hit a known false-success pattern (degraded/no real output) — treating as FAILED ===" | tee -a "$LOG"
      rm -f "$out"
      return 1
    fi
    echo "=== $name: OK ===" | tee -a "$LOG"
    echo "$name"
    rm -f "$out"
    return 0
  fi
  local rc=$?
  cat "$out" >> "$LOG"
  rm -f "$out"
  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
    echo "=== $name: TIMED OUT after ${TOOL_TIMEOUT_SECS}s — killed, see $LOG ===" | tee -a "$LOG"
  else
    echo "=== $name: FAILED (rc=$rc) — see $LOG ===" | tee -a "$LOG"
  fi
  return 1
}

# PRIMARY env var (opencode|hermes|agy) rotates which tool goes first, so a
# concurrent batch (run_queue.sh) can spread load across all three instead of
# every issue hammering the same tool first. Default order still favors the
# effectively-unlimited ones (opencode/hermes) over rate-limited agy.
run_opencode() { try_tool opencode opencode run -m opencode/big-pickle "$FULL_PROMPT"; }
run_hermes()   { try_tool hermes hermes -z "$FULL_PROMPT" -m nvidia/nemotron-3.5-lightning-30b-a3b --yolo; }
run_agy()      { try_tool agy ~/.local/bin/agy -p "$FULL_PROMPT" --model gemini-3.1-pro-low --effort low; }

# hermes disabled for now: NVIDIA_API_KEY isn't set in this environment, so
# every hermes call fails immediately ("No usable credentials found for
# provider 'nvidia'") — wasting a fallback slot on every single dispatch
# across the whole pipeline. Drop it from the rotation until the credential
# is configured; re-add run_hermes to these ORDER lists once it is.
case "${PRIMARY:-opencode}" in
  hermes)   ORDER=(run_opencode run_agy) ;;
  agy)      ORDER=(run_agy run_opencode) ;;
  *)        ORDER=(run_opencode run_agy) ;;
esac

for fn in "${ORDER[@]}"; do
  if "$fn"; then exit 0; fi
done

echo "ALL_TOOLS_EXHAUSTED" | tee -a "$LOG"
exit 1
