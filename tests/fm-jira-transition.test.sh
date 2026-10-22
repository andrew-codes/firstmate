#!/usr/bin/env bash
# Behavioral tests for bin/fm-jira-transition.sh: per-project opt-in, work item key
# derivation, forward and backward status moves, readiness evaluation from a
# Bitbucket pull request, and the cache that keeps repeated calls quiet.
# Jira and Bitbucket are reached only through fake twg-axi and twg executables,
# which reproduce the real CLIs' JSON contract and log every call.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-jira-transition.sh"
TMP_ROOT=$(fm_test_tmproot fm-jira-transition)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
REAL_JQ=$(command -v jq) || fail "these tests read JSON with the real jq, which was not found"

make_case() {  # <name> <branch> [project-basename]
  local name=$1 branch=$2 project=${3:-rovo-chat-desktop} dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$dir/config" "$dir/wt" "$fakebin"
  ln -sf "$REAL_JQ" "$fakebin/jq"
  cat > "$fakebin/twg-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_JIRA_LOG"
[ "${FM_TEST_JIRA_FAIL:-0}" = 0 ] || exit 1
status_file=$FM_TEST_JIRA_STATUS
case "$*" in
  *"jira workitem get"*)
    name=$(cat "$status_file")
    cat=indeterminate
    case "$name" in Done|"CANNOT REPRODUCE") cat=done ;; esac
    jq -n --arg n "$name" --arg c "$cat" '{data:[{status:{name:$n,statusCategory:{key:$c}}}]}'
    ;;
  *"jira workitem transition"*"--transition-id"*)
    args="$*"
    id=${args##*--transition-id }
    id=${id%% *}
    case "$id" in
      2) echo Review > "$status_file" ;;
      21) echo "In Progress" > "$status_file" ;;
      31) echo Done > "$status_file" ;;
    esac
    echo '{"data":{}}'
    ;;
  *"jira workitem transition"*)
    if [ "${FM_TEST_JIRA_NO_REVIEW:-0}" = 1 ]; then
      echo '{"data":{"transitions":[{"id":"21","name":"In Progress","toName":"In Progress"}]}}'
    else
      echo '{"data":{"transitions":[{"id":"2","name":"Review","toName":"Review"},{"id":"21","name":"In Progress","toName":"In Progress"},{"id":"31","name":"Done","toName":"Done"}]}}'
    fi
    ;;
esac
SH
  cat > "$fakebin/twg" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_TWG_LOG"
[ "${FM_TEST_TWG_FAIL:-0}" = 0 ] || exit 1
case "$1 $2 $3" in
  "bb pull-requests get") cat "$FM_TEST_PR_JSON" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/twg-axi" "$fakebin/twg"
  : > "$dir/jira.log"
  : > "$dir/twg.log"
  echo "In Progress" > "$dir/jira-status"
  printf '%s site=product-fabric\n' "$project" > "$dir/config/jira-status-transitions"
  fm_write_meta "$dir/state/task-a.meta" \
    "window=firstmate:fm-task-a" \
    "endpoint_task_id=task-a" \
    "worktree=$dir/wt" \
    "project=$dir/$project" \
    "kind=ship" \
    "mode=direct-PR" \
    "branch=$branch" \
    "pr=https://bitbucket.org/atlassian/rovo-chat-desktop/pull-requests/7"
  write_pr "$dir" OPEN false 0 SUCCESSFUL
  printf '%s\n' "$dir"
}

# write_pr <dir> <state> <draft> <task-count> <build-state> [<comments-json>] [<title>]
write_pr() {
  local dir=$1 state=$2 draft=$3 tasks=$4 build=$5 comments=${6:-[]} title=${7:-CDE-1: a change}
  jq -n --arg state "$state" --argjson draft "$draft" --argjson tasks "$tasks" \
    --arg build "$build" --argjson comments "$comments" --arg title "$title" '
    {state: $state, draft: $draft, title: $title, task_count: $tasks,
     author: {uuid: "{author}", display_name: "Author"},
     source: {commit: {hash: "abc123def456"}}, destination: {branch: {name: "main"}},
     _statuses: [{state: $build}], _comments: $comments}' > "$dir/pr.json"
}

run() {  # <dir> <args...>
  local dir=$1
  shift
  PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_TEST_JIRA_LOG="$dir/jira.log" \
    FM_TEST_JIRA_STATUS="$dir/jira-status" FM_TEST_TWG_LOG="$dir/twg.log" \
    FM_TEST_PR_JSON="$dir/pr.json" "$SCRIPT" "$@"
}

transitions() { grep -c -- '--transition-id' "$1/jira.log" || true; }
jira_status() { cat "$1/jira-status"; }

test_key_derivation() {
  local dir
  dir=$(make_case key fm/CDE-4240-thing)
  [ "$(run "$dir" key fm/CDE-4240-thing)" = CDE-4240 ] || fail "key not derived from an fm/ branch"
  [ "$(run "$dir" key CDE-12)" = CDE-12 ] || fail "key not derived from a bare branch"
  [ -z "$(run "$dir" key fm/NOISSUE-thing)" ] || fail "NOISSUE branch produced a key"
  [ -z "$(run "$dir" key fm/NOISSUE-123-thing)" ] || fail "NOISSUE branch with digits produced a key"
  [ -z "$(run "$dir" key fm/cde-4240-thing)" ] || fail "lowercase key accepted"
  [ -z "$(run "$dir" key fm/plain-thing)" ] || fail "keyless branch produced a key"
  pass "work item keys come from uppercase branch keys and skip NOISSUE and keyless branches"
}

test_skips() {
  local dir
  dir=$(make_case notenabled fm/CDE-1-x other-project)
  printf 'rovo-chat-desktop site=product-fabric\n' > "$dir/config/jira-status-transitions"
  run "$dir" set task-a Review || fail "set exited non-zero for a project that is not enabled"
  [ ! -s "$dir/jira.log" ] || fail "a project that is not enabled reached Jira"
  rm -f "$dir/config/jira-status-transitions"
  run "$dir" set task-a Review || fail "set exited non-zero with no config"
  [ ! -s "$dir/jira.log" ] || fail "an absent config reached Jira"

  dir=$(make_case noissue fm/NOISSUE-thing)
  run "$dir" set task-a Review || fail "set exited non-zero for NOISSUE"
  [ ! -s "$dir/jira.log" ] || fail "a NOISSUE branch reached Jira"
  dir=$(make_case keyless fm/plain)
  run "$dir" set task-a Review || fail "set exited non-zero for a keyless branch"
  [ ! -s "$dir/jira.log" ] || fail "a keyless branch reached Jira"
  pass "a project that is not enabled, a NOISSUE branch, and a keyless branch never reach Jira"
}

test_set_transitions() {
  local dir
  dir=$(make_case forward fm/CDE-9-x)
  run "$dir" set task-a Review || fail "set exited non-zero"
  [ "$(jira_status "$dir")" = Review ] || fail "forward transition did not apply"
  [ "$(transitions "$dir")" = 1 ] || fail "forward transition did not run exactly once"
  grep -q -- '-s product-fabric' "$dir/jira.log" || fail "the configured site was not used"
  : > "$dir/jira.log"
  run "$dir" set task-a Review || fail "repeat set exited non-zero"
  [ ! -s "$dir/jira.log" ] || fail "a repeated set called Jira despite the cache"

  # Back to In Progress, then the already-in-target no-op reads but never writes.
  run "$dir" set task-a "In Progress" || fail "set back exited non-zero"
  [ "$(jira_status "$dir")" = "In Progress" ] || fail "back to In Progress did not apply"
  rm -f "$dir/state/task-a.jira-status"
  : > "$dir/jira.log"
  run "$dir" set task-a "In Progress" || fail "no-op set exited non-zero"
  [ "$(transitions "$dir")" = 0 ] || fail "an item already in the target was transitioned"
  [ -s "$dir/jira.log" ] || fail "the no-op did not read the current status"
  pass "set moves forward and back along offered transitions and is a no-op in the target state"
}

test_done_never_regresses() {
  local dir
  dir=$(make_case done fm/CDE-9-x)
  echo Done > "$dir/jira-status"
  run "$dir" set task-a "In Progress" || fail "set exited non-zero"
  run "$dir" set task-a Review || fail "set exited non-zero"
  [ "$(jira_status "$dir")" = Done ] || fail "a Done item was regressed"
  [ "$(transitions "$dir")" = 0 ] || fail "a Done item was transitioned"
  echo "CANNOT REPRODUCE" > "$dir/jira-status"
  rm -f "$dir/state/task-a.jira-status"
  run "$dir" set task-a "In Progress" || fail "set exited non-zero"
  [ "$(transitions "$dir")" = 0 ] || fail "an item in a Done-category status was transitioned"
  pass "an item already Done is never regressed"
}

test_failures_warn_only() {
  local dir rc=0
  dir=$(make_case failwarn fm/CDE-9-x)
  FM_TEST_JIRA_FAIL=1 run "$dir" set task-a Review 2> "$dir/err" || rc=$?
  [ "$rc" = 0 ] || fail "a Jira failure made set exit non-zero"
  [ -s "$dir/err" ] || fail "a Jira failure was not reported as a warning"
  [ ! -e "$dir/state/task-a.jira-status" ] || fail "a failed transition was cached"
  FM_TEST_JIRA_NO_REVIEW=1 run "$dir" set task-a Review 2> "$dir/err" || fail "an unoffered transition made set exit non-zero"
  grep -q 'offers no transition' "$dir/err" || fail "an unoffered transition was not named"
  [ "$(transitions "$dir")" = 0 ] || fail "a transition the workflow does not offer was attempted"
  pass "Jira failures and unoffered transitions only warn"
}

test_readiness() {
  local dir v replied unreplied
  dir=$(make_case ready fm/CDE-9-x)
  [ "$(run "$dir" ready task-a)" = ready ] || fail "a clean open pull request was not ready: $(run "$dir" ready task-a)"

  write_pr "$dir" OPEN true 0 SUCCESSFUL
  [ "$(run "$dir" ready task-a)" = draft-ready ] || fail "an otherwise ready draft was not reported as draft-ready"
  write_pr "$dir" OPEN true 1 SUCCESSFUL
  [ "$(run "$dir" ready task-a)" = draft ] || fail "a draft with open tasks was not draft"

  write_pr "$dir" OPEN false 2 SUCCESSFUL
  v=$(run "$dir" ready task-a)
  case "$v" in not-ready:*tasks*) ;; *) fail "open tasks did not block readiness: $v" ;; esac
  write_pr "$dir" OPEN false 0 FAILED
  v=$(run "$dir" ready task-a)
  case "$v" in not-ready:*build*) ;; *) fail "a red build status did not block readiness: $v" ;; esac
  write_pr "$dir" OPEN false 0 INPROGRESS
  v=$(run "$dir" ready task-a)
  case "$v" in not-ready:*) ;; *) fail "a pending build status did not block readiness: $v" ;; esac

  unreplied='[{"id":10,"parent":null,"resolution":null,"user":{"uuid":"{rev}","display_name":"Rev"}}]'
  write_pr "$dir" OPEN false 0 SUCCESSFUL "$unreplied"
  v=$(run "$dir" ready task-a)
  case "$v" in not-ready:*thread*) ;; *) fail "a thread without a reply did not block readiness: $v" ;; esac
  replied='[{"id":10,"parent":null,"resolution":null,"user":{"uuid":"{rev}","display_name":"Rev"}},{"id":11,"parent":{"id":10},"user":{"uuid":"{author}","display_name":"Author"}}]'
  write_pr "$dir" OPEN false 0 SUCCESSFUL "$replied"
  [ "$(run "$dir" ready task-a)" = ready ] || fail "a replied thread blocked readiness"
  write_pr "$dir" OPEN false 0 SUCCESSFUL '[{"id":10,"parent":null,"resolution":{"type":"x"},"user":{"uuid":"{rev}","display_name":"Rev"}}]'
  [ "$(run "$dir" ready task-a)" = ready ] || fail "a resolved thread blocked readiness"
  write_pr "$dir" OPEN false 0 SUCCESSFUL '[{"id":10,"parent":null,"resolution":null,"user":{"uuid":"{a}","display_name":"a-bot"}}]'
  printf 'rovo-chat-desktop site=product-fabric ignore-commenters=a-bot\n' > "$dir/config/jira-status-transitions"
  [ "$(run "$dir" ready task-a)" = ready ] || fail "an ignored commenter blocked readiness"

  write_pr "$dir" MERGED false 0 SUCCESSFUL
  [ "$(run "$dir" ready task-a)" = merged ] || fail "a merged pull request was not reported merged"
  write_pr "$dir" OPEN false 0 SUCCESSFUL '[]' 'NOISSUE: a change'
  case "$(run "$dir" ready task-a)" in skip:*NOISSUE*) ;; *) fail "a NOISSUE title was not skipped" ;; esac
  FM_TEST_TWG_FAIL=1 run "$dir" ready task-a > "$dir/out"
  case "$(cat "$dir/out")" in unknown:*) ;; *) fail "an unreadable pull request was not unknown" ;; esac
  pass "readiness requires an open non-draft pull request, green builds, replied threads, and no open tasks"
}

test_behind_limit() {
  local dir v
  dir=$(make_case behind fm/CDE-9-x)
  git -C "$dir/wt" init -q
  git -C "$dir/wt" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m one
  head=$(git -C "$dir/wt" rev-parse HEAD)
  git -C "$dir/wt" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m two
  git -C "$dir/wt" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m three
  git -C "$dir/wt" update-ref refs/remotes/origin/main HEAD
  jq --arg h "$head" '.source.commit.hash = $h' "$dir/pr.json" > "$dir/pr2.json" && mv "$dir/pr2.json" "$dir/pr.json"
  printf 'rovo-chat-desktop site=product-fabric max-behind=5\n' > "$dir/config/jira-status-transitions"
  [ "$(run "$dir" ready task-a)" = ready ] || fail "2 commits behind with a limit of 5 was not ready: $(run "$dir" ready task-a)"
  printf 'rovo-chat-desktop site=product-fabric max-behind=1\n' > "$dir/config/jira-status-transitions"
  v=$(run "$dir" ready task-a)
  case "$v" in not-ready:*behind*) ;; *) fail "2 commits behind with a limit of 1 was ready: $v" ;; esac
  pass "the commits-behind limit gates readiness"
}

test_reconcile() {
  local dir
  dir=$(make_case reconcile fm/CDE-9-x)
  # Ready -> Review.
  run "$dir" reconcile || fail "reconcile exited non-zero"
  [ "$(jira_status "$dir")" = Review ] || fail "a ready pull request did not move the item to Review"
  # Not ready -> back to In Progress.
  write_pr "$dir" OPEN false 1 SUCCESSFUL
  run "$dir" reconcile || fail "reconcile exited non-zero"
  [ "$(jira_status "$dir")" = "In Progress" ] || fail "a not-ready pull request did not move the item back to In Progress"
  # A draft, even otherwise ready, keeps the item In Progress and is never published.
  write_pr "$dir" OPEN true 0 SUCCESSFUL
  run "$dir" reconcile || fail "reconcile exited non-zero"
  [ "$(jira_status "$dir")" = "In Progress" ] || fail "a draft moved the item to Review"
  ! grep -qE 'publish|ready|PUT|POST' "$dir/twg.log" || fail "reconcile wrote to the pull request"
  # Unknown readiness changes nothing.
  echo Review > "$dir/jira-status"
  rm -f "$dir/state/task-a.jira-status"
  : > "$dir/jira.log"
  FM_TEST_TWG_FAIL=1 run "$dir" reconcile || fail "reconcile exited non-zero"
  [ ! -s "$dir/jira.log" ] || fail "an unreadable pull request still moved the item"
  # Steady state makes no Jira call.
  write_pr "$dir" OPEN false 0 SUCCESSFUL
  run "$dir" reconcile
  : > "$dir/jira.log"
  run "$dir" reconcile
  [ ! -s "$dir/jira.log" ] || fail "a steady-state reconcile called Jira"
  # Merged -> Done.
  write_pr "$dir" MERGED false 0 SUCCESSFUL
  run "$dir" reconcile
  [ "$(jira_status "$dir")" = Done ] || fail "a merged pull request did not move the item to Done"
  pass "reconcile moves between In Progress and Review on readiness, keeps drafts In Progress, and finishes at Done"
}

test_merge_outcome_moves_to_done() {
  local dir url=https://bitbucket.org/atlassian/rovo-chat-desktop/pull-requests/7
  dir=$(make_case mergehook fm/CDE-9-x)
  printf 'done: PR %s checks green\n' "$url" > "$dir/state/task-a.status"
  (
    # shellcheck source=bin/fm-merge-outcome-lib.sh
    . "$ROOT/bin/fm-merge-outcome-lib.sh"
    PATH="$dir/fakebin:$BASE_PATH" FM_TEST_JIRA_LOG="$dir/jira.log" FM_TEST_JIRA_STATUS="$dir/jira-status" \
      FM_CONFIG_OVERRIDE="$dir/config" fm_merge_outcome_report "$dir" "$dir/state" task-a "$url" self \
      || fail "the merge outcome was not recorded"
  ) || exit 1
  [ "$(jira_status "$dir")" = Done ] || fail "a recorded merge did not move the item to Done"
  pass "a recorded merge moves the item to Done"
}

test_key_derivation
test_merge_outcome_moves_to_done
test_skips
test_set_transitions
test_done_never_regresses
test_failures_warn_only
test_readiness
test_behind_limit
test_reconcile
