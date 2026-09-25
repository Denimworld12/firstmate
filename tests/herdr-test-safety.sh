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

# Remove an adopted lab through the helper so its binding record goes with it;
# a dir that never became a lab is simply removed.
fm_test_lab_remove() { # <dir>
  "$HERDR_TEST_SAFETY_DIR/bin/fm-lab-home.sh" teardown "$1" >/dev/null 2>&1 || rm -rf "$1"
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
