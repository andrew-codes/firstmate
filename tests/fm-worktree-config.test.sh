#!/usr/bin/env bash
# tests/fm-worktree-config.test.sh - firstmate.yml parsing
# (bin/fm-worktree-config-lib.sh): copy_files and post_create.
#
# Every malformed case is checked by capturing the function's stdout through
# `$(...)` (a real subshell) and reading its exit status, exactly like every
# production call site does - never through a global variable, since a
# variable a function sets inside that kind of subshell is discarded when the
# subshell returns (the exact bug this lib's design note warns about).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-worktree-config-lib.sh
. "$ROOT/bin/fm-worktree-config-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worktree-config)

write_yml() {  # <path> <content>
  printf '%s' "$2" > "$1"
}

test_absent_file_is_not_an_error() {
  local path="$TMP_ROOT/absent/firstmate.yml"
  local out rc
  out=$(fm_worktree_config_copy_files "$path"); rc=$?
  [ "$rc" -eq 0 ] || fail "an absent file must report success, got exit $rc"
  [ -z "$out" ] || fail "expected no copy_files from an absent file, got: $out"
  out=$(fm_worktree_config_post_create "$path"); rc=$?
  [ "$rc" -eq 0 ] || fail "an absent file must report success (post_create), got exit $rc"
  [ -z "$out" ] || fail "expected no post_create from an absent file, got: $out"
  pass "worktree-config: an absent firstmate.yml yields nothing and success"
}

test_valid_copy_files_and_post_create() {
  local dir path out rc
  dir="$TMP_ROOT/valid"; mkdir -p "$dir"
  path="$dir/firstmate.yml"
  write_yml "$path" '# setup
copy_files:
  - .env
  - .env.local
post_create: scripts/dev-setup.sh
'
  out=$(fm_worktree_config_copy_files "$path"); rc=$?
  [ "$rc" -eq 0 ] || fail "valid copy_files reported failure, exit $rc"
  [ "$out" = "$(printf '.env\n.env.local')" ] || fail "copy_files mismatch: got [$out]"
  out=$(fm_worktree_config_post_create "$path"); rc=$?
  [ "$rc" -eq 0 ] || fail "valid post_create reported failure, exit $rc"
  [ "$out" = "scripts/dev-setup.sh" ] || fail "post_create mismatch: got [$out]"
  pass "worktree-config: valid copy_files and post_create parse correctly"
}

test_quoted_values_are_trimmed() {
  local dir path out
  dir="$TMP_ROOT/quoted"; mkdir -p "$dir"
  path="$dir/firstmate.yml"
  write_yml "$path" 'copy_files:
  - ".env"
post_create: "yarn install"
'
  out=$(fm_worktree_config_copy_files "$path")
  [ "$out" = ".env" ] || fail "quoted copy_files entry not trimmed: got [$out]"
  out=$(fm_worktree_config_post_create "$path")
  [ "$out" = "yarn install" ] || fail "quoted post_create not trimmed: got [$out]"
  pass "worktree-config: quoted scalar values are trimmed"
}

test_path_traversal_entry_is_rejected() {
  local dir path out rc
  dir="$TMP_ROOT/traversal"; mkdir -p "$dir"
  path="$dir/firstmate.yml"
  write_yml "$path" 'copy_files:
  - ../../.ssh/id_rsa
'
  out=$(fm_worktree_config_copy_files "$path" 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] || fail "a path-traversal copy_files entry must report failure"
  [ -z "$out" ] || fail "a path-traversal copy_files entry must never be printed, got: $out"
  pass "worktree-config: a path-traversal copy_files entry is rejected, not silently followed"
}

test_absolute_path_entry_is_rejected() {
  local dir path out rc
  dir="$TMP_ROOT/absolute"; mkdir -p "$dir"
  path="$dir/firstmate.yml"
  write_yml "$path" 'copy_files:
  - /etc/passwd
'
  out=$(fm_worktree_config_copy_files "$path" 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] || fail "an absolute copy_files entry must report failure"
  [ -z "$out" ] || fail "an absolute copy_files entry must never be printed, got: $out"
  pass "worktree-config: an absolute copy_files entry is rejected"
}

test_nested_path_entry_is_rejected() {
  local dir path out rc
  dir="$TMP_ROOT/nested"; mkdir -p "$dir"
  path="$dir/firstmate.yml"
  write_yml "$path" 'copy_files:
  - config/.env
'
  out=$(fm_worktree_config_copy_files "$path" 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] || fail "a nested-path copy_files entry must report failure"
  [ -z "$out" ] || fail "a nested-path copy_files entry must never be printed, got: $out"
  pass "worktree-config: a nested-directory copy_files entry is rejected"
}

test_duplicate_post_create_is_rejected() {
  local dir path rc
  dir="$TMP_ROOT/dup"; mkdir -p "$dir"
  path="$dir/firstmate.yml"
  write_yml "$path" 'post_create: yarn install
post_create: npm install
'
  fm_worktree_config_post_create "$path" > /dev/null 2>/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "a duplicate post_create key must report failure"
  pass "worktree-config: a duplicate post_create key is rejected"
}

test_empty_post_create_value_is_rejected() {
  local dir path rc
  dir="$TMP_ROOT/empty-post-create"; mkdir -p "$dir"
  path="$dir/firstmate.yml"
  write_yml "$path" 'post_create:
'
  fm_worktree_config_post_create "$path" > /dev/null 2>/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "an empty post_create value must report failure"
  pass "worktree-config: an empty post_create value is rejected"
}

test_file_with_neither_key_is_not_an_error() {
  local dir path out rc
  dir="$TMP_ROOT/neither"; mkdir -p "$dir"
  path="$dir/firstmate.yml"
  write_yml "$path" '# nothing here yet
'
  out=$(fm_worktree_config_copy_files "$path"); rc=$?
  [ "$rc" -eq 0 ] || fail "a file with neither key must report success"
  [ -z "$out" ] || fail "expected no copy_files, got: $out"
  out=$(fm_worktree_config_post_create "$path"); rc=$?
  [ "$rc" -eq 0 ] || fail "a file with neither key must report success (post_create)"
  [ -z "$out" ] || fail "expected no post_create, got: $out"
  pass "worktree-config: a file with neither key is valid and produces nothing"
}

test_list_ends_at_next_unindented_content() {
  local dir path out
  dir="$TMP_ROOT/list-end"; mkdir -p "$dir"
  path="$dir/firstmate.yml"
  write_yml "$path" 'copy_files:
  - .env
post_create: yarn install
'
  out=$(fm_worktree_config_copy_files "$path")
  [ "$out" = ".env" ] || fail "copy_files must stop at post_create, got: $out"
  out=$(fm_worktree_config_post_create "$path")
  [ "$out" = "yarn install" ] || fail "post_create mismatch: got [$out]"
  pass "worktree-config: the copy_files list ends at the next top-level key"
}

test_absent_file_is_not_an_error
test_valid_copy_files_and_post_create
test_quoted_values_are_trimmed
test_path_traversal_entry_is_rejected
test_absolute_path_entry_is_rejected
test_nested_path_entry_is_rejected
test_duplicate_post_create_is_rejected
test_empty_post_create_value_is_rejected
test_file_with_neither_key_is_not_an_error
test_list_ends_at_next_unindented_content
