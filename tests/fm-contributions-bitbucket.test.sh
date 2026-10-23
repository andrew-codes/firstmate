#!/usr/bin/env bash
# Unanswered review-thread reminders for Bitbucket pull requests recorded by a
# fleet task (FM_CONTRIBUTIONS_REPLY_AGE in bin/fm-contributions.sh). twg is a
# fake that serves one pull request document, so every case runs the real poll,
# the real fleet snapshot input and the real wake queue.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-contributions-bitbucket)
URL=https://bitbucket.org/myworkspace/my-repo/pull-requests/7
THREAD_URL="$URL/_/diff#comment-101"
T0=2026-09-16T08:00:00Z
HOUR=2026-09-16T09:00:01Z

new_home() { # name: one fleet task whose recorded pr= is a Bitbucket pull request
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin" "$home/root/bin" "$home/wt" "$home/forge"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"
  # Any GitHub read in this suite is a bug: nothing here may reach gh.
  printf '#!/bin/sh\nprintf "gh %%s\\n" "$*" >> "$FORGE/gh.log"\nexit 1\n' > "$home/fakebin/gh"
  cat > "$home/fakebin/twg" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FORGE/twg.log"
[ ! -e "$FORGE/twg-fail" ] || { echo 'twg: request failed' >&2; exit 1; }
case "$1 $2 $3" in
  'bb pull-requests get') cat "$FORGE/pr.json" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$home/fakebin/"* "$home/root/bin/fm-guard.sh"
  : > "$home/forge/twg.log"
  : > "$home/forge/gh.log"
  printf 'worktree=%s/wt\nkind=ship\npr=%s\n' "$home" "$URL" > "$home/state/task-a.meta"
  chmod 600 "$home/state/task-a.meta"
  write_pr "$home" OPEN '[]'
  printf '%s\n' "$home"
}

# write_pr <home> <state> <comments-json>: the document twg prints with --comments
write_pr() {
  jq -n --arg state "$2" --argjson comments "$3" '
    [{state:$state,author:{uuid:"{author}",display_name:"author"},comment_count:($comments | length),_comments:$comments}]' \
    > "$1/forge/pr.json"
}

# comment <id> <user> <created> [parent] [resolved]: one Bitbucket comment
comment() {
  jq -n --argjson id "$1" --arg user "$2" --arg created "$3" --arg parent "${4:-}" --arg resolved "${5:-}" '
    {id:$id,user:({uuid:("{" + $user + "}"),display_name:$user,nickname:$user,type:"user"}
        + (if $user == "rovo-dev" then {type:"app_user",ai_agent:true} else {} end)),
     created_on:($created | sub("Z$"; ".123456+00:00")),updated_on:($created | sub("Z$"; ".123456+00:00")),
     deleted:false,pending:false,content:{raw:"please look"},
     parent:(if $parent == "" then null else {id:($parent | tonumber)} end),
     resolution:(if $resolved == "" then null else {type:"resolution"} end),
     links:{html:{href:("https://bitbucket.org/myworkspace/my-repo/pull-requests/7/_/diff#comment-" + ($id | tostring))}}}'
}

comments() { jq -s . ; }

with_home() {
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CONTRIBUTIONS_NOW="$T0" "$@"
}

poll_at() { # home now [env...]
  local home=$1 now=$2
  shift 2
  with_home "$home" env FM_CONTRIBUTIONS_REPLY_AGE=3600 FM_CONTRIBUTIONS_NOW="$now" "$@" "$ROOT/bin/fm-contributions.sh" poll
}

wake_line() { # the single wake a poll prints, with the key hashed away
  printf '%s\n' "$1" | sed -E 's/contributions task-a [0-9a-f]{64}/contributions task-a KEY/'
}

ack_pending() {
  local home=$1 token
  token=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -er 'first | .token') || fail 'no pending signal to acknowledge'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack task-a "$URL" "$token" || fail 'ack of a Bitbucket signal was refused'
}

reviewer_comment() { comment 101 reviewer "$T0" | comments; }

test_unanswered_thread_is_raised_after_the_age_and_again() {
  local home out
  home=$(new_home raised)
  reviewer_comment > "$home/forge/c.json"
  write_pr "$home" OPEN "$(cat "$home/forge/c.json")"
  out=$(poll_at "$home" 2026-09-16T08:59:00Z) || fail 'poll before the age failed'
  [ -z "$out" ] || fail "a thread younger than the reply age was raised: $out"
  out=$(poll_at "$home" "$HOUR") || fail 'poll at the age failed'
  [ "$(wake_line "$out")" = "contribution-wake: check: contributions task-a KEY unanswered $THREAD_URL 1h" ] \
    || fail "the wake did not name the task, thread URL and age: $out"
  grep -Fq "unanswered $THREAD_URL 1h" "$home/state/.wake-queue" || fail 'the raise never reached the durable wake queue'
  grep -Fq -- '-w myworkspace -r my-repo' "$home/forge/twg.log" || fail 'twg was not addressed by workspace and repository'
  grep -Fq -- '--comments' "$home/forge/twg.log" || fail 'twg was not asked for the comments'
  [ ! -s "$home/forge/gh.log" ] || fail "a Bitbucket poll reached gh: $(cat "$home/forge/gh.log")"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending \
    | jq -e 'length == 1 and .[0].type == "unanswered" and .[0].source == "'"$THREAD_URL"'" and .[0].author == "reviewer"' >/dev/null \
    || fail 'the raise is not one pending signal naming the thread'
  # Acknowledging clears the wake, not the thread: it is raised again one age later.
  ack_pending "$home"
  out=$(poll_at "$home" 2026-09-16T09:30:00Z) || fail 'poll half an age later failed'
  [ -z "$out" ] || fail "the thread was raised again before another reply age: $out"
  out=$(poll_at "$home" 2026-09-16T10:00:02Z) || fail 'poll an age later failed'
  [ "$(wake_line "$out")" = "contribution-wake: check: contributions task-a KEY unanswered $THREAD_URL 2h" ] \
    || fail "the thread was not raised again after a further reply age: $out"
  pass 'an unanswered Bitbucket thread is raised after the age and again after each further age'
}

test_author_reply_answers() {
  local home out
  home=$(new_home answered)
  write_pr "$home" OPEN "$( { comment 101 reviewer "$T0"; comment 102 author 2026-09-16T08:20:00Z 101; } | comments)"
  out=$(poll_at "$home" "$HOUR") || fail 'poll failed'
  [ -z "$out" ] || fail "a thread the author replied to was raised: $out"
  # A reply from a third account answers nothing.
  write_pr "$home" OPEN "$( { comment 101 reviewer "$T0"; comment 102 someone-else 2026-09-16T08:20:00Z 101; } | comments)"
  out=$(poll_at "$home" "$HOUR") || fail 'poll with a third-party reply failed'
  [ "$(wake_line "$out")" = "contribution-wake: check: contributions task-a KEY unanswered $THREAD_URL 1h" ] \
    || fail "a reply from another account answered the thread: $out"
  # A reviewer's later follow-up after the author replied is its own thread comment to answer.
  write_pr "$home" OPEN "$( { comment 101 reviewer "$T0"; comment 102 author 2026-09-16T08:20:00Z 101; comment 103 reviewer 2026-09-16T08:30:00Z 101; } | comments)"
  out=$(poll_at "$home" 2026-09-16T10:00:00Z) || fail 'poll with a follow-up failed'
  printf '%s\n' "$out" | grep -Fq "unanswered https://bitbucket.org/myworkspace/my-repo/pull-requests/7/_/diff#comment-103 1h" \
    || fail "an unanswered reviewer follow-up was not raised: $out"
  printf '%s\n' "$out" | grep -Fq "comment-101" && fail "the answered comment was raised with its follow-up: $out"
  # An author reply clears the raised signal nobody acknowledged.
  jq --argjson reply "$(comment 104 author 2026-09-16T10:10:00Z 101)" '.[0]._comments += [$reply] | .[0].comment_count += 1' \
    "$home/forge/pr.json" > "$home/forge/pr.tmp" && mv "$home/forge/pr.tmp" "$home/forge/pr.json"
  poll_at "$home" 2026-09-16T10:15:00Z >/dev/null || fail 'poll after the reply failed'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 0' >/dev/null \
    || fail 'an author reply did not withdraw the unacknowledged signal'
  pass 'only a reply by the pull request author answers a Bitbucket thread'
}

test_resolved_thread_is_answered() {
  local home out
  home=$(new_home resolved)
  write_pr "$home" OPEN "$( { comment 101 reviewer "$T0" '' yes; comment 102 reviewer 2026-09-16T08:10:00Z 101; } | comments)"
  out=$(poll_at "$home" 2026-09-16T12:00:00Z) || fail 'poll failed'
  [ -z "$out" ] || fail "a resolved thread was raised: $out"
  pass 'a resolved Bitbucket thread is never raised'
}

test_bot_comments_are_ignored() {
  local home out
  home=$(new_home bots)
  write_pr "$home" OPEN "$( { comment 101 iap-pipelines-bot "$T0"; comment 102 rovo-dev "$T0"; } | comments)"
  out=$(poll_at "$home" 2026-09-16T12:00:00Z FM_CONTRIBUTIONS_IGNORE_COMMENTERS=iap-pipelines-bot) || fail 'poll failed'
  [ -z "$out" ] || fail "a configured bot or an app account was raised: $out"
  out=$(poll_at "$home" 2026-09-16T12:00:00Z) || fail 'poll without the ignore list failed'
  printf '%s\n' "$out" | grep -Fq 'comment-101 ' || fail "an unlisted commenter was not raised: $out"
  printf '%s\n' "$out" | grep -Fq 'comment-102 ' && fail "an app account was raised: $out"
  pass 'configured bot commenters and app accounts need no reply'
}

test_merged_pull_request_ends_tracking() {
  local home out reads
  home=$(new_home merged)
  write_pr "$home" OPEN "$(reviewer_comment)"
  poll_at "$home" "$HOUR" >/dev/null || fail 'first poll failed'
  jq -e '.records[0] | (.threads | length) == 1 and (.pending | length) == 1' "$home/data/task-a/contributions.json" >/dev/null \
    || fail 'the open pull request did not track its thread'
  write_pr "$home" MERGED "$(reviewer_comment)"
  out=$(poll_at "$home" 2026-09-16T11:00:00Z) || fail 'poll after the merge failed'
  [ -z "$out" ] || fail "a merged pull request was raised: $out"
  jq -e '.records[0] | .observation.state == "merged" and (.threads | length) == 0 and (.pending | length) == 0' \
    "$home/data/task-a/contributions.json" >/dev/null || fail 'the merge did not end tracking and withdraw the signal'
  reads=$(wc -l < "$home/forge/twg.log")
  poll_at "$home" 2026-09-17T11:00:00Z >/dev/null || fail 'later poll failed'
  [ "$(wc -l < "$home/forge/twg.log")" = "$reads" ] || fail 'a merged pull request was read again'
  home=$(new_home declined)
  write_pr "$home" DECLINED "$(reviewer_comment)"
  out=$(poll_at "$home" "$HOUR") || fail 'poll of a declined pull request failed'
  [ -z "$out" ] || fail "a declined pull request was raised: $out"
  pass 'a merged or declined Bitbucket pull request ends tracking and is not read again'
}

test_unset_setting_reads_nothing() {
  local home out
  home=$(new_home unset)
  write_pr "$home" OPEN "$(reviewer_comment)"
  out=$(with_home "$home" env -u FM_CONTRIBUTIONS_REPLY_AGE FM_CONTRIBUTIONS_NOW=2026-09-20T00:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'unset poll failed'
  [ -z "$out" ] || fail "an unset poll printed: $out"
  [ ! -s "$home/forge/twg.log" ] || fail "an unset poll read Bitbucket: $(cat "$home/forge/twg.log")"
  [ ! -e "$home/data/task-a/contributions.json" ] || fail 'an unset poll wrote a contribution record'
  with_home "$home" env -u FM_CONTRIBUTIONS_REPLY_AGE "$ROOT/bin/fm-contributions.sh" arm --if-owned || fail 'unset arm failed'
  [ ! -e "$home/state/contributions.check.sh" ] || fail 'a Bitbucket-only home armed the check with the setting unset'
  pass 'with the setting unset nothing is read, recorded or armed for Bitbucket'
}

test_arm_and_coverage() {
  local home out
  home=$(new_home arm)
  write_pr "$home" OPEN "$(reviewer_comment)"
  with_home "$home" env FM_CONTRIBUTIONS_REPLY_AGE=3600 FM_CONTRIBUTIONS_IGNORE_COMMENTERS='iap-pipelines-bot,x y' \
    "$ROOT/bin/fm-contributions.sh" arm --if-owned || fail 'arm failed'
  grep -Fq 'FM_CONTRIBUTIONS_REPLY_AGE=3600' "$home/state/contributions.check.sh" || fail 'arm did not plumb the reply age'
  grep -Fq 'FM_CONTRIBUTIONS_IGNORE_COMMENTERS=' "$home/state/contributions.check.sh" || fail 'arm did not plumb the ignored commenters'
  # Armed again without the setting, the check reads nothing.
  with_home "$home" env -u FM_CONTRIBUTIONS_REPLY_AGE "$ROOT/bin/fm-contributions.sh" arm >/dev/null || fail 'unset re-arm failed'
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$HOUR" bash "$home/state/contributions.check.sh") || fail 'check shim failed'
  [ -z "$out" ] && [ ! -s "$home/forge/twg.log" ] || fail "the unset-setting check shim read Bitbucket: $out"
  poll_at "$home" "$HOUR" >/dev/null || fail 'poll failed'
  # Bitbucket threads never become fleet coverage rows or counts.
  with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" || fail 'could not collect contribution input'
  out=$(with_home "$home" env FM_CONTRIBUTIONS_REPLY_AGE=3600 "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) \
    || fail 'snapshot failed'
  printf '%s' "$out" | jq -e '.known == 0 and .unmeasured == 0 and .unreadable_records == 0 and .complete == true and .rows == []' >/dev/null \
    || fail "a Bitbucket pull request changed coverage: $out"
  pass 'arm plumbs the settings and Bitbucket never changes coverage rows'
}

test_failed_read_is_reported_once() {
  local home out
  home=$(new_home failing)
  : > "$home/forge/twg-fail"
  out=$(poll_at "$home" "$HOUR") || fail 'poll with twg down failed'
  [ "$(printf '%s\n' "$out" | grep -c 'observation unavailable for')" = 1 ] || fail "a twg failure was not reported once: $out"
  out=$(poll_at "$home" 2026-09-16T09:10:00Z) || fail 'second failing poll failed'
  [ -z "$out" ] || fail "the same outage was reported twice: $out"
  jq -e '.records[0].error != null' "$home/data/task-a/contributions.json" >/dev/null || fail 'the failed read left no error evidence'
  rm -f "$home/forge/twg-fail"
  write_pr "$home" OPEN "$(reviewer_comment)"
  out=$(poll_at "$home" 2026-09-16T09:20:00Z) || fail 'recovered poll failed'
  printf '%s\n' "$out" | grep -Fq "unanswered $THREAD_URL" || fail "a recovered read did not raise the thread: $out"
  # A response that lists fewer comments than the pull request reports is not a clean read.
  home=$(new_home truncated)
  write_pr "$home" OPEN "$(reviewer_comment)"
  jq '.[0].comment_count = 5' "$home/forge/pr.json" > "$home/forge/pr.tmp" && mv "$home/forge/pr.tmp" "$home/forge/pr.json"
  out=$(poll_at "$home" "$HOUR") || fail 'truncated poll failed'
  printf '%s\n' "$out" | grep -Fq 'observation unavailable' || fail "a truncated comment list passed as a clean read: $out"
  pass 'a failed or truncated Bitbucket read is reported once and never reads as silence'
}

test_github_path_is_unchanged() {
  local home out
  home=$(new_home github)
  write_pr "$home" OPEN "$(reviewer_comment)"
  printf 'worktree=%s/wt\nkind=ship\npr=https://github.com/o/r/pull/8\n' "$home" > "$home/state/task-b.meta"
  chmod 600 "$home/state/task-b.meta"
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$FORGE/gh.log"
case "$*" in
  'pr view '*) printf '{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","reviewDecision":""}\n' ;;
  'api repos/o/r/pulls/8') printf '{"state":"open","user":{"login":"author"},"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"draft":false,"mergeable":true,"merged_at":null}\n' ;;
  'api repos/o/r/pulls/8/comments?'*) printf '[[{"id":31,"user":{"login":"maintainer"},"author_association":"OWNER","body":"Why?","html_url":"https://github.com/o/r/pull/8#discussion_r31","created_at":"2026-09-16T08:00:00Z","updated_at":"2026-09-16T08:00:00Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]]\n' ;;
  'api repos/o/r/pulls/8/reviews?'*|'api repos/o/r/issues/8/comments?'*) printf '[[]]\n' ;;
  'api graphql '*) printf '[{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}]\n' ;;
  'api repos/o/r/commits/'*'/check-runs?'*) printf '[{"check_runs":[]}]\n' ;;
  'api repos/o/r/commits/'*'/statuses?'*) printf '[[]]\n' ;;
  'api repos/o/r') printf '{"permissions":{"push":false}}\n' ;;
  *) exit 1 ;;
esac
SH
  out=$(poll_at "$home" "$HOUR") || fail 'mixed poll failed'
  printf '%s\n' "$out" | grep -Eq '^contribution-wake: check: contributions task-b [0-9a-f]{64}$' \
    || fail "the GitHub comment did not raise its ordinary arrival wake: $out"
  printf '%s\n' "$out" | grep -Fq "contributions task-a" || fail "the Bitbucket thread was not raised beside a GitHub pull request: $out"
  grep -Fq 'api repos/o/r/pulls/8/comments' "$home/forge/gh.log" || fail 'the GitHub pull request was not read through gh'
  grep -Fq 'github.com' "$home/forge/twg.log" && fail 'a GitHub pull request was read through twg'
  jq -e '.records[0].observation.head == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and (.records[0].observation | has("threads") | not)' \
    "$home/data/task-b/contributions.json" >/dev/null || fail 'the GitHub observation shape changed'
  with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" || fail 'could not collect contribution input'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all \
    | jq -e '.known == 1 and (.rows | length) == 1 and .rows[0].url == "https://github.com/o/r/pull/8"' >/dev/null \
    || fail 'coverage rows are not exactly the GitHub pull request'
  pass 'a GitHub pull request is read, shaped and projected as before beside a Bitbucket one'
}

failures=0
for test_name in test_unanswered_thread_is_raised_after_the_age_and_again test_author_reply_answers test_resolved_thread_is_answered test_bot_comments_are_ignored test_merged_pull_request_ends_tracking test_unset_setting_reads_nothing test_arm_and_coverage test_failed_read_is_reported_once test_github_path_is_unchanged; do
  ( "$test_name" ) || failures=$((failures + 1))
done
[ "$failures" -eq 0 ] || fail "$failures Bitbucket contribution regressions"
