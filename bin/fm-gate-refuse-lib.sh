#!/usr/bin/env bash
# fm-gate-refuse-lib.sh - fail-closed refusal that keeps a no-mistakes GATE agent
# out of firstmate's fleet lifecycle, with ONE structurally scoped exception:
# a disposable lab home created by bin/fm-lab-home.sh.
#
# The hazard (data/nm-gate-ambient-authority-containment-c3/report.md): a
# no-mistakes gate agent runs inside a firstmate checkout with a free shell, so
# it auto-loads firstmate's AGENTS.md, adopts the captain identity, and - seeing
# crew "in flight" - reaches for fm-spawn.sh/fm-send.sh/fm-teardown.sh to
# "delegate" and "reconcile" the shared worktree. It has real capability because
# those entrypoints self-locate their home and never knew a gate context existed.
#
# no-mistakes owns the authority-removal half (it neutralizes the project
# instructions and stamps NO_MISTAKES_GATE into the gate agent's environment).
# THIS is the firstmate capability-removal half: an enforceable script refusal,
# not a prose rule the neutralized agent would never read. It is sourced at the
# top of the fleet-lifecycle entrypoints and called before any fleet mutation,
# so a gate agent that still reaches for the fleet is stopped cold.
#
# Two independent gate signals, either of which engages the boundary
# (fail closed):
#
#   1. NO_MISTAKES_GATE set - the durable env marker no-mistakes stamps into every
#      gate agent. This is the primary signal and covers a relocated NM_HOME.
#   2. The current worktree's git-common-dir resolves under a no-mistakes gate
#      repo (.../.no-mistakes/repos/*.git) - the UNSPOOFABLE backstop. It derives
#      from the checkout's real filesystem location, which the agent cannot
#      relocate without breaking the gate's own git operations, so it still
#      refuses even if the agent tampered NO_MISTAKES_GATE away. Its limit: the
#      literal-path match only fires for the default NM_HOME (~/.no-mistakes); a
#      relocated NM_HOME is covered by signal 1.
#
# A NORMAL firstmate session - a real primary checkout, a real treehouse/Orca
# crew worktree - has NEITHER signal and is COMPLETELY unaffected: the function
# returns 0 and the lifecycle proceeds exactly as before.
#
# ==== STRUCTURAL LAB AUTHORIZATION ====
#
# When a gate signal IS present, one and only one path authorizes a lifecycle
# call: every condition below must hold, proven from on-disk structure, and any
# uncertainty refuses. This replaces the retired FM_GATE_REFUSE_BYPASS env
# escape hatch, which authorized on the honor system and could not tell a
# disposable lab from the real fleet.
#
#   fm_gate_lab_authorize requires ALL of:
#
#   1. FM_HOME (or the caller's resolved home) is a disposable lab home:
#      bin/fm-lab-home.sh's fm_lab_home_verify must prove a marked lab dir that
#      carries .fm-lab-home, whose marker token binds back to that exact
#      canonical dir in the helper's state, and which canonically lives under
#      the temp root ${TMPDIR:-/tmp}. A copied or forged marker fails: the
#      binding names the dir the token was minted for.
#   2. The home is NOT the primary checkout (canonical FM_HOME != FM_ROOT).
#      The effective state and data dirs (FM_STATE_OVERRIDE/FM_DATA_OVERRIDE,
#      else $FM_HOME/state and $FM_HOME/data) must resolve inside the lab dir
#      too, symlinks followed - they hold the task records and data the call
#      writes, so a dir outside the lab would reach real fleet state.
#   3. The home's own secondmate registry (data/secondmates.md) binds only
#      lab-contained local homes; a remote record additionally requires the
#      ssh transport to resolve inside the lab (FM_SSH_BIN or `ssh` under the
#      lab dir). A malformed registry refuses.
#   4. The checkout's real registry ($FM_ROOT/data/secondmates.md) binds
#      nothing inside the lab dir - the lab home must not be a registered
#      real secondmate.
#   5. The backend the call could reach is the lab's own isolated target -
#      a socket dir or tool must resolve inside THIS lab dir, never another
#      marked lab:
#      - herdr: HERDR_SESSION names an fm-lab-* session, or `herdr` resolves
#        inside the lab (a fake). The default session is never authorized.
#      - tmux: TMUX_TMPDIR resolves inside the lab (private socket dir), or
#        `tmux` resolves inside the lab. An ambient $TMUX naming a live socket
#        outside the lab refuses, since pane targeting would hit a real
#        server. The default tmux server is never authorized.
#      - zellij/orca/cmux: the tool resolves inside the lab only - there is
#        no lab-safe isolation for the real tools.
#      - remote secondmates: ssh resolves inside the lab.
#      The resolved backend is read exactly as fm_backend_name does:
#      FM_BACKEND, then config/backend, then runtime markers (HERDR_ENV,
#      CMUX_WORKSPACE_ID), else tmux.
#   6. Every task record in the lab's state dir ($FM_HOME/state or
#      FM_STATE_OVERRIDE) stays bound to the lab: a recorded secondmate
#      home= canonicalizes inside the lab dir, backend= plus
#      herdr_session= satisfy the same isolation rules, remote_host=
#      requires ssh in the lab, and a non-regular .meta file refuses.
#      worktree= and project= are deliberately NOT location-checked:
#      a real treehouse or Orca spawn legitimately lands its worktree in
#      the shared pool outside the lab dir, so pinning it inside would
#      force every lab spawn onto a fake pool - the authorized proof is
#      the lab home plus the isolated backend target, nothing more.
#
# Post-resolution assertions (fm_gate_lab_assert_*): authorization at refusal
# time can only see the environment, so entrypoints re-assert once arguments
# resolve the true target - the resolved backend and fm-send's resolved
# endpoint - inside the lab boundary. These are no-ops outside an authorized
# lab call.
#
# Everything else stays refused exactly as before: a real home keeps refusing
# even with a copied marker, a malformed or incomplete lab refuses, and a
# default-session or real-server target refuses.
#
# Sourced by bin/fm-spawn.sh, bin/fm-send.sh, bin/fm-teardown.sh,
# bin/fm-control.sh, bin/fm-sessionstart-nudge.sh, and the tests.
# No side effects on source. set -u / set -e safe. The refusal is a hard exit,
# not a return, because there is no safe way to continue a fleet mutation from a
# gate context.

# The exit code every refusal uses, distinct enough to recognize in a caller or
# test as "the gate refusal fired" rather than an ordinary usage error.
FM_GATE_REFUSE_EXIT=3

# Set by fm_gate_lab_authorize on success: the verified lab dir, and the last
# authorization-failure reason (for the refusal note and tests).
FM_GATE_LAB_DIR=
FM_GATE_LAB_REASON=

# fm_is_gate_agent: return 0 without output when this process looks like a
# no-mistakes gate agent. An optional root anchors the git-common-dir check;
# callers that omit it retain the historical current-worktree behavior.
fm_is_gate_agent() {
  local anchor=${1:-.} common
  if [ "${NO_MISTAKES_GATE+x}" = x ]; then
    FM_GATE_REFUSE_REASON='env'
    return 0
  fi
  common=$(cd "$anchor" 2>/dev/null \
    && cd "$(git rev-parse --git-common-dir 2>/dev/null || echo /nonexistent)" 2>/dev/null \
    && pwd -P || true)
  case "$common" in
    */.no-mistakes/repos/*.git)
      FM_GATE_REFUSE_REASON='path'
      FM_GATE_REFUSE_COMMON=$common
      return 0 ;;
  esac
  return 1
}

# --- lab authorization internals ---------------------------------------------

# Lazy-source the helper libs the authorization needs. Only runs inside a gate
# context, so a normal firstmate session never pays for it.
fm_gate_lab_deps() {
  local dir
  dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
  # shellcheck source=bin/fm-lab-home.sh
  . "$dir/fm-lab-home.sh" || return 1
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$dir/fm-secondmate-registry-lib.sh" || return 1
  # shellcheck source=bin/fm-secondmate-parent-lib.sh
  . "$dir/fm-secondmate-parent-lib.sh" || return 1
}

fm_gate_lab_fail() { # <reason>
  FM_GATE_LAB_REASON=$1
  return 1
}

# Canon-resolve a path (symlinks followed; existing dir, or parent-canon +
# basename) and require it to live inside the authorized lab dir. Used for
# the home's own records and state/data dirs, and for backend containment: a
# private socket dir or fixture tool must belong to this lab, not merely to
# some marked lab, and a lab-local symlink to an outside tool is not lab-local.
fm_gate_lab_path_inside() { # <path>
  local c
  c=$(fm_lab_home_canon_loose "$1" 2>/dev/null) || return 1
  case "$c" in
    "$FM_GATE_LAB_DIR" | "$FM_GATE_LAB_DIR"/*) return 0 ;;
  esac
  return 1
}

# A tool binary that canonically resolves inside the lab dir (a fixture
# fake). With no argument override, PATH resolution decides - a missing tool
# fails closed since it cannot be proven lab-contained.
fm_gate_lab_bin_inside() { # <tool> [explicit-path]
  local tool=$1 bin=${2:-}
  if [ -z "$bin" ]; then
    bin=$(command -v "$tool" 2>/dev/null) || return 1
  fi
  [ -n "$bin" ] || return 1
  fm_gate_lab_path_inside "$bin"
}

# tmux containment: the server the call would reach must be private to the
# lab - TMUX_TMPDIR inside the lab dir (private socket dir) or a lab-local
# `tmux` binary. An ambient $TMUX naming a live socket outside the lab
# refuses: pane targeting would hit a real server.
fm_gate_lab_tmux_ok() {
  local sock
  if [ -n "${TMUX:-}" ]; then
    sock=${TMUX%%,*}
    case "$sock" in
      /*)
        if [ -e "$sock" ]; then
          fm_gate_lab_path_inside "$sock" || return 1
        fi
        ;;
    esac
  fi
  if [ -n "${TMUX_TMPDIR:-}" ] && fm_gate_lab_path_inside "$TMUX_TMPDIR"; then
    return 0
  fi
  fm_gate_lab_bin_inside tmux
}

# herdr containment: a named non-default fm-lab-* session, or a lab-local
# `herdr` binary. The default session is never authorized.
fm_gate_lab_herdr_ok() {
  case "${HERDR_SESSION:-}" in
    fm-lab-*) return 0 ;;
  esac
  fm_gate_lab_bin_inside herdr
}

# Remote-route containment: the ssh transport (FM_SSH_BIN or PATH ssh) must
# resolve inside the lab.
fm_gate_lab_remote_ok() {
  fm_gate_lab_bin_inside ssh "${FM_SSH_BIN:-}"
}

fm_gate_lab_backend_ok() { # <backend>
  case "$1" in
    tmux) fm_gate_lab_tmux_ok ;;
    herdr) fm_gate_lab_herdr_ok ;;
    zellij) fm_gate_lab_bin_inside zellij ;;
    orca) fm_gate_lab_bin_inside orca ;;
    cmux) fm_gate_lab_bin_inside cmux ;;
    remote) fm_gate_lab_remote_ok ;;
    *) return 1 ;;
  esac
}

# The backend a NEW spawn would resolve, mirroring fm_backend_name precedence:
# an explicit --backend hint (pre-scanned by the caller, since argument parsing
# runs after the refusal check), then FM_BACKEND, config/backend, runtime
# markers, else tmux.
fm_gate_lab_resolved_backend() { # <home> [hint]
  local cfg line v
  case "${2:-}" in
    tmux | herdr | zellij | orca | cmux) printf '%s' "$2"; return 0 ;;
  esac
  if [ -n "${FM_BACKEND:-}" ]; then
    printf '%s' "$FM_BACKEND"
    return 0
  fi
  cfg="${FM_CONFIG_OVERRIDE:-$1/config}/backend"
  if [ -f "$cfg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      v=$(printf '%s' "$line" | tr -d '[:space:]')
      if [ -n "$v" ]; then
        printf '%s' "$v"
        return 0
      fi
    done < "$cfg"
  fi
  if [ "${HERDR_ENV:-}" = 1 ]; then
    printf 'herdr'
    return 0
  fi
  if [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    printf 'cmux'
    return 0
  fi
  printf 'tmux'
}

# Scan one secondmates.md registry file. When the registry lives inside the
# lab, every local binding must stay inside the lab and every remote record
# needs the ssh transport inside the lab (a registry the call may consult can
# never hand the agent a route to a real home or host). When the registry
# lives OUTSIDE the lab - the checkout's real registry - it must bind nothing
# inside the lab dir: the lab home must not be a registered real secondmate.
fm_gate_lab_registry_scan() { # <reg-file> <inside-lab:0|1>
  local reg=$1 inside=$2 line c
  [ -f "$reg" ] && [ ! -L "$reg" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*)
        secondmate_registry_parse_line "$line" || return 1
        if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
          [ "$inside" -eq 1 ] || continue
          fm_gate_lab_remote_ok || return 1
        else
          c=$(fm_lab_home_canon_loose "$SECONDMATE_REGISTRY_HOME" 2>/dev/null) || c=
          if [ "$inside" -eq 1 ]; then
            [ -n "$c" ] || return 1
            case "$c" in "$FM_GATE_LAB_DIR" | "$FM_GATE_LAB_DIR"/*) ;; *) return 1 ;; esac
          else
            case "$c" in "$FM_GATE_LAB_DIR" | "$FM_GATE_LAB_DIR"/*) return 1 ;; esac
          fi
        fi
        ;;
    esac
  done < "$reg"
  return 0
}

fm_gate_lab_registry_ok() { # <home>
  local home=$1 reg c
  reg="${FM_DATA_OVERRIDE:-$home/data}/secondmates.md"
  if [ -e "$reg" ] || [ -L "$reg" ]; then
    fm_gate_lab_registry_scan "$reg" 1 || return 1
  fi
  reg="${FM_ROOT:-}/data/secondmates.md"
  if [ -e "$reg" ] || [ -L "$reg" ]; then
    c=$(fm_lab_home_canon_loose "$reg" 2>/dev/null) || c=
    case "$c" in
      "$FM_GATE_LAB_DIR"/*) fm_gate_lab_registry_scan "$reg" 1 ;;
      *) fm_gate_lab_registry_scan "$reg" 0 ;;
    esac || return 1
  fi
  return 0
}

# The secondmate parent chain (.fm-secondmate-parent markers) must stay inside
# the lab: bookkeeping like the treehouse project lock anchors in the chain's
# ROOT home, so a lab home chained to a real home would mutate real state. A
# remote parent additionally needs the ssh transport inside the lab. A
# malformed marker, unreachable parent, cycle, or runaway chain refuses -
# mirroring fm_firstmate_root_home's fail-closed contract.
fm_gate_lab_parent_chain_ok() { # <home>
  local home cur marker parent seen depth=0
  cur=$(fm_lab_home_canon "$1" 2>/dev/null) || return 1
  seen="|$cur|"
  while [ -e "$cur/.fm-secondmate-parent" ] || [ -L "$cur/.fm-secondmate-parent" ]; do
    marker="$cur/.fm-secondmate-parent"
    fm_secondmate_parent_record_parse "$marker" || return 1
    case "$FM_SECONDMATE_PARENT_ROUTE" in
      remote)
        fm_gate_lab_remote_ok || return 1
        return 0
        ;;
      local) ;;
      *) return 1 ;;
    esac
    parent=$(fm_lab_home_canon "$FM_SECONDMATE_PARENT_HOME" 2>/dev/null) || return 1
    case "$parent" in
      "$FM_GATE_LAB_DIR" | "$FM_GATE_LAB_DIR"/*) ;;
      *) return 1 ;;
    esac
    case "$seen" in *"|$parent|"*) return 1 ;; esac
    seen="$seen$parent|"
    cur=$parent
    depth=$((depth + 1))
    [ "$depth" -le 64 ] || return 1
  done
  return 0
}

# Every task record in the lab's state dir must stay bound to the lab: a
# recorded secondmate home= canonically contained (worktree= and project=
# are deliberately unchecked - the shared real pool legitimately holds
# them), recorded backend isolated by the same rules, remote routes through
# lab ssh. Non-regular or unreadable records refuse.
fm_gate_lab_metas_ok() { # <home>
  local state_dir meta backend session host c
  state_dir="${FM_STATE_OVERRIDE:-$1/state}"
  [ -d "$state_dir" ] || return 0
  for meta in "$state_dir"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
    host=$(sed -n 's/^remote_host=//p' "$meta" | tail -1)
    if [ -n "$host" ]; then
      fm_gate_lab_remote_ok || return 1
    fi
    backend=$(sed -n 's/^backend=//p' "$meta" | tail -1)
    backend=${backend:-tmux}
    case "$backend" in
      tmux | herdr | zellij | orca | cmux) ;;
      *) return 1 ;;
    esac
    if [ "$backend" = herdr ]; then
      session=$(sed -n 's/^herdr_session=//p' "$meta" | tail -1)
      case "$session" in
        fm-lab-*) ;;
        *) fm_gate_lab_bin_inside herdr || return 1 ;;
      esac
    else
      fm_gate_lab_backend_ok "$backend" || return 1
    fi
    c=$(sed -n 's/^home=//p' "$meta" | tail -1)
    case "$c" in '' | '-') ;;
      *) fm_gate_lab_path_inside "$c" || return 1 ;;
    esac
  done
  return 0
}

# fm_gate_lab_authorize: the single structural path a gate-context lifecycle
# call may take. Returns 0 and sets FM_GATE_LAB_DIR when every condition in
# the header holds; otherwise returns 1 with FM_GATE_LAB_REASON set.
fm_gate_lab_authorize() { # <home> [--backend hint] [skip-env-backend]
  local home=$1 lab canon_home canon_root resolved
  FM_GATE_LAB_DIR=
  FM_GATE_LAB_REASON=
  fm_gate_lab_deps || {
    fm_gate_lab_fail "lab helper unavailable"
    return 1
  }
  lab=$(fm_lab_home_verify "$home" 2>/dev/null) || {
    fm_gate_lab_fail "FM_HOME is not a marked disposable lab home under the temp root"
    return 1
  }
  FM_GATE_LAB_DIR=$lab
  canon_home=$(fm_lab_home_canon "$home" 2>/dev/null) || {
    fm_gate_lab_fail "cannot resolve FM_HOME"
    return 1
  }
  # The lab home must not be the checkout itself. FM_ROOT is the checkout the
  # invoked scripts came from, so home == root means the agent pointed FM_HOME
  # at a code checkout rather than a disposable home. The equality only counts
  # when FM_ROOT is a real git worktree root: fixture harnesses routinely
  # alias home and root inside a lab, and a fixture root is not a checkout.
  canon_root=$(fm_lab_home_canon "${FM_ROOT:-.}" 2>/dev/null) || canon_root=
  if [ -n "$canon_root" ] && { [ "$canon_home" = "$canon_root" ] || [ "$lab" = "$canon_root" ]; } \
      && [ "$(fm_lab_home_canon "$(git -C "$canon_root" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)" = "$canon_root" ]; then
    fm_gate_lab_fail "lab home must not be the primary checkout"
    return 1
  fi
  if ! fm_gate_lab_path_inside "${FM_STATE_OVERRIDE:-$home/state}" \
      || ! fm_gate_lab_path_inside "${FM_DATA_OVERRIDE:-$home/data}"; then
    fm_gate_lab_fail "the state or data directory resolves outside the lab"
    return 1
  fi
  fm_gate_lab_registry_ok "$home" || {
    fm_gate_lab_fail "secondmate registry does not stay inside the lab"
    return 1
  }
  fm_gate_lab_parent_chain_ok "$home" || {
    fm_gate_lab_fail "the home's secondmate parent chain leaves the lab"
    return 1
  }
  # The env-resolved backend only predicts what a NEW spawn will use. Resolver
  # entrypoints (send, teardown, control) take their backend from recorded
  # metadata, which the meta scan below and the post-resolution asserts already
  # constrain to the lab; checking env resolution there only false-refuses.
  if [ "${3:-}" != 1 ]; then
    resolved=$(fm_gate_lab_resolved_backend "$home" "${2:-}")
    fm_gate_lab_backend_ok "$resolved" || {
      fm_gate_lab_fail "backend '$resolved' is not isolated inside the lab"
      return 1
    }
  fi
  fm_gate_lab_metas_ok "$home" || {
    fm_gate_lab_fail "a task record points outside the lab"
    return 1
  }
  return 0
}

# fm_refuse_if_gate_agent: exit FM_GATE_REFUSE_EXIT with a clear stderr message if
# this process looks like a no-mistakes gate agent, unless the call targets a
# structurally verified disposable lab home (see the header).
fm_refuse_if_gate_agent() { # [anchor] [--backend hint] [skip-env-backend]
  fm_is_gate_agent "${1:-.}" || return 0
  if fm_gate_lab_authorize "${FM_HOME:-${FM_ROOT:-.}}" "${2:-}" "${3:-}"; then
    return 0
  fi
  if [ "$FM_GATE_REFUSE_REASON" = env ]; then
    echo "error: no-mistakes gate agent must not drive the fleet (NO_MISTAKES_GATE set)" >&2
  else
    echo "error: refusing fleet lifecycle from inside a no-mistakes gate worktree ($FM_GATE_REFUSE_COMMON)" >&2
  fi
  if [ -n "$FM_GATE_LAB_REASON" ]; then
    echo "note: lab authorization failed - $FM_GATE_LAB_REASON" >&2
  fi
  exit "$FM_GATE_REFUSE_EXIT"
}

# --- post-resolution assertions ----------------------------------------------
#
# Authorization at refusal time only sees the environment, so entrypoints
# re-assert the true target once arguments resolve. Each is a no-op unless a
# lab authorization is active in this process (FM_GATE_LAB_DIR set), so they
# cost nothing in a normal firstmate session.

fm_gate_lab_assert_active() {
  [ -n "$FM_GATE_LAB_DIR" ]
}

fm_gate_lab_refuse() { # <detail>
  echo "error: no-mistakes gate lab authorization refused - $1" >&2
  exit "$FM_GATE_REFUSE_EXIT"
}

# The backend resolved after argument parsing must satisfy the same isolation
# the environment-level check required.
fm_gate_lab_assert_backend() { # <backend>
  fm_gate_lab_assert_active || return 0
  fm_gate_lab_backend_ok "$1" \
    || fm_gate_lab_refuse "backend '$1' is not isolated inside the lab"
}

# fm-send's resolved endpoint must be the lab's own backend target.
fm_gate_lab_assert_target() { # <backend> <resolved-target>
  fm_gate_lab_assert_active || return 0
  case "$1" in
    remote)
      fm_gate_lab_remote_ok \
        || fm_gate_lab_refuse "remote target '$2' needs a lab-local ssh transport"
      ;;
    herdr)
      case "$2" in
        fm-lab-*:*) ;;
        *)
          fm_gate_lab_bin_inside herdr \
            || fm_gate_lab_refuse "herdr target '$2' is not an fm-lab-* session"
          ;;
      esac
      ;;
    tmux | zellij | orca | cmux)
      fm_gate_lab_backend_ok "$1" \
        || fm_gate_lab_refuse "backend '$1' target '$2' is not isolated inside the lab"
      ;;
    *)
      fm_gate_lab_refuse "unknown backend '$1' for target '$2'"
      ;;
  esac
}
