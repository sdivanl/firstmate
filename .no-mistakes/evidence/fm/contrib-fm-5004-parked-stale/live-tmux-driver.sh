#!/usr/bin/env bash
# Live end-to-end verification of issue #5004 deliberate-stop parking using a
# REAL tmux server on a private socket (no fake tmux). The watcher is the real
# bin/fm-watch.sh; the pane is a real tmux window whose agent printed a
# finished-style line and then sat idle - exactly the "finished worker whose
# endpoint was deliberately stopped" the report describes.
set -u
ROOT="${ROOT:?}"
EVID="${EVID:?}"
SOCK="fm-live-parked-$$"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-parked.XXXXXX")
REAL_TMUX=$(command -v tmux)
SHIM="$TMP/bin"; mkdir -p "$SHIM" "$TMP/nonrepo"
printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$REAL_TMUX" "$SOCK" > "$SHIM/tmux"
chmod +x "$SHIM/tmux"
cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$REAL_TMUX" -L "$SOCK" new-session -d -s live -n fm-parked \
  "bash -c 'printf \"done: investigation finished\\n\\$ \"; sleep 900'"
sleep 0.6

STATE="$TMP/state"; mkdir -p "$STATE"
printf 'window=live:fm-parked\nkind=ship\nbackend=tmux\n' > "$STATE/parked.meta"
printf 'done: investigation finished\n' > "$STATE/parked.status"
date +%s > "$STATE/parked.deliberate-stop"
KEY="live_fm-parked"

# Declare the pre-existing status already seen through the production signature
# owner, so the per-poll signal scan does not fire on it (same as a real home
# where the status was reported before the stop).
FM_STATE_OVERRIDE="$STATE" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_status_mark_current "$2" "$3"
' _ "$ROOT" "$STATE" "$STATE/parked.status"

run_watch() {  # <pause-secs> <out> <err>
  PATH="$SHIM:$PATH" FM_STATE_OVERRIDE="$STATE" FM_HOME="$TMP/home" \
    FM_ROOT_OVERRIDE="$TMP/nonrepo" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_ALARM_EXEC=discard \
    FM_PAUSE_RESURFACE_SECS="$1" exec "$ROOT/bin/fm-watch.sh" > "$2" 2> "$3"
}

echo "=== Real tmux session ==="
"$REAL_TMUX" -L "$SOCK" list-windows -t live

echo
echo "=== Phase A: fresh deliberate stop must be absorbed, never wedge-escalated ==="
run_watch 999 "$TMP/a.out" "$TMP/a.err" &
pid=$!
sleep 6
alive=1; kill -0 "$pid" 2>/dev/null || alive=0
echo "watcher alive after ~6 poll cycles: $alive"
echo "phase A stdout bytes: $(wc -c < "$TMP/a.out")"
echo "phase A stdout:"; cat "$TMP/a.out"
echo "phase A stderr:"; cat "$TMP/a.err"
echo "wedge timer present: $([ -e "$STATE/.stale-since-$KEY" ] && echo yes || echo no)"
echo "wedge escalation counter present: $([ -e "$STATE/.wedge-escalations-$KEY" ] && echo yes || echo no)"
echo "stale suppressor advanced: $([ -s "$STATE/.stale-$KEY" ] && echo yes || echo no)"
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true

echo
echo "=== Phase B: past the cadence it re-surfaces as a bounded recheck, never a wedge ==="
rm -f "$STATE/.watcher-down" "$STATE/.wake-queue" "$STATE/.wake-queue.seq" "$STATE/.watch-deliveries.log" "$STATE/.deliberate-stop-resurfaced-$KEY"
touch -d "@$(( $(date +%s) - 500 ))" "$STATE/parked.deliberate-stop"
run_watch 240 "$TMP/b.out" "$TMP/b.err" &
bpid=$!
exited=0
for _ in $(seq 1 300); do
  kill -0 "$bpid" 2>/dev/null || { exited=1; break; }
  sleep 0.1
done
wait "$bpid" 2>/dev/null || true
echo "watcher exited on the recheck: $exited"
echo "phase B stdout:"; cat "$TMP/b.out"
echo "phase B stderr:"; cat "$TMP/b.err"
echo "deliberate-stop re-surface throttle present: $([ -e "$STATE/.deliberate-stop-resurfaced-$KEY" ] && echo yes || echo no)"
echo "wedge timer present after recheck: $([ -e "$STATE/.stale-since-$KEY" ] && echo yes || echo no)"

echo
echo "=== Phase C (adversarial): same finished idle task with NO marker still wedge-escalates ==="
rm -f "$STATE/parked.deliberate-stop" "$STATE/.deliberate-stop-resurfaced-$KEY" \
  "$STATE/.stale-$KEY" "$STATE/.stale-since-$KEY" "$STATE/.wedge-escalations-$KEY" \
  "$STATE/.watcher-down" "$STATE/.wake-queue" "$STATE/.wake-queue.seq" "$STATE/.watch-deliveries.log"
printf '1\n' > "$STATE/.count-$KEY"   # one prior identical sighting -> stable on next poll
run_watch 240 "$TMP/c.out" "$TMP/c.err" &
cpid=$!
cexited=0
for _ in $(seq 1 400); do
  kill -0 "$cpid" 2>/dev/null || { cexited=1; break; }
  sleep 0.1
done
wait "$cpid" 2>/dev/null || true
echo "watcher exited on the marker-less finished task: $cexited"
echo "phase C stdout:"; cat "$TMP/c.out"
echo "phase C stderr:"; cat "$TMP/c.err"

echo
echo "=== Phase D: a re-stop after relaunch absorbs on first sight despite the old throttle ==="
# Simulate the relaunch+stop sequence: the previous phase's throttle survives
# while the stop itself is refreshed (relaunch then a second fm-control exit).
printf 'deliberate-stop:%s' "$(( $(date +%s) - 1000 ))" > "$STATE/.deliberate-stop-resurfaced-$KEY" || true
touch -d "@$(( $(date +%s) - 1000 ))" "$STATE/.deliberate-stop-resurfaced-$KEY" || true
date +%s > "$STATE/parked.deliberate-stop"
rm -f "$STATE/.watcher-down" "$STATE/.wake-queue" "$STATE/.wake-queue.seq" "$STATE/.watch-deliveries.log" \
  "$STATE/.stale-$KEY" "$STATE/.stale-since-$KEY" "$STATE/.wedge-escalations-$KEY"
run_watch 999 "$TMP/d.out" "$TMP/d.err" &
dpid=$!
sleep 6
dalive=1; kill -0 "$dpid" 2>/dev/null || dalive=0
echo "watcher alive after re-stop (first-sight absorb expected): $dalive"
echo "phase D stdout bytes: $(wc -c < "$TMP/d.out")"
echo "phase D stdout:"; cat "$TMP/d.out"
echo "phase D stderr:"; cat "$TMP/d.err"
kill "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null || true

# Evidence
cp "$TMP/a.out" "$EVID/live-tmux-phaseA-absorb.out" 2>/dev/null || true
cp "$TMP/b.out" "$EVID/live-tmux-phaseB-recheck.out" 2>/dev/null || true
cp "$TMP/c.out" "$EVID/live-tmux-phaseC-adversarial.out" 2>/dev/null || true
{
  echo "REAL tmux server on private socket; real bin/fm-watch.sh; pane idle after a finished status line."
  echo "Phase A (fresh deliberate stop, 6 polls): watcher alive=$alive; stdout bytes=$(wc -c < "$TMP/a.out"); wedge timer=$([ -e "$STATE/.stale-since-$KEY" ] && echo yes || echo no)"
  echo "Phase B (marker aged 500s, PAUSE_RESURFACE_SECS=240): exited=$exited; stdout:"
  cat "$TMP/b.out"
  echo "Phase C (marker removed, adversarial, PAUSE_RESURFACE_SECS=240): exited=$cexited; stdout:"
  cat "$TMP/c.out"
  echo "Phase D (re-stop with old throttle, first-sight absorb): watcher alive=$dalive; stdout bytes=$(wc -c < "$TMP/d.out")"
} > "$EVID/live-tmux-summary.txt"
cp "$TMP/d.out" "$EVID/live-tmux-phaseD-restop.out" 2>/dev/null || true
