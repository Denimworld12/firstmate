#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/git-config-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-config-helpers.sh"

# Herdr backend tests drive the real fm-spawn/fm-teardown but do not source
# tests/lib.sh. Under the gate-lifecycle refusal (bin/fm-gate-refuse-lib.sh)
# their fixture homes need the same disposable-lab marking fm_test_tmproot
# applies, so each suite marks its scratch root with fm_test_lab_adopt (or
# bin/fm-lab-home.sh adopt) right after creating it; the fm-lab-* session
# names already satisfy the backend-isolation side of the lab contract.

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

fm_test_lab_adopt() { # <dir>
  "$HERDR_TEST_SAFETY_DIR/bin/fm-lab-home.sh" adopt "$1" >/dev/null
}

# fm_test_fake_treehouse <fakebin> <worktree-parent>: an interactive treehouse
# fake for REAL-pane e2e suites. bin/fm-spawn.sh sends `treehouse get` as text
# into the spawned pane, then discovers the worktree by watching the pane's
# cwd and requiring it to be a real linked git worktree of the pane's project
# (spawn_worktree_isolated). The fake therefore `git worktree add`s a detached
# worktree of the pane's current project under <worktree-parent> and execs a
# shell inside it, which is what makes the pane's cwd a lab-contained path.
# `return` and every other verb exit 0. Put the fakebin first on PATH for the
# spawn call; under the gate lab authorization the resolved treehouse then
# lives in a marked dir while a real pool allocation stays refused.
fm_test_fake_treehouse() { # <fakebin> <worktree-parent>
  local fakebin=$1 parent=$2
  mkdir -p "$fakebin" "$parent" || return 1
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  get)
    dir=\$(mktemp -d "$parent/wt.XXXXXX") || exit 1
    git -C "\$PWD" worktree add --detach "\$dir" >/dev/null 2>&1 || exit 1
    cd -- "\$dir" || exit 1
    exec "\${SHELL:-/bin/bash}"
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/treehouse"
}

# herdr_forget_inherited_pane: drop the Herdr PANE identity this test process
# inherited from whatever terminal it was started in.
#
# Herdr injects HERDR_ENV, HERDR_PANE_ID, HERDR_TAB_ID, HERDR_WORKSPACE_ID,
# HERDR_SOCKET_PATH, and HERDR_SESSION into every process it manages a pane for
# (verified 0.7.5 - docs/verification/runtime-backends.md), and a test run from
# inside a Herdr pane inherits all of them. Spawn now treats that pane as the
# authoritative parent to place workers next to, so a leaked identity from the
# developer's own session would follow the test into its isolated lab session
# and be refused there as a cross-session parent - a result that depends on
# where the suite was launched from, not on what it asserts.
#
# Call this before exporting the lab HERDR_SESSION in any suite whose subject is
# the per-home container path. A suite that means to exercise a launcher-bound
# spawn sets HERDR_PANE_ID itself, to a pane it created in its own lab session.
herdr_forget_inherited_pane() {
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
}

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}
