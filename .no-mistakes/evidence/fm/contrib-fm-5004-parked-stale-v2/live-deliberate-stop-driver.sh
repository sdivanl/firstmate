#!/usr/bin/env bash
# Live driver for the deliberate-stop parking change (firstmate issue #5004).
#
# Drives the REAL product binaries (bin/fm-control.sh, bin/fm-watch.sh,
# bin/fm-teardown.sh, bin/fm-busy-event.sh) against a disposable marked lab home
# with a REAL tmux server, isolated on a private socket through a tmux shim so
# the host's sessions are never touched. Every scenario prints a labeled section
# to stdout; the caller tees it to the evidence log.
#
#   bash live-deliberate-stop-driver.sh /path/to/repo-root
set -u

ROOT=${1:-$(pwd)}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
SOCK="$LAB/tmux/fm.sock"
export NO_MISTAKES_GATE=

cleanup() {
  [ -x "$LAB/shim/tmux" ] && "$LAB/shim/tmux" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

section() { printf '\n===== %s =====\n' "$*"; }

"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$LAB/tmux" "$LAB/shim"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec /usr/bin/tmux -S "$SOCK" "\$@"
SH
chmod +x "$LAB/shim/tmux"
export PATH="$LAB/shim:$PATH"

# Environment for every real product invocation: the marked lab home, no
# fleet-path overrides, and the shim on PATH.
run_lab() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
    -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$LAB/shim:$PATH" FM_HOME="$LAB" "$@"
}

make_meta() {  # <id> <window> <harness> [kind]
  local id=$1 win=$2 harness=$3 kind=${4:-ship}
  mkdir -p "$LAB/data/$id" "$LAB/wt-$id" "$LAB/proj-$id" "$LAB/tmp"
  printf '# brief for %s\n' "$id" > "$LAB/data/$id/brief.md"
  {
    echo "window=$win"
    echo "endpoint_task_id=$id"
    echo "worktree=$LAB/wt-$id"
    echo "project=$LAB/proj-$id"
    echo "harness=$harness"
    echo "kind=$kind"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "spawn_gen=${id}gen1"
  } > "$LAB/state/$id.meta"
}

prime_seen() {  # <id>
  run_lab env FM_STATE_OVERRIDE="$LAB/state" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_wake_status_mark_current "$2" "$2/$3.status"' \
    _ "$ROOT" "$LAB/state" "$1"
}

reset_watch() {
  rm -f "$LAB/state/.watcher-down" "$LAB/state/.wake-queue" \
    "$LAB/state/.wake-queue.seq" "$LAB/state/.watch-deliveries.log" \
    "$LAB/state/.hb-surfaced-"* "$LAB/state/.heartbeat-streak" 2>/dev/null || true
}

watch_run() {  # <seconds> [extra env...]
  local secs=$1; shift
  reset_watch
  run_lab env "$@" timeout "$secs" "$ROOT/bin/fm-watch.sh"
}

echo "lab=$LAB"
echo "tmux socket=$SOCK"

# ---------------------------------------------------------------- Scenario 1
section "SCENARIO 1: a deliberate stop writes the durable marker"
tmux new-session -d -s fmlab -n fm-parked -x 200 -y 30
sleep 0.5
make_meta parked fmlab:fm-parked claude
printf 'the agent was deliberately stopped; its task record stays open\n'
echo "--- fm-control.sh parked exit ---"
run_lab "$ROOT/bin/fm-control.sh" parked exit
echo "rc=$?"
echo "--- marker ---"
ls -l "$LAB/state/parked.deliberate-stop"
echo "marker content (stop epoch): $(cat "$LAB/state/parked.deliberate-stop")"

# ---------------------------------------------------------------- Scenario 2
section "SCENARIO 2: a refused stop records no marker"
make_meta refused fmlab:fm-refused claude
echo "--- fm-control.sh refused exit (recorded window does not exist) ---"
run_lab "$ROOT/bin/fm-control.sh" refused exit
echo "rc=$?"
if [ -e "$LAB/state/refused.deliberate-stop" ]; then
  echo "UNEXPECTED: marker present"
else
  echo "confirmed: no deliberate-stop marker for a refused stop"
fi

# ---------------------------------------------------------------- Scenario 3
section "SCENARIO 3: the watcher parks the stopped finished task (absorb, no wedge)"
printf 'done: investigation finished\n' > "$LAB/state/parked.status"
prime_seen parked
echo "--- watcher poll for 7s (FM_PAUSE_RESURFACE_SECS=999) ---"
watch_run 7 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=999999 FM_PAUSE_RESURFACE_SECS=999 FM_SECONDMATE_LIVENESS_SECS=999999
echo "watcher rc=$? (124 = kept blocking = absorbed, no wake)"
echo "--- triage log (deliberate stop absorbed) ---"
grep 'deliberate stop' "$LAB/state/.watch-triage.log" || echo "(none)"
echo "--- wedge markers for this window (must be absent) ---"
ls "$LAB/state"/.stale-since-fmlab_fm-parked "$LAB/state"/.wedge-escalations-fmlab_fm-parked 2>&1 || true

# ---------------------------------------------------------------- Scenario 4
section "SCENARIO 4: past the cadence it re-surfaces as a recheck, never a wedge"
reset_watch
touch -d "@$(( $(date +%s) - 500 ))" "$LAB/state/parked.deliberate-stop"
echo "--- watcher with FM_PAUSE_RESURFACE_SECS=240, marker aged 500s ---"
watch_run 20 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=999999 FM_PAUSE_RESURFACE_SECS=240 FM_SECONDMATE_LIVENESS_SECS=999999
echo "watcher rc=$?"
echo "--- queued wake reason ---"
cat "$LAB/state/.wake-queue" 2>/dev/null

# ---------------------------------------------------------------- Scenario 5
section "SCENARIO 5: clearing the marker returns the finished task to terminal stale"
reset_watch
rm -f "$LAB/state/parked.deliberate-stop" "$LAB/state/.deliberate-stop-resurfaced-fmlab_fm-parked"
echo "--- watcher with no marker ---"
watch_run 15 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=999999
echo "watcher rc=$?"

# ---------------------------------------------------------------- Scenario 6
section "SCENARIO 6: a busy verdict is also parked on the long cadence"
tmux new-window -t fmlab -n fm-busy -d
sleep 0.5
make_meta busy fmlab:fm-busy pi
printf 'done: investigation finished\n' > "$LAB/state/busy.status"
prime_seen busy
gen=$(run_lab "$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" busy)
run_lab "$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" busy busy --gen "$gen" --source pi-ext --event agent-start
printf '%s\n' "$(date +%s)" > "$LAB/state/busy.deliberate-stop"
touch -t 200001010000 "$LAB/state/busy.meta"
reset_watch
rm -f "$LAB/state/.hash-fmlab_fm-busy" "$LAB/state/.count-fmlab_fm-busy"
echo "--- watcher with FM_BUSY_TURN_MAX_SECS=1 (meta aged to year 2000), marker fresh ---"
watch_run 9 FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_SECONDMATE_LIVENESS_SECS=999999
echo "watcher rc=$? (124 = absorbed, no wake)"
echo "--- wedge timer for the busy window (must be absent) ---"
ls "$LAB/state"/.stale-since-fmlab_fm-busy 2>&1 || true
echo "--- busy-turn recheck past the cadence ---"
reset_watch
touch -d "@$(( $(date +%s) - 500 ))" "$LAB/state/busy.deliberate-stop"
watch_run 20 FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=240 \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_SECONDMATE_LIVENESS_SECS=999999
echo "watcher rc=$?"
echo "--- queued wake reason ---"
cat "$LAB/state/.wake-queue" 2>/dev/null

# ---------------------------------------------------------------- Scenario 7
section "SCENARIO 7: teardown clears the deliberate-stop marker"
PROJ="$LAB/proj3"; ORIGIN="$LAB/origin3.git"
git init --bare -q "$ORIGIN"
git init -q -b main "$PROJ"
( cd "$PROJ" && printf 'x\n' > a.txt && git add a.txt \
  && git -c user.email=t@t -c user.name=t commit -qm init \
  && git remote add origin "$ORIGIN" && git push -q -u origin main )
WT=$(cd "$PROJ" && TREEHOUSE_ROOT="$LAB/th" treehouse get --lease 2>/dev/null)
tmux new-window -t fmlab -n fm-teardown -d
mkdir -p "$LAB/data/teardown"
printf '# brief\n' > "$LAB/data/teardown/brief.md"
{
  echo "window=fmlab:fm-teardown"
  echo "endpoint_task_id=teardown"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "spawn_gen=teardowngen1"
} > "$LAB/state/teardown.meta"
printf '%s\n' "$(date +%s)" > "$LAB/state/teardown.deliberate-stop"
echo "marker before teardown: $(ls "$LAB/state/teardown.deliberate-stop")"
echo "--- fm-teardown.sh teardown --force ---"
run_lab env TREEHOUSE_ROOT="$LAB/th" "$ROOT/bin/fm-teardown.sh" teardown --force 2>&1 | tail -6
echo "--- marker after teardown ---"
if [ -e "$LAB/state/teardown.deliberate-stop" ]; then
  echo "UNEXPECTED: marker still present"
else
  echo "confirmed: teardown cleared the deliberate-stop marker"
fi

echo
echo "driver complete"
