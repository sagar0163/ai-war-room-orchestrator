#!/usr/bin/env bash
# solve_issue.sh — fully offloaded solve-loop for ONE issue, including the
# GitHub write-back. Claude only reads this script's final one-line stdout —
# never diffs, never touches git/gh itself.
#
# Usage: solve_issue.sh <repo_dir> <repo_slug> <issue_number> "<issue_prompt>" <log_prefix>
#
# Steps (all offloaded to opencode/hermes/agy via dispatch.sh):
#   1. WORKER dispatch: read the code, write the fix + tests, commit AND push
#      to a dedicated feature branch (war-room-issue-<N>), print
#      "COMMITTED: <sha> <msg>".
#   2. solve_issue.sh opens a PR from that branch (never touches git/gh
#      content itself beyond this bookkeeping — no code decisions made here).
#   3. VERIFIER dispatch (independent second tool): given the commit diff,
#      checks it against acceptance criteria, runs tests if any. If it
#      judges PASS, it submits a GitHub PR review (`gh pr review --approve`)
#      and merges the PR itself (`gh pr merge`), which auto-closes the issue
#      via a "Closes #N" line in the PR body — then replies "PASS". If not
#      satisfied: submits `gh pr review --request-changes` and replies
#      "FAIL: <reason>"; nothing is merged, nothing closes.
#
# Why PRs instead of a direct push (this used to push straight to the
# default branch): the verifier's correctness check was always functionally
# a code review, but with no PR to attach it to, GitHub never counted it as
# one — the account's contribution graph showed 0 code-review contributions
# despite the pipeline doing real per-change review on every single issue.
# Routing through gh pr review/merge makes that existing review step count
# for what it already was, with no change to the actual review rigor.
#
# This also structurally closes an entire bug class for free: an issue can
# now ONLY auto-close via GitHub's own "Closes #N" merge linkage, which only
# fires on a genuine, server-side-confirmed merge — there is no longer a way
# for a verifier to close an issue on GitHub without the code actually
# landing (previously possible via a separately-run `gh issue close`, which
# is exactly how issues got closed for commits that silently never pushed).
#
# Final stdout (the ONLY thing Claude should read):
#   RESULT=PASS sha=<sha> msg="<commit message>" pr=<pr_number>   (merged, issue auto-closed)
#   RESULT=FAIL reason="<reason>"                                  (nothing merged, issue left open)
#   RESULT=EXHAUSTED   (all tools failed at some step)

set -uo pipefail

REPO_DIR="$(cd "${1:?usage: solve_issue.sh <repo_dir> <repo_slug> <issue_number> <issue_prompt> <log_prefix>}" && pwd)"
REPO_SLUG="${2:?usage: solve_issue.sh <repo_dir> <repo_slug> <issue_number> <issue_prompt> <log_prefix>}"
ISSUE_NUM="${3:?usage: solve_issue.sh <repo_dir> <repo_slug> <issue_number> <issue_prompt> <log_prefix>}"
ISSUE_PROMPT="${4:?usage: solve_issue.sh <repo_dir> <repo_slug> <issue_number> <issue_prompt> <log_prefix>}"
LOG_PREFIX_ARG="${5:?usage: solve_issue.sh <repo_dir> <repo_slug> <issue_number> <issue_prompt> <log_prefix>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$(dirname "$LOG_PREFIX_ARG")"
LOG_PREFIX="$(cd "$(dirname "$LOG_PREFIX_ARG")" && pwd)/$(basename "$LOG_PREFIX_ARG")"

WORKER_LOG="${LOG_PREFIX}-worker.log"
VERIFY_LOG="${LOG_PREFIX}-verify.log"
FEATURE_BRANCH="war-room-issue-${ISSUE_NUM}"

# Start from a clean working tree. A previous FAILED attempt (on this issue
# or another one) can leave uncommitted edits sitting in the repo; if the
# next worker's `git add -A && git commit` runs on top of that, it silently
# sweeps the leftover changes into its own commit — contaminating an
# unrelated issue's fix. Stash (never discard) anything dirty before starting.
if [[ -n "$(cd "$REPO_DIR" && git status --porcelain)" ]]; then
  (cd "$REPO_DIR" && git stash push -u -m "war-room: pre-issue-$ISSUE_NUM cleanup ($(date '+%F %T'))") \
    >> "$WORKER_LOG" 2>&1
fi

# Resolve the repo's real default branch first (this is the PR's base, not
# where anyone commits directly anymore).
# Resolution order: (1) local origin/HEAD symbolic ref — fast, no network —
# but this can be MISSING entirely on a clone that was never given one, in
# which case git prints nothing and we'd silently fall through to a wrong
# hardcoded guess (this actually happened: cliq's real default is
# feature/auto-ai-tracing, but a missing local ref made this fall back to
# "main", and every fix since landed on the wrong branch, invisible to
# GitHub's contribution graph and not what the repo actually ships).
# (2) `gh repo view` — authoritative, always correct, small network cost.
# (3) "main" — last-resort guess only if both of the above somehow fail.
DEFAULT_BRANCH="$(cd "$REPO_DIR" && git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#origin/##')"
if [[ -z "$DEFAULT_BRANCH" ]]; then
  DEFAULT_BRANCH="$(gh repo view "$REPO_SLUG" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)"
  # Fix the local ref so future runs resolve it instantly without a gh call.
  if [[ -n "$DEFAULT_BRANCH" ]]; then
    (cd "$REPO_DIR" && git remote set-head origin "$DEFAULT_BRANCH") >> "$WORKER_LOG" 2>&1
  fi
fi
if [[ -z "$DEFAULT_BRANCH" ]]; then
  echo "WARNING: both local origin/HEAD and gh repo view failed to resolve the default branch for $REPO_SLUG — falling back to hardcoded 'main', which may be wrong for this repo" >> "$WORKER_LOG"
fi
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

# git pull hits the network — a transient blip here shouldn't cost this
# issue a strike against its 3-fail block budget for a reason that has
# nothing to do with the actual fix. Retry twice with a short backoff before
# giving up and proceeding anyway (worker will just re-pull if truly stale).
pull_ok=false
for attempt in 1 2 3; do
  if (cd "$REPO_DIR" && git checkout "$DEFAULT_BRANCH" >> "$WORKER_LOG" 2>&1 && git pull --ff-only origin "$DEFAULT_BRANCH" >> "$WORKER_LOG" 2>&1); then
    pull_ok=true
    break
  fi
  echo "checkout/pull attempt $attempt failed, retrying..." >> "$WORKER_LOG"
  sleep 5
done
if [[ "$pull_ok" != "true" ]]; then
  echo "WARNING: could not checkout/pull $DEFAULT_BRANCH after 3 attempts — proceeding with whatever local state exists" >> "$WORKER_LOG"
fi

# Always start this issue's feature branch fresh off an up-to-date default
# branch. A stale branch left over from a previous FAILED attempt (rejected
# review, or an earlier crash) would otherwise accumulate unrelated commits
# or diverge from main across retries. Delete both local and remote copies
# first (ignore errors — most of the time neither exists yet).
(cd "$REPO_DIR" && git branch -D "$FEATURE_BRANCH") >> "$WORKER_LOG" 2>&1
(cd "$REPO_DIR" && git push origin --delete "$FEATURE_BRANCH") >> "$WORKER_LOG" 2>&1
(cd "$REPO_DIR" && git checkout -b "$FEATURE_BRANCH") >> "$WORKER_LOG" 2>&1

WORKER_PROMPT="You are working in the git repo at: $REPO_DIR (GitHub: $REPO_SLUG, issue #$ISSUE_NUM).
Task: $ISSUE_PROMPT

IMPORTANT — branch discipline: you are already on a dedicated feature branch
'$FEATURE_BRANCH', created fresh off an up-to-date '$DEFAULT_BRANCH'. Stay on
'$FEATURE_BRANCH' — do not switch to '$DEFAULT_BRANCH' or any other branch.
This branch will become a pull request, not a direct push.

Do the following yourself, don't ask questions:
1. Read whatever files are relevant.
2. Write the fix/feature and any tests needed.
3. Run the project's test/build command if one exists; fix failures yourself.
4. Stage and commit locally, ON '$FEATURE_BRANCH', with: git add -A && git commit
   -m \"<clear message, reference #$ISSUE_NUM>\"
5. Push the branch: git push -u origin $FEATURE_BRANCH
   Do NOT open a pull request yourself, do NOT touch GitHub issues yet —
   that happens after independent verification.
6. As the LAST line of your output print exactly:
   COMMITTED: <git sha> | <commit message>
   (or, if you could not complete the task, print exactly: NOT_COMMITTED: <reason>)"

# Record HEAD before dispatch. A worker that finds the fix "already done" by
# an earlier/different issue's commit will sometimes lazily report the
# current HEAD sha as if it just committed it — even when HEAD has since
# moved on to some unrelated issue's work (e.g. reporting issue #63's commit
# as its own answer for issue #62). Any COMMITTED sha that isn't a genuine
# new descendant made *after* this dispatch started is worthless and must
# not be sent to the verifier as this issue's diff.
PRE_HEAD="$(cd "$REPO_DIR" && git rev-parse HEAD)"
echo "=== PRE_HEAD (before worker dispatch): $PRE_HEAD ===" >> "$WORKER_LOG"

WORKER_TOOL="$(cd "$REPO_DIR" && PRIMARY="${PRIMARY:-opencode}" bash "$SCRIPT_DIR/dispatch.sh" "$WORKER_PROMPT" "$WORKER_LOG")"
WORKER_RC=$?
if [[ $WORKER_RC -ne 0 ]]; then
  echo "RESULT=EXHAUSTED"
  exit 1
fi

WORKER_LAST_LINE="$(grep -E "^(COMMITTED|NOT_COMMITTED):" "$WORKER_LOG" | tail -1)"
if [[ "$WORKER_LAST_LINE" != COMMITTED:* ]]; then
  echo "RESULT=FAIL reason=\"worker did not commit: ${WORKER_LAST_LINE:-no output}\""
  exit 0
fi

SHA_AND_MSG="${WORKER_LAST_LINE#COMMITTED: }"
SHA="${SHA_AND_MSG%% |*}"
MSG="${SHA_AND_MSG#*| }"

RESOLVED_SHA="$(cd "$REPO_DIR" && git rev-parse "$SHA" 2>/dev/null)"
if [[ -z "$RESOLVED_SHA" ]] || [[ "$RESOLVED_SHA" == "$PRE_HEAD" ]] || \
   ! (cd "$REPO_DIR" && git merge-base --is-ancestor "$PRE_HEAD" "$RESOLVED_SHA" 2>/dev/null); then
  echo "RESULT=FAIL reason=\"worker reported stale/unrelated commit sha ($SHA) that predates this dispatch — not a real new commit for issue #$ISSUE_NUM\""
  exit 0
fi
SHA="$RESOLVED_SHA"

# Confirm the worker actually pushed the branch before spending a PR-create
# call on it — a worker that commits locally but forgets step 5 would
# otherwise produce a confusing "no commits between branches" PR failure.
push_ok=false
for attempt in 1 2 3; do
  if (cd "$REPO_DIR" && git fetch origin "$FEATURE_BRANCH") >> "$WORKER_LOG" 2>&1 && \
     (cd "$REPO_DIR" && git merge-base --is-ancestor "$SHA" "origin/$FEATURE_BRANCH" 2>/dev/null); then
    push_ok=true
    break
  fi
  echo "verifying worker's push of $FEATURE_BRANCH, attempt $attempt failed, retrying..." >> "$WORKER_LOG"
  sleep 5
done
if [[ "$push_ok" != "true" ]]; then
  echo "RESULT=FAIL reason=\"worker committed $SHA locally but it never reached origin/$FEATURE_BRANCH\""
  exit 0
fi

PR_BODY="$(printf '%s\n\nCloses #%s\n\n---\nOpened automatically by the war room pipeline. Worker commit: %s' "$MSG" "$ISSUE_NUM" "$SHA")"
PR_URL="$(gh pr create --repo "$REPO_SLUG" --base "$DEFAULT_BRANCH" --head "$FEATURE_BRANCH" \
  --title "$MSG" --body "$PR_BODY" 2>>"$WORKER_LOG")"
if [[ -z "$PR_URL" ]]; then
  echo "RESULT=FAIL reason=\"gh pr create failed for $FEATURE_BRANCH -> $DEFAULT_BRANCH, see worker log\""
  exit 0
fi
PR_NUM="${PR_URL##*/}"
echo "=== opened PR #$PR_NUM: $PR_URL ===" >> "$WORKER_LOG"

DIFF="$(cd "$REPO_DIR" && git show --stat -p "$SHA" 2>/dev/null | head -c 8000)"

VERIFY_PROMPT="You are working in the git repo at: $REPO_DIR (GitHub: $REPO_SLUG,
issue #$ISSUE_NUM). An independent worker claims to have completed this task,
committed as $SHA, and opened pull request #$PR_NUM ($PR_URL) from branch
'$FEATURE_BRANCH' into '$DEFAULT_BRANCH':
--- TASK ---
$ISSUE_PROMPT
--- END TASK ---

Here is the commit diff (may be truncated):
--- DIFF ---
$DIFF
--- END DIFF ---

1. Check: does this diff actually satisfy the task's acceptance criteria? Run
   the repo's test/build command yourself if one exists.
2. If and ONLY if you're satisfied it's correct:
   - run: gh pr review $PR_NUM --repo $REPO_SLUG --approve --body \"<one line summary of why this is correct>\"
   - run: gh pr merge $PR_NUM --repo $REPO_SLUG --squash --delete-branch
   - then reply with exactly: PASS
3. If NOT satisfied:
   - run: gh pr review $PR_NUM --repo $REPO_SLUG --request-changes --body \"<one short reason>\"
   - do NOT merge, do NOT touch the issue
   - reply with exactly: FAIL: <one short reason>

Reply with EXACTLY one line as your last output, nothing after it."

# Verifier defaults to a different primary tool than the worker used, for
# independence (a tool shouldn't grade its own homework first).
case "${PRIMARY:-opencode}" in
  opencode) VERIFY_PRIMARY=hermes ;;
  hermes)   VERIFY_PRIMARY=agy ;;
  *)        VERIFY_PRIMARY=opencode ;;
esac
VERIFY_TOOL="$(cd "$REPO_DIR" && PRIMARY="$VERIFY_PRIMARY" bash "$SCRIPT_DIR/dispatch.sh" "$VERIFY_PROMPT" "$VERIFY_LOG")"
VERIFY_RC=$?
if [[ $VERIFY_RC -ne 0 ]]; then
  echo "RESULT=EXHAUSTED"
  exit 1
fi

VERDICT_LINE="$(grep -E "^(PASS|FAIL:)" "$VERIFY_LOG" | tail -1)"
if [[ "$VERDICT_LINE" == PASS* ]]; then
  # Never trust the verifier's own word that it merged. The old direct-push
  # design had verifiers claim PASS (and even close GitHub issues) while
  # `git push` silently never landed — the "fix" only ever existed in the
  # local clone, invisible on GitHub, for issues #1/#2/#5/#6/#7 on cliq
  # across 2026-09-06/07. Same discipline here: independently confirm via
  # the PR's own merged state, then confirm the merge commit is actually an
  # ancestor of the remote default branch, before believing PASS.
  merge_check_ok=false
  for attempt in 1 2 3; do
    MERGED_INFO="$(gh pr view "$PR_NUM" --repo "$REPO_SLUG" --json merged,mergeCommit --jq '[.merged, .mergeCommit.oid // ""] | @tsv' 2>>"$VERIFY_LOG")"
    if [[ -n "$MERGED_INFO" ]]; then
      merge_check_ok=true
      break
    fi
    echo "gh pr view attempt $attempt failed, retrying..." >> "$VERIFY_LOG"
    sleep 5
  done
  MERGED="$(cut -f1 <<<"$MERGED_INFO")"
  MERGE_SHA="$(cut -f2 <<<"$MERGED_INFO")"

  landed=false
  if [[ "$merge_check_ok" == "true" && "$MERGED" == "true" && -n "$MERGE_SHA" ]]; then
    (cd "$REPO_DIR" && git fetch origin "$DEFAULT_BRANCH") >> "$VERIFY_LOG" 2>&1
    if (cd "$REPO_DIR" && git merge-base --is-ancestor "$MERGE_SHA" "origin/$DEFAULT_BRANCH" 2>/dev/null); then
      landed=true
    fi
  fi

  if [[ "$landed" == "true" ]]; then
    echo "RESULT=PASS sha=$MERGE_SHA msg=\"$MSG\" pr=$PR_NUM"
  else
    # Verifier said PASS but the PR isn't actually merged onto the remote
    # default branch. Because the issue can now ONLY auto-close via a real
    # merge (the "Closes #N" linkage), there is no direct-close path left
    # for the verifier to have used instead — but check defensively anyway
    # in case it closed the issue by hand despite instructions not to.
    CURRENT_ISSUE_STATE="$(gh issue view "$ISSUE_NUM" --repo "$REPO_SLUG" --json state --jq '.state' 2>/dev/null)"
    if [[ "$CURRENT_ISSUE_STATE" == "CLOSED" ]]; then
      gh issue reopen "$ISSUE_NUM" --repo "$REPO_SLUG" >> "$VERIFY_LOG" 2>&1
      gh issue comment "$ISSUE_NUM" --repo "$REPO_SLUG" --body "Reopening: the verifier reported PR #$PR_NUM as resolved and approved, but it never actually merged onto origin/$DEFAULT_BRANCH. Re-queued for another attempt." >> "$VERIFY_LOG" 2>&1
    fi
    gh pr close "$PR_NUM" --repo "$REPO_SLUG" --comment "Closing: approved but never merged onto $DEFAULT_BRANCH — will be re-attempted on a fresh branch." >> "$VERIFY_LOG" 2>&1
    echo "RESULT=FAIL reason=\"verifier approved PR #$PR_NUM but it never merged onto origin/$DEFAULT_BRANCH (closed PR, reopened issue if it had been closed)\""
  fi
else
  # Rejected: close the PR (branch gets recreated fresh on the next attempt
  # anyway) so open-but-abandoned PRs don't pile up across days of retries.
  gh pr close "$PR_NUM" --repo "$REPO_SLUG" --comment "Closing: verifier requested changes — will be re-attempted on a fresh branch." >> "$VERIFY_LOG" 2>&1
  echo "RESULT=FAIL reason=\"${VERDICT_LINE#FAIL: }\""
fi
