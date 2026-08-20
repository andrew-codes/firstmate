#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository (workspace/repository on Bitbucket) and PR number are
# passed to the forge's own CLI as separate arguments: gh-axi for GitHub,
# twg for Bitbucket Cloud.
#
# GitHub merge method defaults to --squash when the caller passes none of
# --squash, --merge, --rebase, or --method after the optional -- separator.
# Bitbucket merge strategy defaults to --merge-strategy squash when the caller
# passes no --merge-strategy, matching the same squash-by-default convention
# (twg's own default is merge_commit). Extra args must not override the
# repository (--repo/-R for GitHub, --workspace/-w/--repo/-r for Bitbucket)
# because it comes only from the URL. GitLab merge requests are parsed by
# bin/fm-pr-lib.sh but still refused here; teaching this path about GitLab is
# a separate change.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra forge merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still refuses GitLab; teaching it about GitLab merges is
# a separate change.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
case "$FM_PR_PROVIDER" in
  github|bitbucket) ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac
URL=$FM_PR_URL
PR_PROVIDER=$FM_PR_PROVIDER
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_github_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

caller_has_bitbucket_merge_strategy() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --merge-strategy|--merge-strategy=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*|--workspace|--workspace=*|-w|-w?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

case "$PR_PROVIDER" in
  github)
    merge_args=()
    if ! caller_has_github_merge_method "$@"; then
      merge_args=(--squash)
    fi
    gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
    ;;
  bitbucket)
    merge_args=()
    if ! caller_has_bitbucket_merge_strategy "$@"; then
      merge_args=(--merge-strategy squash)
    fi
    twg bitbucket pull-requests merge --pull-request "$PR_NUMBER" \
      --workspace "$PR_OWNER" --repo "$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
    ;;
esac
