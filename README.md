# AI War Room Orchestrator

A fully autonomous pipeline that continuously improves a curated set of GitHub
repositories, 24/7, using **free/heavy local AI CLIs** for all the actual
research, coding, and code review — with a thin orchestration layer handling
dispatch, fallback, fairness, safety caps, self-healing, and independent
verification.

The design goal: an LLM (originally Claude, dispatching) should never spend
its own token budget writing code or reviewing diffs here. It only ever
reads a handful of short structured result lines and makes small control-flow
decisions (which repo next, which issue next, is the daily cap hit). All the
heavy lifting — competitor research, issue drafting, implementation, testing,
code review, merging — is offloaded to three local agent CLIs running a
strict fallback chain, with everything written back to GitHub for real:
commits, pull requests, reviews, merges, issue close/reopen.

## Why this exists

Three problems drove the design, each learned the hard way during real runs:

- **A hung dispatch shouldn't freeze everything.** The pipeline runs strictly
  sequentially (an earlier 3-way-concurrent version crashed the machine under
  memory pressure). One stuck local-model call used to block every repo
  behind it indefinitely — it happened for real, 30+ hours once. Every
  dispatch is now wrapped in `timeout --kill-after=30`.
- **A verifier's self-report is not proof.** Early on, an AI "verifier" tool
  reported `git push` and `gh issue close` succeeded — and GitHub's own API
  said otherwise. Issues were closing for fixes that only ever existed in a
  local clone. Every claimed success is now independently re-checked against
  GitHub's actual state before being trusted.
- **A silent crash is worse than a slow one.** The orchestrator loop has died
  silently more than once with nothing noticing for hours. It now runs under
  a cron watchdog that relaunches it within 5 minutes of any crash, survives
  reboots, and self-repairs corrupted state files instead of hard-failing.

## How it works

```
continuous_runner.sh   loops forever over every non-skipped repo in repos.json
  └─ council_and_issues.sh   (per repo, at most once/24h)
       one dispatch: research competitors, run a 5-advisor LLM council,
       draft 3-8 concrete issues, file them on GitHub itself (gh issue create)
  └─ run_queue.sh   (per repo, per lap)
       fetches open `war-room`-labeled issues, sorted by issue number
       (not GitHub's recency order — see "fairness" below), respects the
       daily dispatch cap, dispatches solve_issue.sh for each
       └─ solve_issue.sh   (per issue)
            1. WORKER dispatch: reads the code, writes the fix + tests,
               commits and pushes to a fresh feature branch
               (war-room-issue-<N>)
            2. opens a pull request itself (gh pr create, base = repo's
               real default branch, body includes "Closes #<N>")
            3. VERIFIER dispatch (a different tool than the worker, for
               independence): checks the diff against acceptance criteria,
               runs tests, then either:
               - approves the PR (gh pr review --approve) and merges it
                 (gh pr merge --squash) — issue auto-closes via the
                 "Closes #N" link, or
               - requests changes (gh pr review --request-changes) and
                 leaves everything open
            4. independently re-fetches the remote and confirms the merge
               commit is actually an ancestor of origin's default branch
               before trusting a PASS — see "no self-reported success" below
```

### Fallback chain (`dispatch.sh`)

Every dispatch tries `opencode` → `hermes` → `agy` in a rotated order (so
concurrent-ish load spreads across tools issue-to-issue), each wrapped in a
timeout. A tool that exits 0 but hit a known internal degradation signature
(e.g. a payload-too-large ceiling with no real output) is treated as a
failure and falls through to the next tool rather than being accepted as a
false "OK".

### Fairness (`run_queue.sh`)

Issues are processed in ascending issue-number order, not GitHub's default
recency order — a chronically-failing issue would otherwise keep bubbling to
the top and hog every dispatch slot near the daily cap ceiling, starving
every other open issue. A per-issue consecutive-failure counter
(`state/_issue_fail_counts.json`) auto-blocks an issue after 3 straight
failures so it stops eating slots, but is periodically reset when a repo
gets a fresh council pass, so a blocked issue isn't stuck forever with no
re-evaluation path.

### No self-reported success (`solve_issue.sh`)

Nothing GitHub-visible is ever trusted on the dispatched tool's word alone.
A claimed merge is re-verified against the actual remote branch tip via
`git fetch` + `git merge-base --is-ancestor` before the pipeline calls it a
real PASS. If a verifier approved a PR but it never actually landed, the PR
is closed and the issue is reopened (if it had been closed) with an
explanatory comment — automatically, no human needed to notice.

### Self-healing (`watchdog.sh` + cron)

- `@reboot` and `*/5 * * * *` cron entries relaunch `continuous_runner.sh` if
  it isn't running — `flock`-guarded so overlapping cron ticks can't launch
  duplicates.
- Corrupted or missing state files (`_daily_cap.json`,
  `_issue_fail_counts.json`) are detected, backed up, and reset to a safe
  default instead of crashing the pipeline with a bash arithmetic error.
- Transient network failures (a flaky `git fetch`/`pull` during branch setup
  or push verification) are retried 3x with backoff before being treated as
  a real failure — a network blip shouldn't cost an issue a strike against
  its fail-count budget, or cause a false negative on an actually-successful
  merge.
- Log rotation (compress after 7 days, delete after 30) keeps `logs/` from
  growing unbounded across months of continuous operation.
- A graceful termination signal to the runner kills its whole process group,
  so a restart never leaves an orphaned in-flight dispatch behind holding a
  repo's lock.

### Daily dispatch cap (self-imposed)

`state/_daily_cap.json` is a soft, self-imposed throttle — not a read of any
real provider quota. If the cap is hit mid-run, the pipeline extends it by
exactly +1 at a time (never a jump), up to +20 extensions per day, then
pauses dispatch until the date rolls over. A batch already running is never
aborted mid-way.

## Repo selection (`repos.json`)

Each entry has a `status`: `pending` (queued for council + solve),
`piloting` (further along, being watched more closely), or `skipped`
(explicitly excluded — empty/placeholder repos, pure toy/practice scripts
with no product ambition, duplicates, or repos that turned out to be close
reimplementations of someone else's open-source project rather than
original work). The list is periodically re-audited by hand, not just by
GitHub metadata (stars/description) — several genuinely substantial
codebases were nearly excluded early on because they lacked a GitHub
description, until their actual file trees were checked.

## Models pinned per tool

- **opencode** → `opencode/big-pickle` — opencode's own hosted default;
  nearly every NVIDIA passthrough model tested on this account was
  EOL/404/hanging.
- **hermes** → `nvidia/nemotron-3.5-lightning-30b-a3b`
- **agy** → `gemini-3.1-pro-low`, `--effort low` — rate-limited, kept as the
  last resort in the fallback chain rather than a primary.

## Council methodology

`skills/llm-council-skill.md` is a 5-advisor council methodology (based on
Karpathy's LLM Council idea, adapted): independent advisor perspectives,
anonymous peer review, then a chairman synthesis — run entirely inside a
single dispatched tool call (no sub-agents), pasted into the prompt when
`COUNCIL=1` is set.

## Known limits

- Local tool capacity is "effectively unlimited" as an observation, not a
  guarantee — their backends can throttle independently at any time.
- `agy` is genuinely rate-limited (5-6h session + weekly) and deliberately
  kept last in the fallback order.
- The worst-case latency for a single fully-exhausted dispatch (all 3 tools
  time out) is bounded but not small — a deliberate safety/thoroughness
  tradeoff over raw throughput.

## Layout

```
scripts/
  continuous_runner.sh   the forever-loop over all repos
  run_queue.sh            per-repo issue queue + fairness/fail-tracking
  solve_issue.sh          per-issue worker -> PR -> verifier -> merge flow
  dispatch.sh             the opencode/hermes/agy fallback chain
  council_and_issues.sh   competitor research + issue filing
  watchdog.sh             cron-driven crash recovery + log rotation
state/                    runtime counters (gitignored — machine-local)
logs/                     per-dispatch audit logs (gitignored)
repos.json                the curated repo list + status
skills/llm-council-skill.md
```
