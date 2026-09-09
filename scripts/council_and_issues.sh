#!/usr/bin/env bash
# council_and_issues.sh — ONE dispatch that does council analysis AND files
# the resulting issues on GitHub itself (gh issue create), fully offloaded.
# Claude only reads the short summary block, not the full transcript.
#
# Usage: council_and_issues.sh <repo_dir> <repo_slug e.g. sagar0163/llm-manager> <log_file>
#
# Requires: the repo dir has `gh` authenticated (already set up per user's
# global SSH/gh config) and is a git checkout of repo_slug.

set -uo pipefail

REPO_DIR="$(cd "${1:?usage: council_and_issues.sh <repo_dir> <repo_slug> <log_file>}" && pwd)"
REPO_SLUG="${2:?usage: council_and_issues.sh <repo_dir> <repo_slug> <log_file>}"
LOG_ARG="${3:?usage: council_and_issues.sh <repo_dir> <repo_slug> <log_file>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$(dirname "$LOG_ARG")"
LOG="$(cd "$(dirname "$LOG_ARG")" && pwd)/$(basename "$LOG_ARG")"

README_EXCERPT="$(head -c 3000 "$REPO_DIR/README.md" 2>/dev/null)"

PROMPT="You are working in the git repo at: $REPO_DIR (GitHub: $REPO_SLUG). You have gh CLI access authenticated for this account — use it.

README excerpt:
---
$README_EXCERPT
---

Do all of the following yourself:
1. Research real competing/similar open-source projects in this repo's exact
   space (find actual current ones, don't guess).
2. Run the council methodology (5 advisors -> peer review -> chairman) on:
   'What does this repo need to add or improve to stand above its
   competitors?'
3. Turn the chairman's concrete recommendations into 3-8 well-scoped GitHub
   issues. For each one, run:
   gh issue create --repo $REPO_SLUG --title \"<title>\" --body \"<description +
   acceptance criteria>\" --label war-room
   (create the 'war-room' label first with 'gh label create war-room
   --repo $REPO_SLUG --color FBCA04' if it doesn't exist; ignore error if it
   already exists)
4. As your LAST output, print exactly this block (nothing after it):
===SUMMARY===
COMPETITORS: <comma separated list>
ISSUES_CREATED: <comma separated issue numbers, e.g. 12,13,14>
===END SUMMARY==="

TOOL="$(cd "$REPO_DIR" && COUNCIL=1 bash "$SCRIPT_DIR/dispatch.sh" "$PROMPT" "$LOG")"
RC=$?
if [[ $RC -ne 0 ]]; then
  echo "RESULT=EXHAUSTED"
  exit 1
fi

SUMMARY="$(awk '/===SUMMARY===/,/===END SUMMARY===/' "$LOG")"
if [[ -z "$SUMMARY" ]]; then
  # Model didn't emit the literal block — fall back to ground truth: ask
  # GitHub directly what war-room issues actually exist now (this is what
  # matters, not whether the tool followed the exact output format).
  ISSUE_NUMS="$(gh issue list --repo "$REPO_SLUG" --label war-room --state open --json number --jq '[.[].number] | join(",")')"
  if [[ -n "$ISSUE_NUMS" ]]; then
    echo "RESULT=OK tool=$TOOL (no summary block; recovered from gh issue list)"
    echo "===SUMMARY==="
    echo "COMPETITORS: unknown (tool didn't report format; see $LOG)"
    echo "ISSUES_CREATED: $ISSUE_NUMS"
    echo "===END SUMMARY==="
  else
    echo "RESULT=FAIL reason=\"no summary block AND no war-room issues found on repo, see $LOG\""
  fi
  exit 0
fi

echo "RESULT=OK tool=$TOOL"
echo "$SUMMARY"
