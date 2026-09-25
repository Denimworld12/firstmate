#!/usr/bin/env bash
# fm-lab-home.sh - create, mark, verify, and tear down disposable firstmate
# "lab" homes that a no-mistakes GATE agent may drive through the fleet
# lifecycle entrypoints (bin/fm-gate-refuse-lib.sh owns the authorization
# decision; this helper owns the on-disk shape it verifies).
#
# Why a marker exists at all: the gate refusal must be able to tell a
# throwaway home from a real fleet home WITHOUT trusting an environment
# variable. The marker plus its binding record is that proof:
#
#   - A lab dir carries `.fm-lab-home` with a random `token=`.
#   - The helper's state dir records `bindings/<token>` -> the lab dir's
#     canonical path, so a marker copied onto another directory verifies
#     nothing (the token resolves to the dir it was minted for or to nothing).
#   - The lab dir itself must canonically resolve under ${TMPDIR:-/tmp}, the
#     disposable temp root. A real home (~/fm-homes/*) can never live there,
#     so the marker can never "upgrade" a real home, and a hand-forged
#     marker+binding under the temp root still only authorizes a temp dir.
#
# Usage:
#   bin/fm-lab-home.sh create <label>     print a fresh marked lab dir
#   bin/fm-lab-home.sh adopt <dir>        mark an existing dir under ${TMPDIR:-/tmp}
#   bin/fm-lab-home.sh verify <fm_home>   print the marked lab dir <fm_home> lives in
#   bin/fm-lab-home.sh teardown <dir>     remove a verified lab dir and its binding
#
# A lab dir is itself a usable disposable FM_HOME (state/, data/, config/,
# projects/ are created). For multi-home scenarios create additional homes
# inside the same lab dir - every FM_HOME, FM_STATE_OVERRIDE, and
# FM_DATA_OVERRIDE a lifecycle call uses must resolve inside the one marked
# lab dir, and the backend target must be the lab's own isolated session
# (Herdr fm-lab-*) or private tmux socket (TMUX_TMPDIR inside this lab). A
# lab-launched primary also needs the gate marker scrubbed from its
# environment (env -u NO_MISTAKES_GATE) - it is a test fixture firstmate, not
# a gate agent.
#
# Per-harness "primary in a lab" recipe: create the lab dir, write the opt-in
# flag the scenario needs (e.g. `touch $LAB/config/supervision-host`), then
# start the harness's own CLI, with the machine's existing login, as the
# session command on the lab's private socket:
#   mkdir -p "$LAB/tmux"
#   env -u NO_MISTAKES_GATE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab \
#     new-session -d -s primary -c "$PWD" -e FM_HOME="$LAB" <cli>
# where <cli> is claude -> `claude`, codex -> `codex`, cursor ->
# `cursor-agent`, opencode -> `opencode`, grok -> `grok`, omp -> `omp`.
# Drive and stop it only through that socket
# (`TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab send-keys|capture-pane|kill-server`);
# the primary's own firstmate calls inherit $TMUX naming the same socket. A
# Herdr primary uses a named fm-lab-* session via bin/fm-herdr-lab.sh
# instead. An absent CLI or an unavailable login is reported untested, never
# faked.

fm_lab_home_error() { echo "fm-lab-home: $*" >&2; }

# The helper-owned state root: created lab dirs and the binding records that
# pin each marker token to its exact canonical lab dir. Override with
# FM_LAB_HOME_STATE_DIR only for tests of this helper itself; the override
# must still resolve under ${TMPDIR:-/tmp} to produce verifiable labs.
fm_lab_home_state_dir() {
  printf '%s' "${FM_LAB_HOME_STATE_DIR:-${TMPDIR:-/tmp}/fm-lab-home-${UID}}"
}

fm_lab_home_tmp_root() {
  CDPATH='' cd -- "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P
}

fm_lab_home_canon() { # <dir> - canonical path, or nothing when unresolvable
  CDPATH='' cd -- "$1" 2>/dev/null && pwd -P
}

fm_lab_home_canon_loose() { # <path> - canon of an existing dir, or
  # parent-canon + basename for a not-yet-existing path (mirrors
  # secondmate_registry_path_key).
  local path=$1 parent base
  case "$path" in /*) ;; *) return 1 ;; esac
  if [ -d "$path" ]; then
    fm_lab_home_canon "$path"
  else
    parent=$(dirname "$path")
    base=$(basename "$path")
    parent=$(fm_lab_home_canon "$parent") || return 1
    printf '%s/%s\n' "$parent" "$base"
  fi
}

fm_lab_home_new_token() {
  od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
}

# fm_lab_home_mark <dir>: write the marker into <dir> and the binding record
# that pins its token to <dir>'s canonical path. Fails unless <dir> resolves
# under the temp root - a lab is disposable temp state by definition.
fm_lab_home_mark() { # <dir>
  local dir=$1 canon_root canon_dir token bindings
  canon_root=$(fm_lab_home_tmp_root) || {
    fm_lab_home_error "temp root ${TMPDIR:-/tmp} is not resolvable"
    return 1
  }
  canon_dir=$(fm_lab_home_canon "$dir") || {
    fm_lab_home_error "cannot resolve lab dir: $dir"
    return 1
  }
  case "$canon_dir" in
    "$canon_root"/*) ;;
    *)
      fm_lab_home_error "refusing to mark $canon_dir: a lab dir must live under the temp root $canon_root"
      return 1
      ;;
  esac
  token=$(fm_lab_home_new_token)
  case "$token" in '' | *[!0-9a-f]*)
    fm_lab_home_error "could not mint a marker token"
    return 1
    ;;
  esac
  bindings="$(fm_lab_home_state_dir)/bindings"
  mkdir -p "$bindings" || return 1
  printf 'token=%s\ncreated=%s\n' "$token" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    > "$canon_dir/.fm-lab-home" || return 1
  printf '%s\n' "$canon_dir" > "$bindings/$token" || return 1
}

# fm_lab_home_walk <canon-path>: the marked ancestor walk behind verify -
# print the OUTERMOST dir under the temp root carrying a marker that
# binds back to itself. A nested marked dir can never narrow authorization
# away from the lab that contains it.
fm_lab_home_walk() { # <canon-path>
  local canon_path=$1 canon_root rel cursor marker token bindings bound comp
  canon_root=$(fm_lab_home_tmp_root) || return 1
  case "$canon_path" in
    "$canon_root"/*) ;;
    *) return 1 ;;
  esac
  rel=${canon_path#"$canon_root"/}
  cursor=$canon_root
  for comp in ${rel//\// }; do
    [ -n "$comp" ] || continue
    cursor="$cursor/$comp"
    marker="$cursor/.fm-lab-home"
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
      token=$(sed -n 's/^token=\([0-9a-f][0-9a-f]*\)$/\1/p' "$marker" | head -1)
      [ -n "$token" ] || return 1
      bindings="$(fm_lab_home_state_dir)/bindings"
      [ -f "$bindings/$token" ] && [ ! -L "$bindings/$token" ] || return 1
      bound=$(head -1 "$bindings/$token")
      [ "$bound" = "$cursor" ] || return 1
      printf '%s\n' "$cursor"
      return 0
    fi
  done
  return 1
}

# fm_lab_home_verify <fm_home>: print the marked lab dir <fm_home> resolves
# inside (or is), after checking the full proof chain: <fm_home> is an
# existing dir under the temp root, and the outermost marked ancestor's token
# binds back to that exact canonical dir in the helper's state. Anything less
# fails closed.
fm_lab_home_verify() { # <fm_home>
  local home=$1 canon_home
  [ -n "$home" ] && [ -d "$home" ] || return 1
  canon_home=$(fm_lab_home_canon "$home") || return 1
  fm_lab_home_walk "$canon_home"
}

fm_lab_home_create() { # <label>
  local label=$1 state_dir lab
  label=$(printf '%s' "$label" | tr -cd 'a-zA-Z0-9_-' | sed 's/^[^a-zA-Z0-9]*//; s/-*$//')
  [ -n "$label" ] || label=lab
  label=${label:0:24}
  state_dir=$(fm_lab_home_state_dir)
  case "$(fm_lab_home_canon "$state_dir" 2>/dev/null || printf '%s' "$state_dir")" in
    "$(fm_lab_home_tmp_root)"/*) ;;
    *)
      fm_lab_home_error "lab state dir $state_dir is not under the temp root"
      return 1
      ;;
  esac
  mkdir -p "$state_dir" || return 1
  lab=$(mktemp -d "$state_dir/${label}-XXXXXX") || return 1
  mkdir -p "$lab/state" "$lab/data" "$lab/config" "$lab/projects" || return 1
  fm_lab_home_mark "$lab" || return 1
  printf '%s\n' "$lab"
}

fm_lab_home_adopt() { # <dir>
  local dir=$1
  [ -d "$dir" ] || {
    fm_lab_home_error "adopt needs an existing directory: $dir"
    return 1
  }
  fm_lab_home_mark "$dir" || return 1
  printf '%s\n' "$(fm_lab_home_canon "$dir")"
}

fm_lab_home_teardown() { # <dir>
  local dir=$1 canon token
  canon=$(fm_lab_home_canon "$dir" 2>/dev/null) || {
    fm_lab_home_error "cannot resolve lab dir: $dir"
    return 1
  }
  fm_lab_home_verify "$canon" >/dev/null || {
    fm_lab_home_error "refusing to teardown $canon: not a marked lab dir"
    return 1
  }
  token=$(sed -n 's/^token=\([0-9a-f][0-9a-f]*\)$/\1/p' "$canon/.fm-lab-home" | head -1)
  rm -rf -- "$canon" || {
    fm_lab_home_error "could not remove lab dir $canon"
    return 1
  }
  [ -z "$token" ] || rm -f -- "$(fm_lab_home_state_dir)/bindings/$token"
}

fm_lab_home_usage() {
  sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fm_lab_home_main() {
  local command=${1:-}
  case "$command" in
    create)
      [ "$#" -eq 2 ] || { fm_lab_home_usage >&2; return 2; }
      fm_lab_home_create "$2"
      ;;
    adopt)
      [ "$#" -eq 2 ] || { fm_lab_home_usage >&2; return 2; }
      fm_lab_home_adopt "$2"
      ;;
    verify)
      [ "$#" -eq 2 ] || { fm_lab_home_usage >&2; return 2; }
      fm_lab_home_verify "$2"
      ;;
    teardown)
      [ "$#" -eq 2 ] || { fm_lab_home_usage >&2; return 2; }
      fm_lab_home_teardown "$2"
      ;;
    -h | --help | help)
      fm_lab_home_usage
      ;;
    *)
      fm_lab_home_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -eu
  fm_lab_home_main "$@"
fi
