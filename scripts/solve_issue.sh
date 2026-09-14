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
PLAN_FILE="WAR_ROOM_PLAN_${ISSUE_NUM}.md"

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

# Resume a previous attempt's real progress instead of always wiping it. A
# worker that gets killed by dispatch.sh's 25-min timeout mid-task used to
# lose everything on the next retry — this script unconditionally deleted
# and recreated the feature branch at the top of every invocation, so a
# worker that was 90% done when the clock ran out started completely over,
# and could hit the same timeout again on the same ground it already
# covered. Only reset fresh when there's nothing to lose: no local/remote
# branch exists, or it exists but has no commits beyond the default branch
# (an empty branch from a worker that never got anywhere). A branch that a
# verifier explicitly REJECTED is deleted at that point (see the
# --delete-branch below) specifically so it can never be mistaken for
# resumable progress here — only an incomplete/timed-out attempt resumes.
(cd "$REPO_DIR" && git fetch origin "$FEATURE_BRANCH") >> "$WORKER_LOG" 2>&1
EXISTING_AHEAD=0
if (cd "$REPO_DIR" && git rev-parse --verify "origin/$FEATURE_BRANCH" >/dev/null 2>&1); then
  (cd "$REPO_DIR" && git checkout -B "$FEATURE_BRANCH" "origin/$FEATURE_BRANCH") >> "$WORKER_LOG" 2>&1
  EXISTING_AHEAD="$(cd "$REPO_DIR" && git rev-list --count "$DEFAULT_BRANCH..$FEATURE_BRANCH" 2>/dev/null || echo 0)"
elif (cd "$REPO_DIR" && git rev-parse --verify "$FEATURE_BRANCH" >/dev/null 2>&1); then
  (cd "$REPO_DIR" && git checkout "$FEATURE_BRANCH") >> "$WORKER_LOG" 2>&1
  EXISTING_AHEAD="$(cd "$REPO_DIR" && git rev-list --count "$DEFAULT_BRANCH..$FEATURE_BRANCH" 2>/dev/null || echo 0)"
fi

RESUME_NOTE=""
if [[ "$EXISTING_AHEAD" =~ ^[0-9]+$ ]] && (( EXISTING_AHEAD > 0 )); then
  PRIOR_LOG="$(cd "$REPO_DIR" && git log --oneline "$DEFAULT_BRANCH..$FEATURE_BRANCH" 2>/dev/null | head -c 2000)"
  PRIOR_PLAN=""
  if [[ -f "$REPO_DIR/$PLAN_FILE" ]]; then
    PRIOR_PLAN="$(cat "$REPO_DIR/$PLAN_FILE" | head -c 3000)"
  fi
  echo "=== resuming existing $FEATURE_BRANCH, $EXISTING_AHEAD commit(s) ahead of $DEFAULT_BRANCH ===" >> "$WORKER_LOG"
  RESUME_NOTE="
IMPORTANT — this branch already has prior work from an earlier attempt that
ran out of time (it was NOT rejected — a rejected attempt's branch is always
deleted, so if you're seeing this, the earlier work was never judged wrong,
just incomplete). Do NOT start over or discard it. Here is what's already
committed:
--- PRIOR COMMITS ---
$PRIOR_LOG
--- END PRIOR COMMITS ---
$( [[ -n "$PRIOR_PLAN" ]] && printf -- '--- PRIOR PLAN FILE (%s), read this first to see what is already checked off ---\n%s\n--- END PRIOR PLAN ---\n' "$PLAN_FILE" "$PRIOR_PLAN" )
Review what's already there — the commits AND the plan file above — then
continue from exactly where the previous attempt left off. Update the plan
file's checkboxes as you go rather than starting a new plan from scratch."
else
  # Checkout DEFAULT_BRANCH first: the block above (lines 123-128) may have
  # just left us sitting ON $FEATURE_BRANCH (an empty/no-progress branch, so
  # we fall into this reset path anyway) — deleting the currently checked-out
  # branch fails with "used by worktree", which then made the subsequent
  # `checkout -b` fail too ("branch already exists"), leaving the worker
  # dispatched into a broken, half-reset git state. Caught live: this exact
  # sequence produced repeated "worker did not commit: no output" failures
  # across an entire repo's issue batch.
  (cd "$REPO_DIR" && git checkout "$DEFAULT_BRANCH") >> "$WORKER_LOG" 2>&1
  (cd "$REPO_DIR" && git branch -D "$FEATURE_BRANCH") >> "$WORKER_LOG" 2>&1
  (cd "$REPO_DIR" && git push origin --delete "$FEATURE_BRANCH") >> "$WORKER_LOG" 2>&1
  (cd "$REPO_DIR" && git checkout -b "$FEATURE_BRANCH") >> "$WORKER_LOG" 2>&1
fi

WORKER_PROMPT="You are working in the git repo at: $REPO_DIR (GitHub: $REPO_SLUG, issue #$ISSUE_NUM).
Task: $ISSUE_PROMPT

IMPORTANT — branch discipline: you are already on a dedicated feature branch
'$FEATURE_BRANCH', based on '$DEFAULT_BRANCH'. Stay on '$FEATURE_BRANCH' —
do not switch to '$DEFAULT_BRANCH' or any other branch. This branch will
become a pull request, not a direct push.

IMPORTANT — you run under a 25-minute timeout, and the tool that picks up a
retry after a timeout may be a DIFFERENT one than you (this pipeline falls
back opencode -> hermes -> agy) with no memory of this conversation. Two
things make that safe:

A) Maintain a plan file at '$PLAN_FILE' in the repo root (git-tracked, on
   this branch). Before writing any code, break the task into a checklist
   of small, concrete subtasks (roughly 5-15 min of work each) and write it
   there as markdown checkboxes, e.g.:
     - [ ] Add pricing.json fetch + local cache
     - [ ] Replace hardcoded model name in parseClaudeUsage
     - [ ] Add --by provider|model|project flags to report command
     - [ ] Unit tests for pricing lookup
   As you finish each subtask, check its box and commit that change along
   with the actual code. If you are the tool that picks this up after a
   previous attempt timed out, READ THIS FILE FIRST (see below if one
   already exists) instead of re-planning from zero — treat unchecked boxes
   as your remaining work, not the whole task.

B) Commit incrementally, not just once at the end: run
   'git add -A && git commit -m \"WIP #$ISSUE_NUM: <what this chunk does>\"'
   after each subtask from the plan file, not only when everything is
   done. Every commit is real progress that survives even if you run out of
   time before finishing — a future retry (by you or a different tool)
   resumes from your last commit and your plan file's checkboxes, not from
   scratch.
$RESUME_NOTE

Do the following yourself, don't ask questions:
1. Read whatever files are relevant.
2. Write/update '$PLAN_FILE' with your subtask checklist (or continue an
   existing one — see above).
3. Write the fix/feature and any tests needed, checking off plan items and
   committing incrementally as described above as you go.
4. Run the project's test/build command if one exists; fix failures yourself.
5. Once everything is complete and tests pass, delete '$PLAN_FILE' (it's
   scratch, not part of the product) and make a final commit:
   git rm $PLAN_FILE && git add -A && git commit -m \"<clear message, reference #$ISSUE_NUM>\"
6. Push the branch: git push -u origin $FEATURE_BRANCH
   Do NOT open a pull request yourself, do NOT touch GitHub issues yet —
   that happens after independent verification.
7. As the LAST line of your output print exactly:
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
  # NOTE: `gh pr view --json merged` is NOT a real field (gh errors with
  # "Unknown JSON field: merged") — this silently failed on every single
  # verification (empty MERGED_INFO after all 3 retries), so `landed` was
  # ALWAYS false regardless of the real outcome. Caught live: PR #8 on cliq
  # genuinely merged, but this bug made the script believe it hadn't, so it
  # reopened the already-fixed issue and tried to close an already-merged
  # PR (which gh correctly refused, "can't be closed because it was already
  # merged"). Every prior "verifier approved but never merged" FAIL on a
  # repo using this code path should be treated as suspect — some of those
  # were likely real merges wrongly reported as failures. Use `state` and
  # `mergedAt`, which actually exist, instead.
  merge_check_ok=false
  for attempt in 1 2 3; do
    MERGED_INFO="$(gh pr view "$PR_NUM" --repo "$REPO_SLUG" --json state,mergeCommit,mergedAt --jq '[(.state=="MERGED"), (.mergeCommit.oid // ""), (.mergedAt // "")] | @tsv' 2>>"$VERIFY_LOG")"
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
  # Rejected: the code itself was judged wrong, not just incomplete — delete
  # the branch, both remote (--delete-branch) and the local clone's copy, so
  # the next attempt's resume-detection (which only resumes a branch with
  # commits ahead of default) can never mistake rejected work for
  # salvageable progress and build on top of it. The local delete matters
  # separately: --delete-branch only removes origin's copy, and this script
  # falls back to checking a local branch by that name if origin has none.
  gh pr close "$PR_NUM" --repo "$REPO_SLUG" --delete-branch --comment "Closing: verifier requested changes — will be re-attempted on a fresh branch." >> "$VERIFY_LOG" 2>&1
  (cd "$REPO_DIR" && git checkout "$DEFAULT_BRANCH" && git branch -D "$FEATURE_BRANCH") >> "$VERIFY_LOG" 2>&1
  echo "RESULT=FAIL reason=\"${VERDICT_LINE#FAIL: }\""
fi
