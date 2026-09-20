#!/usr/bin/env bash
# Live validation for firstmate issue #5004 at the away-mode daemon boundary:
# run the REAL bin/fm-supervise-daemon.sh process over a REAL Herdr pane whose
# task carries the durable deliberate-stop marker, and prove the daemon parks it
# on the declared-pause recheck cadence instead of wedge-escalating it.
set -u

WT_ROOT="/home/ivanl/.no-mistakes/worktrees/bfc710bdae80/01M303DW1X88PJJQE9XJBN04EY"
ROOT="$WT_ROOT"
LAB="$ROOT/bin/fm-herdr-lab.sh"

fail() { printf 'NOT OK - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'OK - %s\n' "$1"; }
note() { printf '## %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "SKIP: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION=$("$LAB" name deliberate-stop-daemon) || fail "could not generate a lab session name"
export HERDR_SESSION="$SESSION"
SCRATCH=
DAEMON_PID=
cleanup_all() {
  [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null || true
  [ -n "$DAEMON_PID" ] && wait "$DAEMON_PID" 2>/dev/null || true
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  "$LAB" teardown "$SESSION" >/dev/null 2>&1 || true
}
trap cleanup_all EXIT

note "lab session: $SESSION"
"$LAB" provision "$SESSION" || fail "could not provision isolated Herdr lab session"
pass "isolated Herdr lab session $SESSION provisioned"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-deliberate-stop-daemon.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
STATE="$HOME_DIR/state"
mkdir -p "$STATE" "$HOME_DIR/data/dd1"
cat > "$HOME_DIR/data/dd1/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise the durable deliberate-stop marker under the away-mode daemon.

## Firstmate spec
Keep the isolated endpoint and worktree intact.
EOF

PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b dd1 "$WT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-dd1" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"
WINDOW="$SESSION:$PANE_ID"
KEY=${WINDOW//:/_}; KEY=${KEY//\//_}; KEY=${KEY//./_}

{
  echo "window=$WINDOW"
  echo "endpoint_task_id=dd1"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$STATE/dd1.meta"
pass "real Herdr task pane created: $WINDOW"

# Away posture: the daemon owns triage. Non-terminal status so the daemon's
# heartbeat catch-all has no captain-relevant line to escalate on its own.
: > "$STATE/.afk"
printf 'working: parked after a deliberate stop\n' > "$STATE/dd1.status"
FM_STATE_OVERRIDE="$STATE" bash -c '
  . "$1"
  fm_wake_status_mark_current "$2" "$3"
' _ "$ROOT/bin/fm-wake-lib.sh" "$STATE" "$STATE/dd1.status"
# The stop path's durable marker, already past the recheck cadence.
printf '%s\n' "$(date +%s)" > "$STATE/dd1.deliberate-stop"
touch -d "@$(( $(date +%s) - 500 ))" "$STATE/dd1.deliberate-stop"

note "SCENARIO: the real away-mode daemon parks a deliberately stopped task and re-surfaces it on the pause cadence"
FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
  FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$WINDOW" \
  FM_HOUSEKEEPING_TICK=1 FM_POLL=1 FM_PAUSE_RESURFACE_SECS=240 \
  FM_STALE_ESCALATE_SECS=240 FM_ESCALATE_BATCH_SECS=2 \
  FM_WEDGE_ALARM_EXEC=discard FM_INJECT_FAIL_SLEEP=1 \
  "$ROOT/bin/fm-supervise-daemon.sh" > "$SCRATCH/daemon.out" 2>&1 &
DAEMON_PID=$!

# Wait for the daemon to classify the watcher's deliberate-stop recheck and
# re-surface it through housekeeping.
FOUND=0
for _ in $(seq 1 60); do
  if [ -s "$STATE/.subsuper-escalations" ] \
    && grep -F "deliberately stopped" "$STATE/.subsuper-escalations" >/dev/null 2>&1; then
    FOUND=1; break
  fi
  sleep 1
done
[ "$FOUND" -eq 1 ] || {
  echo "--- daemon log ---"; cat "$SCRATCH/daemon.out"
  [ -e "$STATE/.supervise-daemon.log" ] && { echo "--- daemon log file ---"; tail -40 "$STATE/.supervise-daemon.log"; }
  fail "the away-mode daemon never re-surfaced the deliberately parked task"
}
echo "--- daemon escalation buffer ---"; cat "$STATE/.subsuper-escalations"
grep -F "possible wedge" "$STATE/.subsuper-escalations" >/dev/null 2>&1 \
  && fail "the away-mode daemon wedge-escalated a deliberately parked task"
TASK_KEY=$(printf '%s' dd1 | tr ':/.' '___')
[ -e "$STATE/.subsuper-paused-$TASK_KEY" ] || fail "the daemon did not keep a pause marker for the parked task"
pass "real away-mode daemon parked the deliberately stopped task and re-surfaced it on the pause cadence, never a wedge"

note "ALL LIVE DAEMON SCENARIOS PASSED"
