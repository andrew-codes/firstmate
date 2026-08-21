#!/usr/bin/env bash
# Parses a project's optional firstmate.yml: additional gitignored files to copy
# into a freshly created task worktree (e.g. local .env files needed to run the
# app or its e2e tests) and one command to run right after the worktree is set
# up (e.g. yarn install). docs/configuration.md "Per-project worktree setup
# (firstmate.yml)" is the schema's one owner; this file is the one parser.
#
# Deliberately NOT a general YAML parser. Recognizes only this narrow shape and
# fails closed on anything else - malformed or unrecognized content is reported
# as an error rather than partially applied or guessed at:
#
#   copy_files:
#     - .env
#     - .env.local
#   post_create: scripts/dev-setup.sh
#
# Both keys are optional; an absent file, or a file with neither key, is not an
# error. Blank lines and full-line `#` comments are ignored. `copy_files` entries
# must be plain relative filenames (no `/`, no `..`) - see
# fm_worktree_config_valid_copy_entry - so a compromised entry can never reach
# outside the project's checkout root.
#
# Every parse function reports malformed content by printing one "warning: ..."
# line to STDERR and returning 1, never through a side-channel global: a caller
# that captures a function's stdout via `$(...)` or reads it via `<(...)`
# forces a subshell, and any plain variable that function set would be
# discarded with that subshell on return - silently losing the error. Check the
# function's own exit status instead.
#
# Trust boundary: bin/fm-spawn.sh sources this only against a worktree just
# fetched and hard-reset to the project's own default branch (before any
# crewmate or agent-controlled commit exists in it), mirroring no-mistakes' own
# pinned-SHA trusted-repo-config boundary (see that project's AGENTS.md "Repo
# Config Trust Boundary"). A task's own later branch commits can never cause
# this file to be re-read for that task, because it is read exactly once, at
# worktree creation.
# This file is sourced by scripts and has no side effects on source.

# True if $1 is safe as a copy_files entry: a plain relative filename with no
# path traversal and no directory components, so the copy can only ever read
# <project-root>/<name> and write <worktree-root>/<name>.
fm_worktree_config_valid_copy_entry() {  # <name>
  local name=$1
  [ -n "$name" ] || return 1
  case "$name" in
    /*) return 1 ;;
    *..*) return 1 ;;
    */*) return 1 ;;
  esac
  return 0
}

# Parse $1 (a firstmate.yml path); print each valid copy_files entry, one per
# line. Prints nothing and returns 0 when the file is absent or has no
# copy_files key. On malformed content, prints a "warning: ..." line to
# stderr and returns 1 - any entries already printed to stdout before the
# malformed one are still valid and may be used by the caller.
fm_worktree_config_copy_files() {  # <firstmate.yml path>
  local path=$1 line in_list=0 name
  [ -f "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      'copy_files:')
        in_list=1
        continue
        ;;
      '  - '*)
        if [ "$in_list" -eq 1 ]; then
          name=${line#  - }
          name=$(fm_worktree_config_trim_quotes "$name")
          if ! fm_worktree_config_valid_copy_entry "$name"; then
            echo "warning: firstmate.yml copy_files entry '$name' is not a plain relative filename; skipping remaining copy_files" >&2
            return 1
          fi
          printf '%s\n' "$name"
          continue
        fi
        ;;
    esac
    in_list=0
  done < "$path"
  return 0
}

# Parse $1 (a firstmate.yml path); print the configured post_create command, or
# nothing when absent. On a malformed post_create line (no value, or a
# duplicate key), prints a "warning: ..." line to stderr and returns 1.
fm_worktree_config_post_create() {  # <firstmate.yml path>
  local path=$1 line value found=0
  [ -f "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      'post_create:'*)
        if [ "$found" -eq 1 ]; then
          echo "warning: firstmate.yml post_create is set more than once; skipping" >&2
          return 1
        fi
        value=${line#post_create:}
        value=$(fm_worktree_config_trim_quotes "$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')")
        if [ -z "$value" ]; then
          echo "warning: firstmate.yml post_create has no command; skipping" >&2
          return 1
        fi
        found=1
        printf '%s\n' "$value"
        ;;
    esac
  done < "$path"
  return 0
}

# Strip one layer of matching surrounding quotes (' or "), if present.
fm_worktree_config_trim_quotes() {  # <value>
  local value=$1
  case "$value" in
    \"*\") printf '%s' "${value#\"}" | sed 's/"$//' ;;
    \'*\') printf '%s' "${value#\'}" | sed "s/'\$//" ;;
    *) printf '%s' "$value" ;;
  esac
}
