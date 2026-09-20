#!/usr/bin/env bash
# Live validation for firstmate issue #5004: the durable deliberate-stop marker
# (state/<id>.deliberate-stop) written by bin/fm-control.sh exit, honored by the
# real watcher as a parked task on the bounded pause cadence, cleared by a real
# relaunch, and NOT applied to a worker that was never deliberately stopped.
#
# Driven end to end against the real product (real fm-control.sh, real
# fm-watch.sh, real fm-spawn.sh --relaunch) over a real Herdr pane in an
# isolated throwaway lab session, per docs/herdr-backend.md and the
# bin/fm-herdr-lab.sh prepare/provision/run/teardown contract.
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

SESSION=$("$LAB" name deliberate-stop) || fail "could not generate a lab session name"
export HERDR_SESSION="$SESSION"
SCRATCH=

cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  "$LAB" teardown "$SESSION" >/dev/null 2>&1 || true
}
trap cleanup_all EXIT

note "lab session: $SESSION"
# provision runs the helper's own prepare (tripwire + refusal checks) and starts
# the named server; calling prepare first would double-create the tripwire.
"$LAB" provision "$SESSION" || fail "could not provision isolated Herdr lab session"
pass "isolated Herdr lab session $SESSION provisioned"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-deliberate-stop.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
STATE="$HOME_DIR/state"
mkdir -p "$STATE" "$HOME_DIR/data/ds1"
cat > "$HOME_DIR/data/ds1/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise the durable deliberate-stop marker live.

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
git -C "$PROJ" worktree add --quiet -b ds1 "$WT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-ds1" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"
WINDOW="$SESSION:$PANE_ID"
KEY=${WINDOW//:/_}; KEY=${KEY//\//_}; KEY=${KEY//./_}

write_meta() {  # <task-id> <window>
  {
    echo "window=$2"
    echo "endpoint_task_id=$1"
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
  } > "$STATE/$1.meta"
}
write_meta ds1 "$WINDOW"
pass "real Herdr task pane created: $WINDOW"

# ---------------------------------------------------------------------------
note "SCENARIO 1: a real 'fm-control exit' on the parked task writes the durable marker"
OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
  "$ROOT/bin/fm-control.sh" ds1 exit 2>&1)
RC=$?
printf '%s\n' "$OUT"
[ "$RC" -eq 0 ] || fail "fm-control exit should succeed on an agent-free pane (rc=$RC): $OUT"
case "$OUT" in
  "already-stopped ds1"*) : ;;
  *) fail "expected already-stopped ds1, got: $OUT" ;;
esac
MARKER="$STATE/ds1.deliberate-stop"
[ -f "$MARKER" ] || fail "fm-control exit did not write $MARKER"
MARKER_BODY=$(cat "$MARKER")
case "$MARKER_BODY" in ''|*[!0-9]*) fail "deliberate-stop marker body is not an epoch second: '$MARKER_BODY'" ;; esac
pass "real fm-control exit recorded $MARKER = $MARKER_BODY"

# ---------------------------------------------------------------------------
# Watcher helpers
wait_beats() {  # <state> <pid> <count> [limit]
  local st=$1 pid=$2 want=$3 limit=${4:-300} beat first now i=0 seen=0
  beat="$st/.last-watcher-beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(stat -c '%Y' "$beat" 2>/dev/null || true)
    [ -n "$first" ] && break
    sleep 0.1; i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(stat -c '%Y' "$beat" 2>/dev/null || true)
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      seen=$((seen + 1)); first=$now
      [ "$seen" -ge "$want" ] && return 0
    fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
wait_exit() {  # <pid> <ticks>
  local pid=$1 limit=${2:-100} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
prime_seen() {  # <state> <status-file>
  FM_STATE_OVERRIDE="$1" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}

note "SCENARIO 2+3: the real watcher parks the deliberately stopped task, then re-surfaces a bounded recheck past the cadence"
printf 'done: investigation finished\n' > "$STATE/ds1.status"
prime_seen "$STATE" "$STATE/ds1.status"
OUTF="$SCRATCH/watch-park.out"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" HERDR_SESSION="$SESSION" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_PAUSE_RESURFACE_SECS=240 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch.sh" > "$OUTF" 2>&1 &
WPID=$!
# Three beacon advances guarantee the second poll's stale scan (count reaches 2)
# has completed.
if ! wait_beats "$STATE" "$WPID" 3; then
  kill "$WPID" 2>/dev/null || true; wait "$WPID" 2>/dev/null || true
  fail "watcher exited for a deliberately parked task instead of absorbing: $(cat "$OUTF")"
fi
[ ! -s "$OUTF" ] || { kill "$WPID" 2>/dev/null || true; wait "$WPID" 2>/dev/null || true; fail "parked task produced a wake during absorb: $(cat "$OUTF")"; }
[ ! -e "$STATE/.stale-since-$KEY" ] || { kill "$WPID" 2>/dev/null || true; wait "$WPID" 2>/dev/null || true; fail "parked task started the wedge timer (.stale-since-$KEY)"; }
[ ! -e "$STATE/.wedge-escalations-$KEY" ] || { kill "$WPID" 2>/dev/null || true; wait "$WPID" 2>/dev/null || true; fail "parked task armed the wedge counter"; }
pass "real watcher absorbed the deliberately parked task with no wake and no wedge timer"

# Now age the durable marker past the cadence; the same running watcher must
# re-surface exactly one bounded deliberate-stop recheck, never a wedge.
set_mtime() { touch -d "@$1" "$2"; }
set_mtime "$(( $(date +%s) - 500 ))" "$MARKER"
wait_exit "$WPID" 150 || { kill "$WPID" 2>/dev/null || true; wait "$WPID" 2>/dev/null || true; fail "watcher never re-surfaced the aged parked task: $(cat "$OUTF")"; }
cat "$OUTF"
grep -F "stale: $WINDOW" "$OUTF" >/dev/null || fail "recheck did not surface a stale wake"
grep -F "deliberately stopped" "$OUTF" >/dev/null || fail "recheck was not labeled a deliberate-stop recheck"
grep -F "possible wedge" "$OUTF" >/dev/null && fail "parked task was mislabeled a possible wedge"
[ -e "$STATE/.deliberate-stop-resurfaced-$KEY" ] || fail "the deliberate-stop re-surface throttle was not recorded"
[ ! -e "$STATE/.stale-since-$KEY" ] || fail "the recheck used the wedge timer"
pass "real watcher re-surfaced the parked task on the bounded cadence and never wedge-escalated"

# ---------------------------------------------------------------------------
note "SCENARIO 4 (adversarial): the same idle pane with NO deliberate-stop marker still surfaces as terminal stale"
STATE2="$SCRATCH/home2/state"
mkdir -p "$STATE2" "$SCRATCH/home2/data/ds2"
write_meta2() {
  {
    echo "window=$WINDOW"
    echo "endpoint_task_id=ds2"
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
  } > "$STATE2/ds2.meta"
}
write_meta2
printf 'done: investigation finished\n' > "$STATE2/ds2.status"
prime_seen "$STATE2" "$STATE2/ds2.status"
[ ! -e "$STATE2/ds2.deliberate-stop" ] || fail "adversarial fixture must start without the marker"
OUTF3="$SCRATCH/watch-never-stopped.out"
FM_HOME="$SCRATCH/home2" FM_STATE_OVERRIDE="$STATE2" HERDR_SESSION="$SESSION" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_PAUSE_RESURFACE_SECS=240 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch.sh" > "$OUTF3" 2>&1 &
WPID3=$!
wait_exit "$WPID3" 150 || { kill "$WPID3" 2>/dev/null || true; wait "$WPID3" 2>/dev/null || true; fail "a never-stopped finished task did not surface as stale: $(cat "$OUTF3")"; }
cat "$OUTF3"
grep -Fx "stale: $WINDOW" "$OUTF3" >/dev/null || fail "a never-stopped task did not keep its ordinary terminal-stale surfacing"
grep -F "deliberately stopped" "$OUTF3" >/dev/null && fail "a never-stopped task was misclassified as deliberately parked"
pass "a never-stopped idle task kept its ordinary terminal-stale escalation behavior"

# ---------------------------------------------------------------------------
note "SCENARIO 5: a real 'fm-spawn --relaunch' clears the durable marker"
# Put an inert fake codex on the pane PATH so the replacement harness records a launch.
FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/codex" <<EOF
#!/usr/bin/env bash
: > "$SCRATCH/codex-launched"
EOF
chmod +x "$FAKEBIN/codex"
printf -v FAKEBIN_Q '%q' "$FAKEBIN"
fm_backend_herdr_send_text_line "$WINDOW" "export PATH=$FAKEBIN_Q:\$PATH" \
  || fail "could not put the inert harness on the pane PATH"
# Re-record the marker that a prior exit would have left, so the relaunch has
# something to clear (the real exit already did; be explicit).
printf '%s\n' "$(date +%s)" > "$MARKER"
OUTR=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" ds1 --relaunch --harness codex 2>&1)
RCR=$?
printf '%s\n' "$OUTR"
[ "$RCR" -eq 0 ] || fail "fm-spawn --relaunch failed (rc=$RCR)"
for _ in $(seq 1 30); do [ ! -e "$SCRATCH/codex-launched" ] || break; sleep 0.1; done
[ -e "$SCRATCH/codex-launched" ] || fail "the replacement harness was not launched"
[ ! -e "$MARKER" ] || fail "a successful relaunch left the deliberate-stop marker in place"
pass "real relaunch cleared the deliberate-stop marker"

note "ALL LIVE SCENARIOS PASSED"
