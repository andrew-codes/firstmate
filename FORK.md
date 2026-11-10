# This fork's differences from upstream

This is a fork of [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate), maintained by Andrew Smith at [andrew-codes/firstmate](https://github.com/andrew-codes/firstmate).
It adds Bitbucket Cloud support and a few supervision features that upstream does not have, and otherwise tracks upstream.
This page lists every difference so you can see at a glance what is fork-only, and so a sync knows where conflicts can appear.
It describes the fork's `main` and is verified against the code there; the one item that could not be confirmed on real services is flagged in the status column.

Last synced upstream commit: `913bb7a7` (2026-11-09, "fix: recover lost Claude hand-back continuations in herdr (#8317)"), merged by fork PR [#10](https://github.com/andrew-codes/firstmate/pull/10) on 2026-11-10.
The annotated tag `upstream-synced` on the fork points at that commit.
List upstream work not yet merged with `git log upstream-synced..origin/main`, where `origin` is the upstream repository.

## Summary

The fork's own work is 29 files and about 2,350 added lines against upstream `main`: scripts under `bin/`, tests, two skill pages, and the docs listed below.

| Feature | What it does | Status | Where it lives |
| --- | --- | --- | --- |
| [Bitbucket Cloud PR tracking](#bitbucket-cloud-pull-requests) | Records a Bitbucket Cloud pull request as a task's `pr=`, polls it for a merge, and reads its state in crew-state | Tested with fake `twg`, unverified on a live workspace | `bin/fm-pr-lib.sh`, `bin/fm-pr-poll.sh`, `bin/fm-pr-check.sh`, `bin/fm-crew-state.sh` |
| [Bitbucket review threads](#unanswered-bitbucket-review-threads) | Raises unanswered review comments on a recorded Bitbucket PR through the contribution check | Tested with fake `twg`, unverified on a live workspace | `bin/fm-contributions.sh`, `bin/fm-contributions.jq` |
| [Bitbucket PR health monitor](#bitbucket-pr-health-monitor) | Notify-only wake for conflicts, failed merge checks, failed builds, and unresolved threads on an owned Bitbucket PR | Opt-in, tested with fake `twg`, unverified on a live workspace | `bin/fm-pr-health.sh` |
| [Dead-monitor wake](#open-pr-with-no-live-monitor) | Wakes the supervisor once when a PR is open but no no-mistakes run is watching it | Stable | `bin/fm-crew-state.sh`, `bin/fm-inactive-reconcile.sh`, `bin/fm-classify-lib.sh` |
| [Jira status transitions](#jira-status-transitions) | Moves a task's Jira work item to In Progress, Review, or Done as the work progresses | Opt-in, tested with fake `twg-axi`, unverified on a live Jira site | `bin/fm-jira-transition.sh` |
| [Test timing hints](#test-timing-hints) | Measured serial duration hints for scripts that had none | Stable | `bin/fm-test-run.sh` |
| [Upstream sync bookkeeping](#upstream-sync-bookkeeping) | The `upstream-synced` tag and the merge-commit sync procedure | Stable | the tag, fork PR history |

## Features

### Bitbucket Cloud pull requests

Upstream accepts GitHub pull requests, GitLab merge requests, Forgejo pull requests, and Gerrit changes.
The fork also accepts a Bitbucket Cloud pull request URL (`https://bitbucket.org/<workspace>/<repo>/pull-requests/<n>`) wherever a task records its PR.
The fork has it so a Bitbucket-hosted project can use the same PR lifecycle as a GitHub one.

- Provider detection: `bin/fm-pr-lib.sh` parses the URL and sets the provider to `bitbucket`, with a fixed `bitbucket.org` host and a two-segment workspace and repository path.
- Poll: `bin/fm-pr-poll.sh` has a `bitbucket)` branch that wakes only when `twg bb pull-requests get` reports the exact state `MERGED`.
- Check: `bin/fm-pr-check.sh` records the `pr=` and refuses to arm the watch unless `twg` and `jq` are on `PATH`.
- Crew state: `bin/fm-crew-state.sh` reads the pull request's state with a five second bound, so a passed run reads as PR open, merged, or closed (declined).
- Reads go through `twg`, which carries the operator's saved credentials, so firstmate never holds a Bitbucket token.
- No `pr_head=` is recorded for a Bitbucket PR, and `bin/fm-review-diff.sh` diffs the local branch because the forge exposes no pull ref.

Setup needs `twg` and `jq` installed and authenticated; see [`docs/configuration.md`](docs/configuration.md) and the header of [`bin/fm-pr-check.sh`](bin/fm-pr-check.sh).
Known limit: firstmate does not merge a Bitbucket pull request.
`bin/fm-pr-merge.sh` has no Bitbucket branch and refuses such a URL as an invalid merge request, so the captain merges it on Bitbucket and the poll records the merge.
Introduced by commit `89bb9232` ("Record and follow Bitbucket Cloud pull requests"), which reached the fork through PRs [#6](https://github.com/andrew-codes/firstmate/pull/6) and [#7](https://github.com/andrew-codes/firstmate/pull/7).
Tests: `tests/fm-pr-bitbucket.test.sh`.

### Unanswered Bitbucket review threads

The existing contribution check can re-raise a GitHub review thread the author never answered.
The fork extends it to a Bitbucket pull request that a task recorded as its `pr=`.

- Enable it with `FM_CONTRIBUTIONS_REPLY_AGE` (positive integer seconds), or durably with `config/contributions-reply-age`.
- `FM_CONTRIBUTIONS_IGNORE_COMMENTERS`, or `config/contributions-ignore-commenters`, lists commenter names to skip, such as a pipeline bot.
- One `twg` read per pull request replaces the GitHub reads.
- A comment from an app or AI-agent account counts only when anchored to a file and line.
- A Bitbucket pull request is never a coverage row.
- The two config files are new in the fork and also apply to GitHub.
- `fm-contributions.sh` gained read-only `owned bitbucket` and `threads <url>` subcommands, and the `bearings` skill says how to route the wake.

See [`docs/configuration.md`](docs/configuration.md) ("Unanswered review-comment reminder") and the header of [`bin/fm-contributions.sh`](bin/fm-contributions.sh).
Introduced by commit `b9e4eeab` through PR [#7](https://github.com/andrew-codes/firstmate/pull/7), with the inline-bot-comment refinement in PR [#5](https://github.com/andrew-codes/firstmate/pull/5).
Tests: `tests/fm-contributions-bitbucket.test.sh`, `tests/fm-contributions.test.sh`.

### Bitbucket PR health monitor

The opt-in PR health monitor (`config/pr-health-monitor`) is GitHub-only upstream.
The fork adds a Bitbucket reader so an open Bitbucket PR with no live no-mistakes run behind it still wakes supervision.
It is notify-only and never changes a PR.

- A PR is monitored when a live task recorded it as its `pr=`, or a thread-tracking contribution record holds it.
- Each is read through `twg` at most every five minutes.
- It wakes once per latest commit for a git conflict, once per latest commit and check for another failed blocking merge check, and once per latest commit and name for a failed build.
- It wakes once per unresolved review thread, and never while `FM_CONTRIBUTIONS_REPLY_AGE` tracking is on, because that observer raises the thread itself.
- A failed mergeability or thread read skips only that condition and is retried next pass.

Known limits: there is no notification feed or branch discovery, so a PR no task recorded is not found.
The three reads are not anchored to one commit, so a head that moves mid-read can be attributed to the previous head for one pass.
Merge-check kinds are matched by name against the no-mistakes Bitbucket adapter's vocabulary, which was not verified against a live workspace.
See [`docs/configuration.md`](docs/configuration.md) ("PR health monitor").
Introduced by commit `fb122018` through PR [#9](https://github.com/andrew-codes/firstmate/pull/9).
Tests: `tests/fm-pr-health.test.sh`.

### Open PR with no live monitor

When a no-mistakes run leaves a PR open but nothing is watching it, nobody notices conflicts, review feedback, or a PR falling behind.
The fork detects two cases and wakes the supervisor once per open PR:

- A run the daemon marked `ci_monitor_interrupted` (daemon restarted mid-monitor) reads `failed` with the detail `open PR, no live monitor` and the PR URL.
  A merge receipt or a forge read showing the PR merged turns it into `done`, and a closed PR reads `unknown`.
- A run parked at the CI gate after the worker already reported `done: PR <url> checks green` stays `parked` and gains the same detail and PR URL.

The wake is keyed on incarnation, task, state, and PR, so a repeated scan does not re-wake, and an ordinary parked gate stays silent.
Firstmate only detects and surfaces; it never corrects the PR.
The generated no-mistakes brief now also tells the worker that the daemon, not the worker, keeps watching the PR until it merges.
The spelling of the detail lives in one constant, `FM_NO_LIVE_MONITOR` in `bin/fm-classify-lib.sh`.
There is nothing to configure.
Introduced by commit `6789c720` through PR [#8](https://github.com/andrew-codes/firstmate/pull/8).
Tests: `tests/fm-crew-state.test.sh`, `tests/fm-inactive-reconcile.test.sh`, `tests/fm-brief.test.sh`.

### Jira status transitions

An opt-in file, `config/jira-status-transitions`, keeps a Jira work item's status in step with the task that carries it.
Without the file nothing is read or written.
The work item key is the uppercase key in the task's ship branch, such as `fm/PROJ-4240-...`.

- A ship's spawn or relaunch moves the item to In Progress.
- Recording a ready PR, and every heartbeat, move it to Review when the PR is ready and back to In Progress when it is not or is a draft.
- A recorded merge moves it to Done.
- A failed Jira call only warns and never blocks a spawn, a merge, or supervision.

Readiness is read from Bitbucket, so this feature is Bitbucket-specific today.
`bin/fm-jira-transition.sh` owns the commands, including a read-only `ready <task-id>` verdict, and [`docs/configuration.md`](docs/configuration.md) ("Jira status transitions") owns the file format, which is also where the per-project `site=`, `max-behind=`, and `ignore-commenters=` settings are described.
The hooks are one-line calls in `bin/fm-spawn.sh`, `bin/fm-pr-check.sh`, `bin/fm-watch.sh`, and `bin/fm-merge-outcome-lib.sh`.
Introduced by commit `0e528b6a` through PR [#6](https://github.com/andrew-codes/firstmate/pull/6), with lint cleanups in `9a3a178d`, `3d87fb51`, and `4654912f`.
Tests: `tests/fm-jira-transition.test.sh`.

### Test timing hints

`bin/fm-test-run.sh` carries a table of measured serial durations that drives CI sharding.
After the fork merged upstream work, 45 serial scripts had no hint, so commit `f9ab7341` (PR [#9](https://github.com/andrew-codes/firstmate/pull/9)) added measured values from fork CI runs, and [`docs/fm-test-portable-shards.md`](docs/fm-test-portable-shards.md) records the source runs.
Existing hints were left alone.
The table is the file most likely to conflict on a sync, because both sides add adjacent lines; keep every line from both sides.
`bin/fm-test-run.sh --check-coverage` is the check that the table is still adequate.

### Upstream sync bookkeeping

The fork syncs with a regular merge commit, not a rebase: a branch is cut from fork `main`, upstream `main` is merged into it, and the result lands through a fork PR (the latest is [#10](https://github.com/andrew-codes/firstmate/pull/10)).
The annotated, signed tag `upstream-synced` marks the last upstream commit merged, and its message holds the procedure.
Work lands on the fork through a PR against the fork's `main`, opened directly rather than through the no-mistakes pipeline, because that pipeline's gate opens PRs against upstream.
Never push to or open anything against upstream from the fork.

## Behaviour that differs from upstream

These are the places a sync is most likely to conflict or to need a decision.
Resolve a conflict by keeping both intents, as PR [#10](https://github.com/andrew-codes/firstmate/pull/10) did.

| File | What the fork changed | What to check on a sync |
| --- | --- | --- |
| `bin/fm-pr-lib.sh` | A `bitbucket` provider in URL parsing, plus `fm_pr_bitbucket_path_valid` and `fm_pr_bitbucket_read_record` | Upstream changes to provider parsing or the shared record shape |
| `bin/fm-pr-poll.sh` | A `bitbucket)` branch in the poll program | Upstream changes to the byte-static poll program or its other providers |
| `bin/fm-pr-check.sh` | A Bitbucket arming check for `twg` and `jq`, and a Jira reconcile call | Upstream checks added next to it, as with the GitLab degraded-watch `jq` check |
| `bin/fm-crew-state.sh` | A Bitbucket PR read and the interrupted-monitor and parked-gate readings | Upstream changes to run-state reconciliation and `emit_run` |
| `bin/fm-contributions.sh`, `bin/fm-contributions.jq` | Bitbucket thread observation, the reply-age config files, and the `owned` and `threads` subcommands | Upstream changes to the record schema or the reply-age reminder |
| `bin/fm-pr-health.sh` | A Bitbucket reader beside the GitHub path | Upstream changes to the fingerprint record or the GitHub read |
| `bin/fm-inactive-reconcile.sh`, `bin/fm-classify-lib.sh` | One parked exception and the `FM_NO_LIVE_MONITOR` constant | Upstream changes to what wakes on a parked state |
| `bin/fm-dod-lib.sh` | One sentence in the no-mistakes brief about the daemon watching the PR | `tests/fm-brief.test.sh` asserts the wording |
| `bin/fm-spawn.sh`, `bin/fm-watch.sh`, `bin/fm-merge-outcome-lib.sh` | One Jira hook call each | The hook still runs after the surrounding code moves |
| `bin/fm-test-run.sh` | Added hint lines | Keep every line from both sides, then run `--check-coverage` |
| `docs/configuration.md`, `docs/scripts.md`, `docs/architecture.md` | Bitbucket and Jira wording, and the reply-age section | Rows and sentences that upstream edited in the same place |
| `.agents/skills/bearings/SKILL.md`, `.agents/skills/operational-home-layout/SKILL.md` | A Bitbucket thread-routing paragraph and the `pr-health.json` description | Upstream rewording of the same passages |

Two deliberate adaptations are worth knowing before resolving a conflict.
The poll and merge paths treat Bitbucket as read-only: the poll reports a merge, but `bin/fm-pr-merge.sh` refuses Bitbucket.
The Bitbucket contribution check observes review threads only and never produces coverage rows, so upstream's coverage logic must keep ignoring Bitbucket URLs.

## Maintaining this page

When a feature is added to or removed from the fork, update this page in the same PR.
After each upstream sync, review this page against the merged code, fix anything the merge changed, and move the tag with `git tag -f -s -a upstream-synced <sha>` followed by `git push --force fork upstream-synced`, keeping the tag message's procedure.
Fork-only features should be recorded here and not in upstream-owned pages beyond the minimal wording they already carry.

## Not verified

- Every Bitbucket and Jira path was checked against the code and the fork's tests, which use a fake `twg` and `twg-axi`; none was run against a live Bitbucket workspace or Jira site.
- Fork PRs [#1](https://github.com/andrew-codes/firstmate/pull/1) through [#4](https://github.com/andrew-codes/firstmate/pull/4) (earlier Bitbucket forge work, lock ownership under a blocked sandbox, and optional `firstmate.yml` worktree setup) no longer show in the diff against upstream, and this page does not describe them.
  Why they dropped out of the diff was not investigated.
