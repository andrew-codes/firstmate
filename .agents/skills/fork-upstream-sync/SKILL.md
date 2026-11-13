---
name: fork-upstream-sync
description: Load when the captain invokes this skill or asks to sync the fork with upstream, and when a fork-sync PR merges and its Bitbucket gap issues are waiting to be implemented.
user-invocable: true
metadata:
  internal: true
---

# Fork upstream sync

This skill exists only in the fork `andrew-codes/firstmate`.
It keeps the fork current with upstream `kunchenguid/firstmate` and closes the Bitbucket Cloud gaps that new upstream features open.
The firstmate-fork project is registered in this home; every task below is a ship on it.

## Hard boundaries

- Never publish to `kunchenguid/firstmate`: no push, issue, comment, or pull request.
  Every publication in this flow targets `github.com/andrew-codes/firstmate` only.
- Publishing to the fork's own lineage needs the one-task consent: pass `--upstream-consent github.com/andrew-codes/firstmate` on the brief, the spawn, and any promotion of each task.
  The consent is per task and never carries to the next one.
  Load `firstmate-self-repo` first for the gate, and `firstmate-coding-guidelines` for the worker's brief.
- The sync PR is the only automerge.
  Every per-issue PR is reported with its full URL and waits for the captain's explicit word.
- Never skip the review, test or document step of the pipeline in this fork, because the required check rejects a PR whose attestation shows any of them skipped; a skipped lint for a missing host tool is fine.

## Merge authority for the sync PR

The captain's invocation of this skill is the explicit instruction to merge that run's sync PR.
Merge it with `bin/fm-pr-merge.sh` without a further question, only when checks are green.
The authority covers that run's sync PR alone and is never standing; a later run needs a fresh invocation.
If checks are red or a required check has not reported, do not merge: report it to the captain.

## 1. Sync ship

1. Find the upstream work to pull: the `upstream-synced` tag names the last upstream commit merged, and `git log upstream-synced..<upstream main>` lists what is new.
   On the first run the tag does not exist yet; use `git merge-base <fork main> <upstream main>` as the baseline instead.
   Derive it each run; never hardcode SHAs in the brief.
2. Dispatch one ship on firstmate-fork with the project's registered mode, branch prefix, and `--project` as usual, plus the upstream consent above.
   The brief tells the worker to:
   - add a temporary `upstream` remote for `https://github.com/kunchenguid/firstmate.git`, fetch it, and merge new upstream commits into the ship branch, resolving conflicts in favor of keeping both upstream behavior and the fork's features;
   - read `FORK.md` for the fork's Bitbucket Cloud features, then review the newly pulled upstream features and write the gaps to a file under its task data directory, one entry per gap: the upstream feature, what the fork's Bitbucket support lacks for it, and the files involved;
   - remove the `upstream` remote before reporting done, because a leftover upstream remote in the shared clone makes the publication gate refuse every fork task;
   - update the "It is current with upstream through commit `<sha>` (<date>)" line in `FORK.md` to the last upstream commit merged and its date, in the same PR, and leave the rest of `FORK.md` alone unless the sync changes a fork capability a user can see.
3. The worker never creates issues or edits the PR description itself; firstmate does both from its gap file.

## 2. Gap issues and PR description

When the worker reports the PR ready:

1. Create one issue per gap on `andrew-codes/firstmate` with `gh-axi`, using the repo's labels (create `bitbucket-gap` first with `gh-axi label create` when absent).
   Each issue carries the upstream feature, the Bitbucket gap, and the files involved, self-sufficient enough to become a brief's captain intent.
2. Edit the sync PR description so it summarizes the merged upstream range and links every issue by full URL under a "Bitbucket gaps" heading.
   With no gaps, say so in the description and create no issues.
3. Register the PR with `bin/fm-pr-check.sh` as `ship-landing` directs, then merge it per the merge-authority section once checks are green.
4. After the merge, move the `upstream-synced` tag to the last upstream commit merged and push the tag to the fork only:
   `git tag -f -a upstream-synced <upstream sha> -m "last upstream commit merged"`, then `git push --force origin refs/tags/upstream-synced`.
   This creates the tag on the first run.

## 3. Per-issue ships

After the sync PR merges and the fork clone is refreshed, dispatch one ship per gap issue: one issue, one PR.
Each brief's captain intent is the issue's substance, with the issue URL, and the same upstream consent.
Report each ready PR with its full URL and wait for the captain's word; never auto-merge it, whatever the project's yolo posture says.
