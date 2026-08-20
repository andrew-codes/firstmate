#!/usr/bin/env bash
# Tests for bin/fm-project-mode.sh: the registry-posture resolver every
# mechanical consumer (fm-fleet-sync.sh, fm-home-seed.sh, fm-spawn.sh) trusts
# for "<mode> <yolo>" on stdout. forge= is a new orthogonal bracket token
# (AGENTS.md-adjacent grammar owned by this script's own header), read only
# through the additive --forge flag so the default two-word contract, and
# every existing mechanical consumer that depends on it, is unaffected.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-mode)

make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/data"
  printf '%s\n' "$dir"
}

run_mode() {
  local dir=$1
  shift
  FM_DATA_OVERRIDE="$dir/data" "$PROJECT_MODE" "$@"
}

test_default_forge_for_legacy_entries() {
  local dir out
  dir=$(make_case legacy)
  cat > "$dir/data/projects.md" <<'EOF'
- bare-project - a legacy entry with no brackets at all (added 2026-01-01)
- bracketed-project [no-mistakes +yolo] - a legacy entry with brackets but no forge token (added 2026-01-01)
EOF
  out=$(run_mode "$dir" --forge bare-project) || fail "legacy: --forge failed for a bracket-less entry"
  [ "$out" = github ] || fail "legacy: bracket-less entry did not default to forge=github"
  out=$(run_mode "$dir" --forge bracketed-project) || fail "legacy: --forge failed for a bracketed entry"
  [ "$out" = github ] || fail "legacy: bracketed entry with no forge token did not default to forge=github"
  out=$(run_mode "$dir" bare-project) || fail "legacy: default output failed"
  [ "$out" = "no-mistakes off" ] || fail "legacy: default two-word output changed for a bracket-less entry"
  out=$(run_mode "$dir" bracketed-project) || fail "legacy: default output failed for a bracketed entry"
  [ "$out" = "no-mistakes on" ] || fail "legacy: default two-word output changed for a bracketed entry"
  pass "every existing registry entry shape still defaults to forge=github and an unchanged two-word default"
}

test_forge_bitbucket_various_token_orders() {
  local dir out
  dir=$(make_case token-orders)
  cat > "$dir/data/projects.md" <<'EOF'
- mode-first [no-mistakes forge=bitbucket +yolo] - mode then forge then yolo (added 2026-01-01)
- forge-only [forge=bitbucket] - forge with no explicit mode or yolo (added 2026-01-01)
- yolo-first [no-mistakes +yolo forge=bitbucket] - yolo before forge (added 2026-01-01)
EOF
  out=$(run_mode "$dir" --forge mode-first) || fail "token-orders: --forge failed"
  [ "$out" = bitbucket ] || fail "token-orders: mode-then-forge-then-yolo did not resolve forge=bitbucket"
  out=$(run_mode "$dir" mode-first) || fail "token-orders: default output failed"
  [ "$out" = "no-mistakes on" ] || fail "token-orders: forge token corrupted mode/yolo resolution"

  out=$(run_mode "$dir" --forge forge-only) || fail "token-orders: --forge failed for forge-only entry"
  [ "$out" = bitbucket ] || fail "token-orders: forge-only entry did not resolve forge=bitbucket"
  out=$(run_mode "$dir" forge-only) || fail "token-orders: default output failed for forge-only entry"
  [ "$out" = "no-mistakes off" ] || fail "token-orders: forge-only entry should default mode/yolo unaffected"

  out=$(run_mode "$dir" --forge yolo-first) || fail "token-orders: --forge failed for yolo-first entry"
  [ "$out" = bitbucket ] || fail "token-orders: yolo-before-forge did not resolve forge=bitbucket"
  out=$(run_mode "$dir" yolo-first) || fail "token-orders: default output failed for yolo-first entry"
  [ "$out" = "no-mistakes on" ] || fail "token-orders: yolo-before-forge corrupted mode/yolo resolution"
  pass "forge=bitbucket resolves regardless of its position among mode and +yolo tokens"
}

test_unknown_forge_falls_back_to_github() {
  local dir out err rc
  dir=$(make_case unknown-forge)
  cat > "$dir/data/projects.md" <<'EOF'
- typo-project [no-mistakes forge=gitlab] - an unregistered forge token (added 2026-01-01)
EOF
  set +e
  out=$(run_mode "$dir" --forge typo-project 2> "$dir/stderr")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "unknown-forge: --forge should still exit 0 after falling back"
  [ "$out" = github ] || fail "unknown-forge: unrecognized forge token did not fall back to github"
  err=$(cat "$dir/stderr")
  case "$err" in
    *'unknown forge "gitlab"'*) ;;
    *) fail "unknown-forge: no warning was printed for an unrecognized forge token" ;;
  esac
  pass "an unrecognized forge token warns and falls back to github rather than propagating a typo"
}

test_missing_project_and_missing_registry_default_forge() {
  local dir out
  dir=$(make_case missing-project)
  cat > "$dir/data/projects.md" <<'EOF'
- other-project [forge=bitbucket] - unrelated entry (added 2026-01-01)
EOF
  out=$(run_mode "$dir" --forge nonexistent-project 2>/dev/null) \
    || fail "missing-project: --forge should still exit 0 for an unregistered project"
  [ "$out" = github ] || fail "missing-project: an unregistered project did not default --forge to github"

  dir=$(make_case missing-registry)
  out=$(run_mode "$dir" --forge any-project 2>/dev/null) \
    || fail "missing-registry: --forge should still exit 0 with no registry file"
  [ "$out" = github ] || fail "missing-registry: an absent registry did not default --forge to github"
  pass "an unregistered project or an absent registry both default --forge to github"
}

test_forge_bitbucket_project_reports_correctly() {
  local dir out
  dir=$(make_case direct-lookup)
  cat > "$dir/data/projects.md" <<'EOF'
- bb-project [direct-PR forge=bitbucket] - a real Bitbucket-backed project (added 2026-01-01)
EOF
  out=$(run_mode "$dir" --forge bb-project) || fail "direct-lookup: --forge failed"
  [ "$out" = bitbucket ] || fail "direct-lookup: did not resolve the registered forge=bitbucket token"
  out=$(run_mode "$dir" --raw bb-project) || fail "direct-lookup: --raw failed"
  [ "$out" = "direct-PR off" ] || fail "direct-lookup: forge token corrupted --raw mode/yolo output"
  pass "a registered forge=bitbucket project resolves through --forge without disturbing --raw"
}

test_default_forge_for_legacy_entries
test_forge_bitbucket_various_token_orders
test_unknown_forge_falls_back_to_github
test_missing_project_and_missing_registry_default_forge
test_forge_bitbucket_project_reports_correctly
