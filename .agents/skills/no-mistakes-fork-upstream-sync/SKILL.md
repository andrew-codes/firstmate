---
name: no-mistakes-fork-upstream-sync
description: Load when the captain invokes this skill or asks to sync the no-mistakes fork with upstream, and when a no-mistakes fork-sync PR merges and its Bitbucket gap issues are waiting to be implemented.
user-invocable: true
metadata:
  internal: true
---

# No-mistakes fork upstream sync

This skill exists only in the fork `andrew-codes/firstmate`.
It keeps the captain's no-mistakes fork `andrew-codes/no-mistakes` current with upstream `kunchenguid/no-mistakes` and closes the Bitbucket Cloud gaps that new upstream features open.
Every task below is a ship on the `no-mistakes-fork` project, whose only remote is the fork, so its pipeline opens PRs against the fork's main.
Never use the separate `no-mistakes` project: it targets upstream.

## Hard boundaries

- Never publish to `kunchenguid/no-mistakes`: no push, issue, comment, or pull request.
  Every publication in this flow targets `github.com/andrew-codes/no-mistakes` only.
- Publishing to the fork's own lineage may need a one-task consent: when `bin/fm-spawn.sh` refuses a publishing contract this home's role does not authorize, pass the consent it names as `--upstream-consent <host>/<owner>/<repo>` on the brief, the spawn, and any promotion of that task.
  The consent is per task and never carries to the next one.
  Load `firstmate-self-repo` first for the gate.
- The sync PR is the only automerge.
  Every per-issue PR is reported with its full URL and waits for the captain's explicit word.

## Merge authority for the sync PR

The captain's invocation of this skill is the explicit instruction to merge that run's sync PR.
Merge it with `bin/fm-pr-merge.sh` without a further question, only when checks are green.
The authority covers that run's sync PR alone and is never standing; a later run needs a fresh invocation.
If checks are red or a required check has not reported, do not merge: report it to the captain.

## 1. Sync ship

1. Find the upstream work to pull: the `upstream-synced` tag on the fork names the last upstream commit merged, and `git log upstream-synced..<upstream main>` lists what is new.
   If the tag is absent, use `git merge-base <fork main> <upstream main>` as the baseline instead.
   Derive it each run; never hardcode SHAs in the brief.
2. Dispatch one ship on `no-mistakes-fork` with the project's registered mode, branch prefix, and `--project` as usual, plus any consent from the hard boundaries.
   The brief tells the worker to:
   - add a temporary `upstream` remote for `https://github.com/kunchenguid/no-mistakes.git`, fetch it, and merge new upstream commits into the ship branch, resolving conflicts in favor of keeping both upstream behavior and the fork's features;
   - read `FORK.md` for the fork's Bitbucket Cloud features, then compare the newly pulled upstream capabilities against the fork's Bitbucket provider surface, and write the gaps to a file under its task data directory, one entry per gap: the upstream feature, what the fork's Bitbucket support lacks for it, and the files involved;
   - run the fork's full build, lint, and test suite locally, as its `AGENTS.md` and `Makefile` direct, because this is a Go project and a merge can break what neither side broke alone;
   - let the no-mistakes pipeline's review, test, and document steps complete and never answer them with skip, because the fork's required check rejects a run with a skipped step; skipping lint only because a host tool is missing is fine;
   - remove the `upstream` remote before reporting done, because a leftover upstream remote in the shared clone makes the publication gate refuse every fork task;
   - update the "Last synced with upstream: `<short sha>` (<date>)." line in `FORK.md` to the last upstream commit merged and its date, in the same PR, and leave the rest of `FORK.md` alone unless the sync changes a fork capability a user can see.
3. Title the sync PR so the fork's release labeler recognizes it, for example `Merge upstream kunchenguid/no-mistakes main (<short sha>) into fork main`; the fork's release notes then list it as one line under "Synced with upstream".
   A sync counts as a patch release; the captain adds `minor` to the PR by hand when it brings features the fork version should reflect.
   Releases themselves are the captain's: never publish the draft release.
4. The worker never creates issues or edits the PR description itself; firstmate does both from its gap file.

## 2. Gap issues and PR description

When the worker reports the PR ready:

1. Create one issue per gap on `andrew-codes/no-mistakes` with `gh-axi`, using the repo's labels (create `bitbucket-gap` first with `gh-axi label create` when absent).
   Each issue carries the upstream feature, the Bitbucket gap, and the files involved, self-sufficient enough to become a brief's captain intent.
2. Edit the sync PR description so it summarizes the merged upstream range and links every issue by full URL under a "Bitbucket gaps" heading.
   Keep the pipeline-generated `## Pipeline` section intact, because replacing the whole body makes the required check fail; add to the body rather than rewriting it.
   With no gaps, say so in the description and create no issues.
3. Register the PR with `bin/fm-pr-check.sh` as `ship-landing` directs, then merge it per the merge-authority section once checks are green.
4. After the merge, move the `upstream-synced` tag to the last upstream commit merged and push the tag to the fork only:
   `git tag -f -a upstream-synced <upstream sha> -m "last upstream commit merged"`, then `git push --force origin refs/tags/upstream-synced`.

## 3. Per-issue ships

After the sync PR merges and the fork clone is refreshed, dispatch one ship per gap issue: one issue, one PR.
Each brief's captain intent is the issue's substance, with the issue URL, plus any consent from the hard boundaries, and the same no-skip rule for the pipeline's review, test, and document steps.
Report each ready PR with its full URL and wait for the captain's word; never auto-merge it, whatever the project's yolo posture says.
