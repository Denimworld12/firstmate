#!/usr/bin/env bash
# Behavior tests for the no-mistakes GATE-agent fleet-lifecycle refusal and its
# structural lab authorization.
#
# A confused no-mistakes gate agent runs inside a firstmate checkout, adopts the
# captain identity from AGENTS.md, and reaches for fm-spawn/fm-send/fm-teardown.
# bin/fm-gate-refuse-lib.sh is the firstmate capability-removal half: sourced at
# the top of those entrypoints and called before any fleet mutation, it fails
# closed on either of two independent signals:
#   1. NO_MISTAKES_GATE set in the environment (the marker no-mistakes stamps);
#   2. the current worktree's git-common-dir resolves under a no-mistakes gate
#      repo (.../.no-mistakes/repos/*.git) - the unspoofable backstop, which
#      still refuses even if the marker was tampered/unset.
# A normal firstmate session (real primary, real crew worktree) has NEITHER
# signal and is completely unaffected.
#
# Exactly one path survives a gate signal: the structural lab authorization.
# FM_HOME must live inside a marked disposable lab dir (bin/fm-lab-home.sh
# create/adopt) and the backend target must be the lab's own isolation
# (an fm-lab-* Herdr session recorded for this lab, private tmux socket dir,
# or a lab-local tool).
# A forged marker on a real or unadopted dir still refuses - the marker
# token binds to the exact canonical dir it was minted for. Worktree and
# spawning-project locations are deliberately NOT pinned inside the lab: a
# real pool worktree is a legitimate spawn result, and requiring a lab-local
# pool would force a fake treehouse. The backend target and any
# FM_STATE_OVERRIDE/FM_DATA_OVERRIDE must belong to the authorized home's own
# lab - another marked lab's socket dir, tool, or state never authorizes.
#
# This suite deliberately does NOT use fm_test_tmproot: that helper adopts its
# root as a lab, and refusal fixtures need unadopted (non-lab) territory. The
# world root below is raw mktemp; only $LAB and $OTHER_LAB are adopted.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

GATE_LIB="$ROOT/bin/fm-gate-refuse-lib.sh"
LAB_HELPER="$ROOT/bin/fm-lab-home.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
SEND="$ROOT/bin/fm-send.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"

WORLD=$(mktemp -d "${TMPDIR:-/tmp}/fm-gate-refuse.XXXXXX")
printf '%s\n' "$WORLD" >> "$FM_TEST_CLEANUP_REGISTRY"
fm_git_identity fmtest fmtest@example.invalid

# The adopted lab dir every authorized-path fixture lives under. Refusal
# fixtures stay in $WORLD outside it.
LAB="$WORLD/lab"
mkdir -p "$LAB"
"$LAB_HELPER" adopt "$LAB" >/dev/null \
  || fail "could not adopt the gate-refuse lab dir"
# A second, separately adopted lab: its artifacts are verified disposable, yet
# must never authorize a call whose FM_HOME lives in $LAB.
OTHER_LAB="$WORLD/other-lab"
mkdir -p "$OTHER_LAB"
"$LAB_HELPER" adopt "$OTHER_LAB" >/dev/null \
  || fail "could not adopt the second gate-refuse lab dir"
trap 'fm_test_lab_remove "$LAB"; fm_test_lab_remove "$OTHER_LAB"; fm_test_cleanup' EXIT

# The env marker's exact stderr fragment (the primary signal).
ENV_MSG='NO_MISTAKES_GATE set'
# The git-common-dir backstop's exact stderr fragment (the unspoofable signal).
PATH_MSG='no-mistakes gate worktree'
# The structural note printed beside every lab-authorization failure.
LAB_MSG='lab authorization failed'

# --- shared fixtures --------------------------------------------------------

# make_gate_worktree <root> -> echoes a worktree whose git-common-dir is
# <root>/.no-mistakes/repos/<id>.git, reproducing no-mistakes' gate topology
# (<NM_HOME>/repos/<id>.git + <NM_HOME>/worktrees/<id>/<run>).
make_gate_worktree() {
  local root=$1 id=016d88035d58 run=01KXC3SD5NZYMERGDS68Z1C8ER seed
  mkdir -p "$root/.no-mistakes/repos"
  git init -q --bare "$root/origin.git"
  seed=$(mktemp -d "$WORLD/gate-seed.XXXXXX")
  git init -q -b main "$seed"
  git -C "$seed" commit -q --allow-empty -m init
  git -C "$seed" push -q "$root/origin.git" HEAD:refs/heads/main
  rm -rf "$seed"
  git clone -q --bare "$root/origin.git" "$root/.no-mistakes/repos/$id.git"
  git -C "$root/.no-mistakes/repos/$id.git" worktree add --detach \
    "$root/.no-mistakes/worktrees/$id/$run" main >/dev/null 2>&1
  printf '%s\n' "$root/.no-mistakes/worktrees/$id/$run"
}

# make_normal_repo <dir> -> echoes a plain (non-gate) git repo to stand in for a
# normal primary/crew checkout: its git-common-dir is <dir>/.git, never a gate.
make_normal_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

GATE_WT=$(make_gate_worktree "$WORLD/gate")
NORMAL_CWD=$(make_normal_repo "$WORLD/normal-cwd")

# --- the shared helper, tested directly -------------------------------------

# run_guard_lib <cwd> [set|empty] : from <cwd>, source the lib and call the
# guard under set -eu in a subshell. NO_MISTAKES_GATE is unset first; a literal
# "set"/"empty" second argument re-exports it. With no FM_HOME the authorize
# sees the cwd itself, which is unadopted territory in every caller.
run_guard_lib() {
  local cwd=$1 marker=${2:-unset}
  (
    cd "$cwd" || exit 111
    unset NO_MISTAKES_GATE
    case "$marker" in
      set) export NO_MISTAKES_GATE=1 ;;
      empty) export NO_MISTAKES_GATE= ;;
    esac
    set -eu
    # shellcheck source=/dev/null
    . "$GATE_LIB"
    fm_refuse_if_gate_agent
  ) 2>&1
}

test_helper_env_marker_refuses() {
  local out rc
  out=$(run_guard_lib "$NORMAL_CWD" set); rc=$?
  expect_code 3 "$rc" "helper: env marker must exit 3"
  assert_contains "$out" "$ENV_MSG" "helper: env-marker refusal message"
  assert_contains "$out" "$LAB_MSG" "helper: env-marker refusal must name the failed lab check"
  pass "fm-gate-refuse-lib: refuses when NO_MISTAKES_GATE is set outside a lab"
}

test_helper_empty_env_marker_refuses() {
  local out rc
  out=$(run_guard_lib "$NORMAL_CWD" empty); rc=$?
  expect_code 3 "$rc" "helper: empty env marker must exit 3"
  assert_contains "$out" "$ENV_MSG" "helper: empty env-marker refusal message"
  pass "fm-gate-refuse-lib: refuses when NO_MISTAKES_GATE is set empty"
}

test_helper_path_backstop_refuses() {
  local out rc
  # Marker UNSET: only the git-common-dir backstop can fire here.
  out=$(run_guard_lib "$GATE_WT"); rc=$?
  expect_code 3 "$rc" "helper: gate worktree must exit 3 even with the marker unset"
  assert_contains "$out" "$PATH_MSG" "helper: path-backstop refusal message"
  assert_not_contains "$out" "$ENV_MSG" "helper: backstop must not be attributed to the env marker"
  pass "fm-gate-refuse-lib: refuses from a gate worktree via git-common-dir (marker unset)"
}

test_helper_normal_is_noop() {
  local out rc
  out=$(run_guard_lib "$NORMAL_CWD"); rc=$?
  expect_code 0 "$rc" "helper: a normal session (neither signal) must not refuse"
  [ -z "$out" ] || fail "helper: normal session printed output: $out"
  pass "fm-gate-refuse-lib: no-op for a normal session (neither signal, set -eu clean)"
}

# --- structural lab authorization -------------------------------------------

# run_lib_call <cwd> <home> [ASSIGN...] : source the lib in a gate env and call
# fm_refuse_if_gate_agent with an explicit FM_HOME, the shape the lifecycle
# entrypoints take after their own home resolution.
run_lib_call() {
  local cwd=$1 home=$2
  shift 2
  (
    cd "$cwd" || exit 111
    set -eu
    # shellcheck source=/dev/null
    . "$GATE_LIB"
    # shellcheck disable=SC2016 # The inner bash, not this shell, expands $1.
    env "$@" FM_HOME="$home" NO_MISTAKES_GATE=1 bash -c \
      '. "$1"; fm_refuse_if_gate_agent' _ "$GATE_LIB"
  ) 2>&1
}

# A fake tmux inside the lab makes the default backend lab-contained.
make_lab_fakebin() { # <dir> -> echoes fakebin
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_lab_home_authorizes() {
  local home fakebin out rc
  home="$LAB/auth-home"; mkdir -p "$home/state" "$home/data" "$home/config"
  fakebin=$(make_lab_fakebin "$LAB/auth-fake")
  out=$(run_lib_call "$NORMAL_CWD" "$home" "PATH=$fakebin:$PATH" "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 0 "$rc" "helper: a marked lab home with a lab-contained backend must authorize"
  [ -z "$out" ] || fail "helper: authorized lab call printed output: $out"
  pass "fm-gate-refuse-lib: a marked lab home authorizes the gate lifecycle call"
}

test_lab_nested_home_authorizes() {
  local home fakebin out rc
  home="$LAB/nested/inner/home"; mkdir -p "$home/state" "$home/data" "$home/config"
  fakebin=$(make_lab_fakebin "$LAB/nested-fake")
  out=$(run_lib_call "$NORMAL_CWD" "$home" "PATH=$fakebin:$PATH" "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 0 "$rc" "helper: a home nested inside the lab dir must authorize"
  pass "fm-gate-refuse-lib: a nested lab path authorizes against the outermost marked dir"
}

test_forged_marker_on_temp_dir_refuses() {
  local home fakebin out rc
  # A .fm-lab-home file copied onto an unadopted temp dir: the token's binding
  # names the real lab dir, not this one, so the proof chain breaks.
  home="$WORLD/forged-home"; mkdir -p "$home/state"
  cp "$LAB/.fm-lab-home" "$home/.fm-lab-home"
  fakebin=$(make_lab_fakebin "$LAB/forged-fake")
  out=$(run_lib_call "$NORMAL_CWD" "$home" "PATH=$fakebin:$PATH"); rc=$?
  expect_code 3 "$rc" "helper: a copied marker on an unadopted temp dir must refuse"
  assert_contains "$out" "$LAB_MSG" "helper: forged-marker refusal must name the failed lab check"
  pass "fm-gate-refuse-lib: a forged marker on a non-lab temp dir refuses"
}

test_marker_outside_temp_root_refuses() {
  local out rc
  # A REAL lab dir (valid marker, valid binding) is still refused once the
  # temp root moves: a real home can never live under the temp root, so a
  # marker outside it is never an authorization.
  out=$(run_lib_call "$NORMAL_CWD" "$LAB" "TMPDIR=$WORLD/fake-tmp" "PATH=$PATH"); rc=$?
  expect_code 3 "$rc" "helper: a marked dir outside the temp root must refuse"
  assert_contains "$out" "$LAB_MSG" "helper: outside-temp-root refusal must name the failed lab check"
  pass "fm-gate-refuse-lib: a real-home-shaped dir outside the temp root refuses even with a valid marker"
}

test_forged_binding_refuses() {
  local home token bindings original fakebin out rc
  # Adopt a dir, then corrupt the binding record to name a different dir: the
  # marker no longer binds back to itself.
  home=$(mktemp -d "$WORLD/forged-binding.XXXXXX")
  "$LAB_HELPER" adopt "$home" >/dev/null || fail "could not adopt forged-binding home"
  token=$(sed -n 's/^token=//p' "$home/.fm-lab-home" | head -1)
  bindings="${FM_LAB_HOME_STATE_DIR:-${TMPDIR:-/tmp}/fm-lab-home-${UID}}/bindings"
  original=$(cat "$bindings/$token")
  printf '%s\n' "$WORLD/somewhere-else" > "$bindings/$token"
  fakebin=$(make_lab_fakebin "$LAB/forgedb-fake")
  out=$(run_lib_call "$NORMAL_CWD" "$home" "PATH=$fakebin:$PATH"); rc=$?
  expect_code 3 "$rc" "helper: a binding that names another dir must refuse"
  assert_contains "$out" "$LAB_MSG" "helper: forged-binding refusal must name the failed lab check"
  printf '%s\n' "$original" > "$bindings/$token"
  fm_test_lab_remove "$home"
  pass "fm-gate-refuse-lib: a forged marker binding refuses"
}

test_lab_ambient_tmux_refuses() {
  local home out rc
  # Lab home but the default tmux path: no private socket dir in a lab, no
  # lab-local tmux - an ambient real tmux server is never authorized.
  home="$LAB/tmux-home"; mkdir -p "$home/state" "$home/data" "$home/config"
  out=$(run_lib_call "$NORMAL_CWD" "$home" -u TMUX_TMPDIR -u TMUX \
      "PATH=/usr/bin:/bin" "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 3 "$rc" "helper: lab home on the ambient tmux server must refuse"
  assert_contains "$out" "is not isolated inside the lab" "helper: ambient-tmux refusal must name the backend check"
  pass "fm-gate-refuse-lib: the default tmux target refuses inside a lab home"
}

test_lab_tmux_private_socket_authorizes() {
  local home out rc
  home="$LAB/sock-home"; mkdir -p "$home/state" "$home/data" "$home/config"
  mkdir -p "$LAB/tmux-sock"
  out=$(run_lib_call "$NORMAL_CWD" "$home" -u TMUX \
      "TMUX_TMPDIR=$LAB/tmux-sock" "PATH=/usr/bin:/bin" "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 0 "$rc" "helper: lab home with a private lab socket dir must authorize"
  pass "fm-gate-refuse-lib: TMUX_TMPDIR inside the lab authorizes the tmux backend"
}

test_lab_cross_lab_backend_refuses() {
  local home fakebin out rc
  # The tmux socket dir and the tmux binary both live in another marked lab:
  # neither is this home's own isolation, so both refuse.
  home="$LAB/cross-home"; mkdir -p "$home/state" "$home/data" "$home/config"
  mkdir -p "$OTHER_LAB/tmux-sock"
  out=$(run_lib_call "$NORMAL_CWD" "$home" -u TMUX \
      "TMUX_TMPDIR=$OTHER_LAB/tmux-sock" "PATH=/usr/bin:/bin" "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 3 "$rc" "helper: a socket dir in another lab must refuse"
  assert_contains "$out" "is not isolated inside the lab" "helper: cross-lab socket refusal must name the backend check"
  fakebin=$(make_lab_fakebin "$OTHER_LAB/cross-fake")
  out=$(run_lib_call "$NORMAL_CWD" "$home" -u TMUX_TMPDIR -u TMUX \
      "PATH=$fakebin:/usr/bin:/bin" "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 3 "$rc" "helper: a tmux binary in another lab must refuse"
  assert_contains "$out" "is not isolated inside the lab" "helper: cross-lab tool refusal must name the backend check"
  pass "fm-gate-refuse-lib: another lab's socket dir or tool never authorizes this lab's home"
}

test_lab_state_overrides_outside_refuse() {
  local home fakebin out rc
  home="$LAB/override-home"; mkdir -p "$home/state" "$home/data" "$home/config"
  fakebin=$(make_lab_fakebin "$LAB/override-fake")
  mkdir -p "$WORLD/real-state" "$WORLD/real-data" "$OTHER_LAB/state"
  out=$(run_lib_call "$NORMAL_CWD" "$home" "PATH=$fakebin:$PATH" "FM_ROOT=$WORLD/auth-root" \
      "FM_STATE_OVERRIDE=$WORLD/real-state"); rc=$?
  expect_code 3 "$rc" "helper: FM_STATE_OVERRIDE outside the lab must refuse"
  assert_contains "$out" "resolves outside the lab" "helper: state-override refusal must name the override check"
  out=$(run_lib_call "$NORMAL_CWD" "$home" "PATH=$fakebin:$PATH" "FM_ROOT=$WORLD/auth-root" \
      "FM_DATA_OVERRIDE=$WORLD/real-data"); rc=$?
  expect_code 3 "$rc" "helper: FM_DATA_OVERRIDE outside the lab must refuse"
  assert_contains "$out" "resolves outside the lab" "helper: data-override refusal must name the override check"
  out=$(run_lib_call "$NORMAL_CWD" "$home" "PATH=$fakebin:$PATH" "FM_ROOT=$WORLD/auth-root" \
      "FM_STATE_OVERRIDE=$OTHER_LAB/state"); rc=$?
  expect_code 3 "$rc" "helper: FM_STATE_OVERRIDE in another lab must refuse"
  out=$(run_lib_call "$NORMAL_CWD" "$home" "PATH=$fakebin:$PATH" "FM_ROOT=$WORLD/auth-root" \
      "FM_STATE_OVERRIDE=$home/state" "FM_DATA_OVERRIDE=$home/data"); rc=$?
  expect_code 0 "$rc" "helper: state and data overrides inside the lab must authorize"
  pass "fm-gate-refuse-lib: FM_STATE_OVERRIDE/FM_DATA_OVERRIDE outside the lab refuse; inside authorize"
}

test_lab_symlinked_backend_escape_refuses() {
  local home linkbin out rc
  # A lab-local symlink is only as contained as its final target: a link in
  # the lab's PATH to an outside tmux, or a lab socket-dir link to an outside
  # (even not-yet-created) dir, must refuse; a link resolving inside the lab
  # still authorizes.
  home="$LAB/link-home"; mkdir -p "$home/state" "$home/data" "$home/config"
  mkdir -p "$WORLD/real-bin" "$LAB/link-fake" "$LAB/link-in-fake"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$WORLD/real-bin/tmux"
  chmod +x "$WORLD/real-bin/tmux"
  linkbin="$LAB/link-fake"
  ln -s "$WORLD/real-bin/tmux" "$linkbin/tmux"
  out=$(run_lib_call "$NORMAL_CWD" "$home" -u TMUX_TMPDIR -u TMUX \
      "PATH=$linkbin:/usr/bin:/bin" "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 3 "$rc" "helper: a lab symlink to an outside tmux must refuse"
  assert_contains "$out" "is not isolated inside the lab" "helper: symlinked-tool refusal must name the backend check"
  ln -s "$WORLD/real-sock-missing" "$LAB/sock-link"
  out=$(run_lib_call "$NORMAL_CWD" "$home" -u TMUX \
      "TMUX_TMPDIR=$LAB/sock-link" "PATH=/usr/bin:/bin" "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 3 "$rc" "helper: a lab socket-dir symlink to an outside dir must refuse"
  make_lab_fakebin "$LAB/link-in-target" >/dev/null
  ln -s "../link-in-target/fakebin/tmux" "$LAB/link-in-fake/tmux"
  out=$(run_lib_call "$NORMAL_CWD" "$home" -u TMUX_TMPDIR -u TMUX \
      "PATH=$LAB/link-in-fake:/usr/bin:/bin" "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 0 "$rc" "helper: a lab symlink resolving inside the lab must authorize"
  pass "fm-gate-refuse-lib: lab-local symlinks authorize only when their target stays inside the lab"
}

test_lab_default_state_data_symlink_refuses() {
  local home fakebin out rc which
  fakebin=$(make_lab_fakebin "$LAB/dirlink-fake")
  for which in state data; do
    home="$LAB/dirlink-$which-home"; mkdir -p "$home/state" "$home/data" "$home/config"
    mkdir -p "$WORLD/real-home-$which"
    rm -rf "${home:?}/$which"
    ln -s "$WORLD/real-home-$which" "$home/$which"
    out=$(run_lib_call "$NORMAL_CWD" "$home" -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
        "PATH=$fakebin:$PATH" "FM_ROOT=$WORLD/auth-root"); rc=$?
    expect_code 3 "$rc" "helper: a lab home whose default $which dir links outside the lab must refuse"
    assert_contains "$out" "the state or data directory resolves outside the lab" \
      "helper: default $which-dir refusal must name the state/data check"
  done
  pass "fm-gate-refuse-lib: a lab home whose default state or data dir links outside the lab refuses"
}

test_lab_herdr_default_session_refuses() {
  local home out rc
  home="$LAB/herdr-home"; mkdir -p "$home/state" "$home/data" "$home/config"
  out=$(run_lib_call "$NORMAL_CWD" "$home" -u TMUX_TMPDIR -u TMUX \
      "FM_BACKEND=herdr" "HERDR_SESSION=default" "PATH=/usr/bin:/bin" \
      "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 3 "$rc" "helper: the default Herdr session must refuse inside a lab"
  assert_contains "$out" "is not isolated inside the lab" "helper: default-session refusal must name the backend check"
  pass "fm-gate-refuse-lib: the default Herdr session refuses inside a lab home"
}

test_lab_herdr_named_session_authorizes() {
  local home session out rc
  home="$LAB/herdr-ok"; mkdir -p "$home/state" "$home/data" "$home/config"
  session="fm-lab-gate-ok-$$-$RANDOM"
  out=$(run_lib_call "$NORMAL_CWD" "$home" -u TMUX_TMPDIR -u TMUX \
      "FM_BACKEND=herdr" "HERDR_SESSION=$session" "PATH=/usr/bin:/bin" \
      "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 3 "$rc" "helper: an fm-lab-* session the lab never recorded must refuse"
  "$LAB_HELPER" record-herdr-session "$LAB" "$session" \
    || fail "could not record the Herdr lab session"
  out=$(run_lib_call "$NORMAL_CWD" "$home" -u TMUX_TMPDIR -u TMUX \
      "FM_BACKEND=herdr" "HERDR_SESSION=$session" "PATH=/usr/bin:/bin" \
      "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 0 "$rc" "helper: an fm-lab-* session recorded for the lab must authorize"
  pass "fm-gate-refuse-lib: only a Herdr lab session recorded for the home's lab authorizes"
}

test_lab_herdr_other_lab_session_refuses() {
  local home session fakebin out rc
  # Lab B provisioned and recorded this session; lab A's home must not reach
  # it through the environment, a task record, or a resolved send target, and
  # lab A cannot claim it by recording it too.
  home="$LAB/herdr-cross"; mkdir -p "$home/state" "$home/data" "$home/config"
  session="fm-lab-gate-other-$$-$RANDOM"
  "$LAB_HELPER" record-herdr-session "$OTHER_LAB" "$session" \
    || fail "could not record lab B's Herdr session"
  if "$LAB_HELPER" record-herdr-session "$LAB" "$session" 2>/dev/null; then
    fail "lab A recorded a Herdr session lab B already owns"
  fi
  out=$(run_lib_call "$NORMAL_CWD" "$home" -u TMUX_TMPDIR -u TMUX \
      "FM_BACKEND=herdr" "HERDR_SESSION=$session" "PATH=/usr/bin:/bin" \
      "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 3 "$rc" "helper: lab B's recorded session must refuse for lab A's home"
  assert_contains "$out" "is not isolated inside the lab" "helper: cross-lab session refusal must name the backend check"

  fakebin=$(make_lab_fakebin "$LAB/herdr-cross-fake")
  fm_write_meta "$home/state/cross.meta" "window=$session:p1" "backend=herdr" \
    "herdr_session=$session" "kind=ship"
  out=$(run_lib_call "$NORMAL_CWD" "$home" "PATH=$fakebin:/usr/bin:/bin" "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 3 "$rc" "helper: a task record on lab B's session must refuse for lab A's home"
  assert_contains "$out" "a task record points outside the lab" "helper: cross-lab record refusal must name the meta check"
  rm -f "$home/state/cross.meta"

  # shellcheck disable=SC2016 # The inner bash, not this shell, expands $1-$3.
  out=$(cd "$NORMAL_CWD" && env PATH="$fakebin:/usr/bin:/bin" FM_HOME="$home" FM_ROOT="$WORLD/auth-root" \
      NO_MISTAKES_GATE=1 bash -c '. "$1"; fm_refuse_if_gate_agent; fm_gate_lab_assert_target herdr "$2:p1"; echo reached' \
      _ "$GATE_LIB" "$session" 2>&1); rc=$?
  expect_code 3 "$rc" "helper: a send target on lab B's session must refuse for lab A's home"
  assert_contains "$out" "is not a Herdr session recorded for this lab" "helper: cross-lab target refusal must name the session check"
  assert_not_contains "$out" "reached" "helper: a refused cross-lab target must stop the call"
  pass "fm-gate-refuse-lib: lab A's home cannot target lab B's recorded Herdr session"
}

test_lab_meta_outside_path_refuses() {
  local home fakebin out rc
  home="$LAB/meta-home"; mkdir -p "$home/state" "$home/data" "$home/config"
  fakebin=$(make_lab_fakebin "$LAB/meta-fake")
  fm_write_meta "$home/state/escape.meta" \
    "window=sess:win" "home=$WORLD/outside-lab" "kind=ship"
  out=$(run_lib_call "$NORMAL_CWD" "$home" "PATH=$fakebin:$PATH" "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 3 "$rc" "helper: a task record pointing outside the lab must refuse"
  assert_contains "$out" "a task record points outside the lab" "helper: outside-path refusal must name the meta check"
  pass "fm-gate-refuse-lib: a lab task record pointing outside the lab refuses"
}

test_lab_descendant_homes_stay_in_lab() {
  local home child fakebin session out rc
  # Recursive secondmate teardown enters every descendant home, so the scan
  # must hold each one to the lab: a clean descendant authorizes; a child
  # record on another lab's Herdr session, a child state dir linked outside
  # the lab, a secondmate home outside the lab, or a cycle refuses.
  fakebin=$(make_lab_fakebin "$LAB/desc-fake")
  session="fm-lab-gate-desc-$$-$RANDOM"
  "$LAB_HELPER" record-herdr-session "$OTHER_LAB" "$session" \
    || fail "could not record lab B's Herdr session"
  home="$LAB/desc-home"; child="$LAB/desc-child"
  mkdir -p "$home/state" "$home/data" "$home/config" "$child/state" "$child/data"
  fm_write_meta "$home/state/mate.meta" "window=sess:fm-mate" "kind=secondmate" "home=$child"
  out=$(run_lib_call "$NORMAL_CWD" "$home" "PATH=$fakebin:/usr/bin:/bin" "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 0 "$rc" "helper: a descendant home inside the lab must authorize"

  fm_write_meta "$child/state/foreign.meta" "window=$session:p1" "backend=herdr" \
    "herdr_session=$session" "kind=ship"
  out=$(run_lib_call "$NORMAL_CWD" "$home" "PATH=$fakebin:/usr/bin:/bin" "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 3 "$rc" "helper: a descendant record on lab B's session must refuse"
  assert_contains "$out" "a task record points outside the lab" "helper: descendant endpoint refusal must name the meta check"
  rm -f "$child/state/foreign.meta"

  mkdir -p "$WORLD/desc-real-state"
  rm -rf "${child:?}/state"
  ln -s "$WORLD/desc-real-state" "$child/state"
  out=$(run_lib_call "$NORMAL_CWD" "$home" "PATH=$fakebin:/usr/bin:/bin" "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 3 "$rc" "helper: a descendant whose state links outside the lab must refuse"
  rm -f "$child/state"; mkdir -p "$child/state"

  mkdir -p "$WORLD/desc-real-home/state"
  fm_write_meta "$home/state/mate.meta" "window=sess:fm-mate" "kind=secondmate" \
    "worktree=$WORLD/desc-real-home"
  out=$(run_lib_call "$NORMAL_CWD" "$home" "PATH=$fakebin:/usr/bin:/bin" "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 3 "$rc" "helper: a secondmate home outside the lab must refuse"

  fm_write_meta "$home/state/mate.meta" "window=sess:fm-mate" "kind=secondmate" "home=$child"
  fm_write_meta "$child/state/back.meta" "window=sess:fm-back" "kind=secondmate" "home=$home"
  out=$(run_lib_call "$NORMAL_CWD" "$home" "PATH=$fakebin:/usr/bin:/bin" "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 3 "$rc" "helper: a descendant home cycle must refuse"
  pass "fm-gate-refuse-lib: every descendant secondmate home is held to the lab boundary"
}

test_lab_registered_in_real_registry_refuses() {
  local home fakeroot fakebin out rc
  home="$LAB/reg-home"; mkdir -p "$home/state" "$home/data" "$home/config"
  fakebin=$(make_lab_fakebin "$LAB/reg-fake")
  fakeroot="$WORLD/reg-root"; mkdir -p "$fakeroot/data"
  printf -- '- mate1 - test (home: %s; scope: test; projects: none; added 2026-01-01)\n' "$home" \
    > "$fakeroot/data/secondmates.md"
  out=$(run_lib_call "$NORMAL_CWD" "$home" "PATH=$fakebin:$PATH" "FM_ROOT=$fakeroot"); rc=$?
  expect_code 3 "$rc" "helper: a lab home registered as a real secondmate must refuse"
  assert_contains "$out" "secondmate registry does not stay inside the lab" \
    "helper: registered-lab refusal must name the registry check"
  pass "fm-gate-refuse-lib: a lab home in the real secondmate registry refuses"
}

test_lab_parent_chain_escape_refuses() {
  local home fakebin out rc
  home="$LAB/child-home"; mkdir -p "$home/state" "$home/data" "$home/config"
  fakebin=$(make_lab_fakebin "$LAB/child-fake")
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$WORLD/real-parent" \
    > "$home/.fm-secondmate-parent"
  mkdir -p "$WORLD/real-parent"
  out=$(run_lib_call "$NORMAL_CWD" "$home" "PATH=$fakebin:$PATH" "FM_ROOT=$WORLD/auth-root"); rc=$?
  expect_code 3 "$rc" "helper: a lab home chained to a real parent must refuse"
  assert_contains "$out" "parent chain leaves the lab" "helper: parent-chain refusal must name the parent check"
  pass "fm-gate-refuse-lib: a lab home whose parent chain reaches a real home refuses"
}

# --- fm-spawn ---------------------------------------------------------------

# run_spawn <cwd> <home> <id> <proj> <pane> <fakebin> [ASSIGN...] -> combined output
# Gate-refuse cases cd into a controlled cwd and drop both refusal signals so
# the suite stays hermetic when it itself runs inside a real gate worktree.
run_spawn() {
  local cwd=$1 home=$2 id=$3 proj=$4 pane=$5 fakebin=$6; shift 6
  fm_test_spawn_brief "$home" "$id" brief
  ( cd "$cwd" && env -u NO_MISTAKES_GATE \
      FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX=fake,1,0 \
      PATH="$fakebin:$PATH" "$@" \
      "$SPAWN" "$id" "$proj" codex --mode no-mistakes --yolo off ) 2>&1
}

test_spawn_refuses_and_admits() {
  local home proj fakebin wt out rc
  home="$WORLD/spawn-home"; mkdir -p "$home/data"
  proj=$(make_normal_repo "$WORLD/spawn-proj")
  fm_git_add_origin "$proj" "$WORLD/spawn-origin.git"
  fakebin=$(make_spawn_fakebin "$WORLD/spawn-fake")
  wt="$WORLD/spawn-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1

  # env-marker refuse: neutral cwd, marker set, home outside any lab.
  out=$(run_spawn "$NORMAL_CWD" "$home" spawn-envmark "$proj" "$wt" "$fakebin" NO_MISTAKES_GATE=1); rc=$?
  expect_code 3 "$rc" "spawn: NO_MISTAKES_GATE must refuse"
  assert_contains "$out" "$ENV_MSG" "spawn: env-marker refusal message"
  assert_absent "$home/state/spawn-envmark.meta" "spawn: refused env-marker launch must not record meta"

  # path-backstop refuse: gate-worktree cwd, marker UNSET.
  out=$(run_spawn "$GATE_WT" "$home" spawn-backstop "$proj" "$wt" "$fakebin"); rc=$?
  expect_code 3 "$rc" "spawn: gate-worktree cwd must refuse with the marker unset"
  assert_contains "$out" "$PATH_MSG" "spawn: path-backstop refusal message"
  assert_absent "$home/state/spawn-backstop.meta" "spawn: refused backstop launch must not record meta"

  # no-regression: neutral cwd, marker UNSET, genuine isolated worktree.
  out=$(run_spawn "$NORMAL_CWD" "$home" spawn-ok "$proj" "$wt" "$fakebin"); rc=$?
  expect_code 0 "$rc" "spawn: a normal session must still spawn"
  assert_contains "$out" "spawned spawn-ok" "spawn: normal launch should report success"
  assert_not_contains "$out" "$ENV_MSG" "spawn: normal launch must not print the gate refusal"
  assert_not_contains "$out" "$PATH_MSG" "spawn: normal launch must not print the backstop refusal"
  assert_present "$home/state/spawn-ok.meta" "spawn: normal launch should record meta"
  pass "fm-spawn: refuses on marker and gate-worktree backstop; a normal crew spawn is unaffected"
}

test_spawn_lab_authorizes() {
  local home proj fakebin wt out rc
  # The full lab world: home, project, worktree, fake tools - all inside $LAB.
  home="$LAB/spawn-home"; mkdir -p "$home/data"
  proj=$(make_normal_repo "$LAB/spawn-proj")
  fm_git_add_origin "$proj" "$LAB/spawn-origin.git"
  fakebin=$(make_spawn_fakebin "$LAB/spawn-fake")
  wt="$LAB/spawn-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1

  out=$(run_spawn "$GATE_WT" "$home" spawn-lab "$proj" "$wt" "$fakebin" NO_MISTAKES_GATE=1); rc=$?
  expect_code 0 "$rc" "spawn: a structurally verified lab spawn must proceed under the gate"
  assert_contains "$out" "spawned spawn-lab" "spawn: authorized lab launch should report success"
  assert_present "$home/state/spawn-lab.meta" "spawn: authorized lab launch should record meta"

  # The same lab spawn redirected at state outside the lab refuses before
  # recording anything there.
  mkdir -p "$WORLD/escape-state"
  out=$(run_spawn "$GATE_WT" "$home" spawn-escape "$proj" "$wt" "$fakebin" NO_MISTAKES_GATE=1 \
      "FM_STATE_OVERRIDE=$WORLD/escape-state"); rc=$?
  expect_code 3 "$rc" "spawn: a lab spawn with FM_STATE_OVERRIDE outside the lab must refuse"
  assert_contains "$out" "resolves outside the lab" "spawn: state-override refusal must name the override check"
  assert_absent "$WORLD/escape-state/spawn-escape.meta" "spawn: refused override launch must not record meta outside the lab"
  pass "fm-spawn: a marked lab home with lab-contained tools authorizes a spawn inside the gate; outside state refuses"
}

test_spawn_lab_allows_real_treehouse() {
  local home proj fakebin wt out rc
  # Backend contained (private socket dir) and a marked lab home, but NO
  # lab-local treehouse, and the project and its worktree outside the lab: the
  # worktree-providing spawn may still reach the real shared pool. The
  # authorized lab proof covers the FM_HOME and the backend target only -
  # pinning the project or pool inside the lab would force a fake treehouse.
  home="$LAB/thome"; mkdir -p "$home/data"
  proj=$(make_normal_repo "$WORLD/tproj")
  fm_git_add_origin "$proj" "$WORLD/tproj-origin.git"
  wt="$WORLD/twt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  mkdir -p "$LAB/tsock"
  fakebin=$(fm_fakebin "$LAB/tfake")
  fm_test_fake_tmux_spawn "$fakebin"
  fm_test_spawn_brief "$home" spawn-treehouse brief
  out=$(cd "$GATE_WT" && env -u TMUX NO_MISTAKES_GATE=1 \
      FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" \
      TMUX_TMPDIR="$LAB/tsock" PATH="$fakebin:$PATH" \
      "$SPAWN" spawn-treehouse "$proj" codex --mode no-mistakes --yolo off 2>&1); rc=$?
  expect_code 0 "$rc" "spawn: a lab spawn resolving the real treehouse pool must proceed"
  assert_contains "$out" "spawned spawn-treehouse" "spawn: real-pool lab spawn should report success"
  pass "fm-spawn: a worktree-providing lab spawn may use the real treehouse pool"
}

# --- fm-send ----------------------------------------------------------------

# A fake tmux that logs send-keys to FM_TMUX_LOG and reports live endpoints
# (mirrors tests/fm-send-strict), so a successful send is observable and a
# refused one leaves an empty log (proving no message was typed).
make_send_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift; literal=0; target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf '%%1\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf 'fm-lane-ok\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/sleep"
  chmod +x "$fakebin/sleep"
  printf '%s\n' "$fakebin"
}

# run_send <cwd> <home> <fakebin> <log> <target> <text> [ASSIGN...] -> combined output
# FM_ROOT_OVERRIDE points at a separate empty root: the structural check reads
# the home-vs-checkout distinction, so the fixture's FM_HOME must not also be
# its code root.
run_send() {
  local cwd=$1 home=$2 fakebin=$3 log=$4 target=$5 text=$6; shift 6
  mkdir -p "$WORLD/send-root"
  ( cd "$cwd" && env -u NO_MISTAKES_GATE \
      "PATH=$fakebin:$PATH" "FM_HOME=$home" "FM_ROOT_OVERRIDE=$WORLD/send-root" \
      "FM_TMUX_LOG=$log" "FM_SEND_SETTLE=0" "$@" \
      "$SEND" "$target" "$text" ) 2>&1
}

test_send_refuses_and_admits() {
  local home fakebin log out rc
  home="$WORLD/send-home"; mkdir -p "$home/state"
  fakebin=$(make_send_fakebin "$WORLD/send-fake")
  log="$WORLD/send-tmux.log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"

  # env-marker refuse.
  : > "$log"
  out=$(run_send "$NORMAL_CWD" "$home" "$fakebin" "$log" fm-lane-ok "hello captain" NO_MISTAKES_GATE=1); rc=$?
  expect_code 3 "$rc" "send: NO_MISTAKES_GATE must refuse"
  assert_contains "$out" "$ENV_MSG" "send: env-marker refusal message"
  [ ! -s "$log" ] || fail "send: refused env-marker send still typed to the endpoint"$'\n'"$(cat "$log")"

  # path-backstop refuse (marker UNSET).
  : > "$log"
  out=$(run_send "$GATE_WT" "$home" "$fakebin" "$log" fm-lane-ok "hello captain"); rc=$?
  expect_code 3 "$rc" "send: gate-worktree cwd must refuse with the marker unset"
  assert_contains "$out" "$PATH_MSG" "send: path-backstop refusal message"
  [ ! -s "$log" ] || fail "send: refused backstop send still typed to the endpoint"$'\n'"$(cat "$log")"

  # no-regression.
  : > "$log"
  out=$(run_send "$NORMAL_CWD" "$home" "$fakebin" "$log" fm-lane-ok "hello captain"); rc=$?
  expect_code 0 "$rc" "send: a normal session must still send"
  assert_not_contains "$out" "$ENV_MSG" "send: normal send must not print the gate refusal"
  assert_not_contains "$out" "$PATH_MSG" "send: normal send must not print the backstop refusal"
  [ "$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" \
      "$home/state/lane-ok.inbox/001.msg")" = "hello captain" ] \
    || fail "send: normal steer was not durably enqueued"
  assert_not_contains "$(cat "$log")" "literal=1 arg=hello captain" \
    "send: normal steer payload must not be typed"
  assert_contains "$(cat "$log")" "target=sess:fm-lane-ok literal=1 arg=: Firstmate instruction waiting" \
    "send: normal steer should ring the durable inbox doorbell"
  pass "fm-send: refuses on marker and gate-worktree backstop; a normal steer uses the inbox"
}

test_send_lab_authorizes() {
  local home fakebin log out rc
  home="$LAB/send-home"; mkdir -p "$home/state"
  fakebin=$(make_send_fakebin "$LAB/send-fake")
  log="$LAB/send-tmux.log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"

  : > "$log"
  out=$(run_send "$GATE_WT" "$home" "$fakebin" "$log" fm-lane-ok "hello captain" NO_MISTAKES_GATE=1); rc=$?
  expect_code 0 "$rc" "send: a structurally verified lab steer must proceed under the gate"
  assert_contains "$(cat "$log")" "target=sess:fm-lane-ok" \
    "send: authorized lab steer should reach the lab endpoint"

  # The same lab home with its default state dir symlinked at an outside
  # home's state: the steer refuses and enqueues nothing there.
  home="$LAB/send-link-home"; mkdir -p "$home" "$WORLD/send-real-state"
  ln -s "$WORLD/send-real-state" "$home/state"
  fm_write_meta "$WORLD/send-real-state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"
  : > "$log"
  out=$(run_send "$GATE_WT" "$home" "$fakebin" "$log" fm-lane-ok "hello captain" NO_MISTAKES_GATE=1); rc=$?
  expect_code 3 "$rc" "send: a lab home whose state links outside the lab must refuse"
  assert_contains "$out" "the state or data directory resolves outside the lab" \
    "send: symlinked-state refusal must name the state/data check"
  [ ! -s "$log" ] || fail "send: refused symlinked-state steer still typed to the endpoint"$'\n'"$(cat "$log")"
  assert_absent "$WORLD/send-real-state/lane-ok.inbox" "send: refused symlinked-state steer must not enqueue outside the lab"
  pass "fm-send: a marked lab home with a lab-contained tmux authorizes a steer inside the gate; outside state refuses"
}

# --- fm-teardown ------------------------------------------------------------

# make_teardown_case <root> <name> -> echoes a case dir holding a LANDED
# no-mistakes ship task (HEAD reachable from origin), so a normal teardown
# genuinely succeeds and a refused one leaves the task untouched.
make_teardown_case() {
  local root=$1 name=$2 case_dir fakebin t
  case_dir="$root/$name"; fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"
  for t in treehouse tmux; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$t"
    chmod +x "$fakebin/$t"
  done
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  git -C "$case_dir/wt" commit -q --allow-empty -m "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "spawn_gen=spawn-gate-refuse-task-x1"
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

# run_teardown <cwd> <case_dir> [ASSIGN...] -> combined output
run_teardown() {
  local cwd=$1 case_dir=$2; shift 2
  ( cd "$cwd" && env -u NO_MISTAKES_GATE \
      "FM_ROOT_OVERRIDE=$ROOT" "FM_STATE_OVERRIDE=$case_dir/state" \
      "FM_DATA_OVERRIDE=$case_dir/data" "FM_CONFIG_OVERRIDE=$case_dir/config" \
      "PATH=$case_dir/fakebin:$PATH" "$@" \
      "$TEARDOWN" task-x1 ) 2>&1
}

test_teardown_refuses_and_admits() {
  local case_dir out rc

  # env-marker refuse: a genuinely-landed task is still refused; nothing is torn down.
  case_dir=$(make_teardown_case "$WORLD" teardown-envmark)
  out=$(run_teardown "$NORMAL_CWD" "$case_dir" NO_MISTAKES_GATE=1); rc=$?
  expect_code 3 "$rc" "teardown: NO_MISTAKES_GATE must refuse"
  assert_contains "$out" "$ENV_MSG" "teardown: env-marker refusal message"
  assert_present "$case_dir/state/task-x1.meta" "teardown: refused env-marker teardown must leave the task"

  # path-backstop refuse (marker UNSET).
  case_dir=$(make_teardown_case "$WORLD" teardown-backstop)
  out=$(run_teardown "$GATE_WT" "$case_dir"); rc=$?
  expect_code 3 "$rc" "teardown: gate-worktree cwd must refuse with the marker unset"
  assert_contains "$out" "$PATH_MSG" "teardown: path-backstop refusal message"
  assert_present "$case_dir/state/task-x1.meta" "teardown: refused backstop teardown must leave the task"

  # no-regression: a normal session tears down the landed task.
  case_dir=$(make_teardown_case "$WORLD" teardown-ok)
  out=$(run_teardown "$NORMAL_CWD" "$case_dir"); rc=$?
  expect_code 0 "$rc" "teardown: a normal session must still tear down landed work"
  assert_not_contains "$out" "$ENV_MSG" "teardown: normal teardown must not print the gate refusal"
  assert_not_contains "$out" "$PATH_MSG" "teardown: normal teardown must not print the backstop refusal"
  assert_not_contains "$out" "REFUSED" "teardown: normal teardown of landed work must not refuse"
  pass "fm-teardown: refuses on marker and gate-worktree backstop; a normal teardown is unaffected"
}

test_teardown_lab_authorizes() {
  local case_dir out rc
  case_dir=$(make_teardown_case "$LAB" teardown-lab)
  # FM_HOME defaults inside run_teardown's env only through FM_*_OVERRIDE -
  # pass the case dir explicitly so the authorize sees the lab home.
  out=$(run_teardown "$GATE_WT" "$case_dir" NO_MISTAKES_GATE=1 "FM_HOME=$case_dir"); rc=$?
  expect_code 0 "$rc" "teardown: a structurally verified lab teardown must proceed under the gate"
  assert_absent "$case_dir/state/task-x1.meta" "teardown: authorized lab teardown should remove the task record"
  pass "fm-teardown: a marked lab home with lab-contained tools authorizes teardown inside the gate"
}

test_helper_env_marker_refuses
test_helper_empty_env_marker_refuses
test_helper_path_backstop_refuses
test_helper_normal_is_noop
test_lab_home_authorizes
test_lab_nested_home_authorizes
test_forged_marker_on_temp_dir_refuses
test_marker_outside_temp_root_refuses
test_forged_binding_refuses
test_lab_ambient_tmux_refuses
test_lab_tmux_private_socket_authorizes
test_lab_cross_lab_backend_refuses
test_lab_state_overrides_outside_refuse
test_lab_symlinked_backend_escape_refuses
test_lab_default_state_data_symlink_refuses
test_lab_herdr_default_session_refuses
test_lab_herdr_named_session_authorizes
test_lab_herdr_other_lab_session_refuses
test_lab_meta_outside_path_refuses
test_lab_descendant_homes_stay_in_lab
test_lab_registered_in_real_registry_refuses
test_lab_parent_chain_escape_refuses
test_spawn_refuses_and_admits
test_spawn_lab_authorizes
test_spawn_lab_allows_real_treehouse
test_send_refuses_and_admits
test_send_lab_authorizes
test_teardown_refuses_and_admits
test_teardown_lab_authorizes
