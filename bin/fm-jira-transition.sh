#!/usr/bin/env bash
# Keep a task's Jira work item status in step with the real state of its work.
#
# Opt-in per project through config/jira-status-transitions (docs/configuration.md
# "Jira status transitions"); a project absent from that file is never touched.
# The work item key is the uppercase [A-Z]+-[0-9]+ in the task's recorded branch
# (fm/CDE-4240-...). A branch or pull request title carrying NOISSUE, or a branch
# with no key, has no work item and is skipped.
#
# Targets are the status names In Progress, Review, and Done. A transition runs
# only when the item is not already in the target, never moves an item whose
# status category is already Done, and only along a transition the workflow
# offers from the item's current status. Jira is reached solely through
# `twg-axi -s <site> jira ...`; pull request state is read through the same
# `twg bb pull-requests get` read that bin/fm-pr-merge.sh uses. Only the status
# field is ever written.
#
# The last applied target per task is cached in state/<task-id>.jira-status, so a
# call that would change nothing makes no Jira call. Every failure is a stderr
# warning and a zero exit: a Jira outage never blocks spawn, merge, or
# supervision.
#
# Usage:
#   fm-jira-transition.sh set <task-id> <In Progress|Review|Done>
#       Move the task's item to the named status when its project is enabled.
#   fm-jira-transition.sh ready <task-id>
#       Print the readiness verdict for the task's recorded pull request, read only:
#         ready | draft-ready | draft | not-ready: <reasons> | merged
#         | unknown: <why> | skip: <why>
#       Ready means the pull request is open and not a draft, every reported
#       build status is successful, every comment thread by someone other than
#       the author has a reply or is resolved, no open pull request task remains,
#       the commits-behind count is within the project's max-behind, and the last
#       no-mistakes run finished passed at the pull request's head. draft-ready is
#       a draft that would otherwise be ready; this script only reports it and
#       never publishes the draft.
#   fm-jira-transition.sh reconcile [<task-id>...]
#       Evaluate readiness and move the item: ready -> Review; draft, draft-ready,
#       or not-ready -> In Progress; merged -> Done; unknown or skip -> unchanged.
#       With no task ids, every enabled ship task that has a recorded pull request.
#   fm-jira-transition.sh key <branch>
#       Print the work item key in a branch name, or nothing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONF="$CONFIG/jira-status-transitions"
JIRA_TIMEOUT=${FM_JIRA_TIMEOUT:-30}
RECONCILE_LOCK=''

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

warn() { printf 'fm-jira-transition: %s\n' "$*" >&2; }

meta_get() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Prints the work item key in a branch name; nothing for NOISSUE or keyless.
branch_key() {  # <branch>
  local branch=$1
  case "$branch" in *NOISSUE*) return 0 ;; esac
  if [[ "$branch" =~ (^|/)([A-Z][A-Z0-9]*-[0-9]+)(-|$) ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
  fi
}

# Sets CFG_SITE, CFG_MAX_BEHIND, and CFG_IGNORE for an enabled project; returns
# non-zero when the project is not listed.
CFG_SITE='' CFG_MAX_BEHIND='' CFG_IGNORE=''
project_config() {  # <project-name>
  local name=$1 line first tok
  CFG_SITE='' CFG_MAX_BEHIND='' CFG_IGNORE=''
  [ -f "$CONF" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    # shellcheck disable=SC2086 # whitespace-separated tokens are the format
    set -- $line
    [ "$#" -gt 0 ] || continue
    first=$1
    shift
    [ "$first" = "$name" ] || continue
    for tok in "$@"; do
      case "$tok" in
        site=*) CFG_SITE=${tok#site=} ;;
        max-behind=*) CFG_MAX_BEHIND=${tok#max-behind=} ;;
        ignore-commenters=*) CFG_IGNORE=${tok#ignore-commenters=} ;;
      esac
    done
    [ -n "$CFG_SITE" ] || { warn "config/jira-status-transitions lists $name without site=<site>"; return 1; }
    return 0
  done < "$CONF"
  return 1
}

bounded() {  # <command> <args...>
  fm_nm_bounded "$PWD" "$JIRA_TIMEOUT" "$@"
}

# Task context. Sets T_META, T_BRANCH, T_PROJECT, T_WT, T_KEY; returns 1 with a
# reason on stdout-free stderr only for a malformed id, and 2 when the task is
# simply out of scope (no meta, not a ship, not enabled, no key).
T_META='' T_BRANCH='' T_PROJECT='' T_WT='' T_KEY='' T_SKIP=''
load_task() {  # <task-id>
  local id=$1 kind
  T_SKIP=''
  fm_pr_task_id_valid "$id" || { warn "invalid task id"; return 1; }
  T_META="$STATE/$id.meta"
  [ -f "$T_META" ] || { T_SKIP="no task record"; return 2; }
  kind=$(meta_get "$T_META" kind)
  [ "$kind" = ship ] || { T_SKIP="not a ship task"; return 2; }
  T_BRANCH=$(meta_get "$T_META" branch)
  T_PROJECT=$(meta_get "$T_META" project)
  T_WT=$(meta_get "$T_META" worktree)
  project_config "${T_PROJECT##*/}" || { T_SKIP="project not enabled"; return 2; }
  T_KEY=$(branch_key "$T_BRANCH")
  [ -n "$T_KEY" ] || { T_SKIP="branch carries no work item key"; return 2; }
  return 0
}

# Reads the item's current status into J_NAME and J_CATEGORY.
J_NAME='' J_CATEGORY=''
jira_read_status() {  # <key>
  local out
  J_NAME='' J_CATEGORY=''
  out=$(bounded twg-axi -s "$CFG_SITE" jira workitem get "$1" --fields status \
    -o json --output-summary none 2>/dev/null) || return 1
  J_NAME=$(printf '%s' "$out" | jq -r '.data[0].status.name // empty' 2>/dev/null) || return 1
  J_CATEGORY=$(printf '%s' "$out" | jq -r '.data[0].status.statusCategory.key // empty' 2>/dev/null) || return 1
  [ -n "$J_NAME" ]
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Moves <key> to <target> when needed. Return 0 when the item is in, or is now in,
# an acceptable state; 1 when it could not be read or moved.
jira_apply() {  # <key> <target>
  local key=$1 target=$2 out tid
  jira_read_status "$key" || { warn "could not read the status of $key"; return 1; }
  if [ "$J_CATEGORY" = done ]; then
    return 0
  fi
  if [ "$(lower "$J_NAME")" = "$(lower "$target")" ]; then
    return 0
  fi
  out=$(bounded twg-axi -s "$CFG_SITE" jira workitem transition --id "$key" \
    -o json --output-summary none 2>/dev/null) || { warn "could not list transitions for $key"; return 1; }
  tid=$(printf '%s' "$out" | jq -r --arg t "$(lower "$target")" \
    '[.data.transitions[]? | select((.toName // "" | ascii_downcase) == $t)][0].id // empty' 2>/dev/null) || tid=
  if [ -z "$tid" ]; then
    warn "$key is \"$J_NAME\" and the workflow offers no transition to \"$target\""
    return 1
  fi
  out=$(bounded twg-axi -s "$CFG_SITE" jira workitem transition --id "$key" \
    --transition-id "$tid" -o json --output-summary none 2>/dev/null) \
    || { warn "transition of $key to \"$target\" failed"; return 1; }
  if [ "$(printf '%s' "$out" | jq -r '.ok // true' 2>/dev/null)" = false ]; then
    warn "transition of $key to \"$target\" was refused by Jira"
    return 1
  fi
  printf 'jira: %s %s -> %s\n' "$key" "$J_NAME" "$target" >&2
}

cmd_set() {  # <task-id> <target>
  local id=$1 target=$2 cache rc=0
  case "$target" in 'In Progress'|Review|Done) ;; *) warn "unknown target status \"$target\""; return 0 ;; esac
  load_task "$id" || rc=$?
  [ "$rc" -eq 0 ] || return 0
  cache="$STATE/$id.jira-status"
  if [ "$(cat "$cache" 2>/dev/null)" = "$T_KEY|$target" ]; then
    return 0
  fi
  if jira_apply "$T_KEY" "$target"; then
    printf '%s|%s\n' "$T_KEY" "$target" > "$cache" 2>/dev/null || true
  fi
  return 0
}

# One pull request read, the same twg call bin/fm-pr-merge.sh makes plus comments.
# Sets R_VERDICT; reasons accumulate in R_REASONS.
R_VERDICT='' R_REASONS='' R_TITLE=''
pr_json_fields() {  # <json> <ignore-csv>
  printf '%s' "$1" | jq -r --arg ignore "$2" '
    (if type == "object" and has("data") then .data else . end)
    | (if type == "array" then .[0] else . end) as $p
    | ($ignore | split(",") | map(select(. != ""))) as $skip
    | ($p.author.uuid // $p.author.display_name // "") as $author
    | "state=" + ($p.state // "" | tostring),
      "draft=" + (if ($p.draft | type) == "boolean" then ($p.draft | tostring) else "unverified" end),
      "title=" + ($p.title // "" | tostring | gsub("\n"; " ")),
      "head=" + ($p.source.commit.hash // "" | tostring),
      "dest=" + ($p.destination.branch.name // "" | tostring),
      "tasks=" + (if ($p.task_count | type) == "number" then ($p.task_count | tostring) else "unverified" end),
      "build=" + (if ($p._statuses | type) != "array" then "unverified"
        elif ([$p._statuses[] | select((.state // "") != "SUCCESSFUL")] | length) > 0 then "failing"
        else "clean" end),
      "unreplied=" + (if ($p._comments | type) != "array" then "unverified"
        else ([$p._comments[] | select((.deleted // false) | not)]) as $live
          | [$live[]
              | select(.parent == null and .resolution == null and (.pending // false | not))
              | select((.user.uuid // .user.display_name // "") != $author)
              | select((.user.display_name // "") as $n | ($skip | index($n)) == null)
              | .id as $id
              | select([$live[] | select(.parent.id == $id)] | length == 0)] | length | tostring end)
  ' 2>/dev/null
}

cmd_ready() {  # <task-id>
  local id=$1 rc=0 url json fields line r_state='' r_draft='' r_head='' r_dest='' r_tasks='' r_build='' r_unreplied=''
  local mode behind overview choice run_id run_out run_status run_head nm_branch
  R_VERDICT='' R_REASONS='' R_TITLE=''
  load_task "$id" || rc=$?
  if [ "$rc" -ne 0 ]; then R_VERDICT="skip: ${T_SKIP:-invalid task}"; return 0; fi
  url=$(meta_get "$T_META" pr)
  [ -n "$url" ] || { R_VERDICT="skip: no pull request recorded"; return 0; }
  fm_pr_url_parse "$url" || { R_VERDICT="unknown: unparseable pull request url"; return 0; }
  if [ "$FM_PR_PROVIDER" != bitbucket ]; then
    R_VERDICT="unknown: readiness is read only for Bitbucket pull requests"
    return 0
  fi
  json=$(bounded twg bb pull-requests get "$FM_PR_NUMBER" -w "${FM_PR_PATH%%/*}" -r "${FM_PR_PATH#*/}" \
    --statuses --comments -o json --output-summary none 2>/dev/null) || json=
  [ -n "$json" ] || { R_VERDICT="unknown: pull request unreadable"; return 0; }
  fields=$(pr_json_fields "$json" "$CFG_IGNORE") || fields=
  while IFS= read -r line; do
    case "$line" in
      state=*) r_state=${line#state=} ;;
      draft=*) r_draft=${line#draft=} ;;
      title=*) R_TITLE=${line#title=} ;;
      head=*) r_head=${line#head=} ;;
      dest=*) r_dest=${line#dest=} ;;
      tasks=*) r_tasks=${line#tasks=} ;;
      build=*) r_build=${line#build=} ;;
      unreplied=*) r_unreplied=${line#unreplied=} ;;
    esac
  done <<FIELDS
$fields
FIELDS
  [ -n "$r_state" ] && [ -n "$r_head" ] || { R_VERDICT="unknown: pull request payload unreadable"; return 0; }
  case "$R_TITLE" in *NOISSUE*) R_VERDICT="skip: pull request title carries NOISSUE"; return 0 ;; esac
  case "$r_state" in
    MERGED) R_VERDICT=merged; return 0 ;;
    OPEN) ;;
    *) R_VERDICT="skip: pull request is $r_state"; return 0 ;;
  esac
  for line in "$r_draft" "$r_tasks" "$r_build" "$r_unreplied"; do
    [ "$line" != unverified ] || { R_VERDICT="unknown: a pull request field could not be verified"; return 0; }
  done

  local reasons='' draft=0
  [ "$r_draft" != true ] || draft=1
  [ "$r_tasks" = 0 ] || reasons="$reasons open pull request tasks ($r_tasks);"
  [ "$r_build" = clean ] || reasons="$reasons a build status is not successful;"
  [ "$r_unreplied" = 0 ] || reasons="$reasons review threads without a reply ($r_unreplied);"

  if [ -n "$CFG_MAX_BEHIND" ]; then
    if [ -n "$r_dest" ] && [ -d "$T_WT" ]; then
      bounded git -C "$T_WT" fetch -q origin "$r_dest" >/dev/null 2>&1 || true
      behind=$(git -C "$T_WT" rev-list --count "$r_head..origin/$r_dest" 2>/dev/null) || behind=
      case "$behind" in
        ''|*[!0-9]*) R_VERDICT="unknown: commits-behind could not be counted"; return 0 ;;
      esac
      [ "$behind" -le "$CFG_MAX_BEHIND" ] || reasons="$reasons $behind commits behind (limit $CFG_MAX_BEHIND);"
    else
      R_VERDICT="unknown: commits-behind could not be counted"
      return 0
    fi
  fi

  mode=$(meta_get "$T_META" mode)
  if [ "$mode" = no-mistakes ]; then
    if ! command -v no-mistakes >/dev/null 2>&1 || [ ! -d "$T_WT" ]; then
      R_VERDICT="unknown: no-mistakes run unreadable"
      return 0
    fi
    overview=$(fm_nm_run_checked "$T_WT" 10 axi) || overview=
    choice=$(fm_nm_select_run "$T_BRANCH" "$overview" "$T_WT" 10)
    case "$choice" in
      absent*) reasons="$reasons no no-mistakes run for the branch;" ;;
      selected\|*)
        IFS='|' read -r _ run_id _ <<< "$choice"
        run_out=$(fm_nm_run_checked "$T_WT" 10 axi status --run "$run_id") || run_out=
        run_status=$(fm_nm_strip_quotes "$(fm_nm_field "$run_out" status)")
        run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$run_out" head)")
        nm_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$run_out" branch)")
        if [ -z "$run_out" ] || [ "$nm_branch" != "$T_BRANCH" ] || [ -z "$run_status" ]; then
          R_VERDICT="unknown: no-mistakes run unreadable"
          return 0
        fi
        if [ "$run_status" != completed ]; then
          reasons="$reasons the last no-mistakes run is $run_status;"
        else
          case "$run_head" in
            ''|*[!A-Fa-f0-9]*) R_VERDICT="unknown: no-mistakes run head unreadable"; return 0 ;;
          esac
          case "$r_head" in "$run_head"*) ;; *) case "$run_head" in "$r_head"*) ;; *)
            reasons="$reasons the last no-mistakes run did not cover the pull request head;" ;; esac ;; esac
        fi
        ;;
      *) R_VERDICT="unknown: no-mistakes run unreadable"; return 0 ;;
    esac
  fi

  R_REASONS=$reasons
  if [ "$draft" = 1 ]; then
    if [ -z "$reasons" ]; then R_VERDICT=draft-ready; else R_VERDICT=draft; fi
  elif [ -n "$reasons" ]; then
    R_VERDICT="not-ready:${reasons%;}"
  else
    R_VERDICT=ready
  fi
}

cmd_reconcile_task() {  # <task-id>
  local id=$1 target
  cmd_ready "$id"
  case "$R_VERDICT" in
    ready) target=Review ;;
    draft|draft-ready|not-ready*) target='In Progress' ;;
    merged) target=Done ;;
    *) return 0 ;;
  esac
  cmd_set "$id" "$target"
}

cmd_reconcile() {
  local meta id pid ids=("$@")
  RECONCILE_LOCK="$STATE/.jira-reconcile.lock.d"
  if ! mkdir "$RECONCILE_LOCK" 2>/dev/null; then
    pid=$(cat "$RECONCILE_LOCK/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 0; fi
    rm -rf "$RECONCILE_LOCK"
    mkdir "$RECONCILE_LOCK" 2>/dev/null || return 0
  fi
  printf '%s\n' "$$" > "$RECONCILE_LOCK/pid"
  trap 'rm -rf "$RECONCILE_LOCK"' EXIT
  if [ "${#ids[@]}" -eq 0 ]; then
    [ -f "$CONF" ] || return 0
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      [ -n "$(meta_get "$meta" pr)" ] || continue
      id=${meta##*/}
      ids+=("${id%.meta}")
    done
  fi
  for id in ${ids[@]+"${ids[@]}"}; do
    cmd_reconcile_task "$id" || true
  done
}

main() {
  local sub=${1:-}
  [ "$#" -gt 0 ] && shift
  case "$sub" in
    set) [ "$#" -eq 2 ] || { warn "usage: set <task-id> <status>"; return 0; }; cmd_set "$1" "$2" ;;
    ready)
      [ "$#" -eq 1 ] || { warn "usage: ready <task-id>"; return 0; }
      cmd_ready "$1"
      printf '%s\n' "$R_VERDICT"
      ;;
    reconcile) cmd_reconcile "$@" ;;
    key) [ "$#" -eq 1 ] || { warn "usage: key <branch>"; return 0; }; branch_key "$1"; echo ;;
    *) warn "usage: fm-jira-transition.sh set|ready|reconcile|key"; return 0 ;;
  esac
}

main "$@"
exit 0
