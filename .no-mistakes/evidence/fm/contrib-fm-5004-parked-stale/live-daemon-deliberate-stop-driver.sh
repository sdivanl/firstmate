#!/usr/bin/env bash
# Live away-mode-daemon driver for the deliberate-stop marker (firstmate #5004).
#
# The committed guard tests/fm-deliberate-stop-live-e2e.test.sh stands up the
# real control plane, watcher, teardown, and relaunch over real tmux. This driver
# fills the remaining gap the repo's own fm-daemon.test.sh covers only over a
# SHIMMED tmux: it sources the REAL bin/fm-supervise-daemon.sh functions and runs
# them against a REAL tmux server on a private socket, so the daemon's
# classify_stale / handle_wake / housekeeping paths touch a real endpoint.
#
# Scenarios:
#   D1  classify_stale parks a deliberately stopped task (pause action)
#   D2  handle_wake records the pause marker anchored on the stop epoch, and the
#       very next housekeeping tick re-surfaces it (no doubled window)
#   D3  adversarial: a pre-aged wedge marker + deliberate marker is dropped by
#       housekeeping with no escalation
#   D4  adversarial: the same pre-aged wedge marker with NO deliberate marker
#       still escalates as "possible wedge" (marker is load-bearing)
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_REPO_ROOT:?set FM_REPO_ROOT to the worktree under test}"
REAL_TMUX=$(command -v tmux) || { echo "skip: tmux absent"; exit 0; }
SOCKET="fm-ds-daemon-live-$$"
SESSION="live"
SHIM=$(mktemp -d "${TMPDIR:-/tmp}/fm-ds-daemon-shim.XXXXXX")
STATE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-ds-daemon-state.XXXXXX")

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$SHIM" "$STATE_ROOT"
}
trap cleanup EXIT

cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM/tmux"
PATH="$SHIM:$PATH"
export PATH

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50 \
  || { echo "not ok - could not start private tmux server"; exit 1; }

# shellcheck source=bin/fm-supervise-daemon.sh
. "$ROOT/bin/fm-supervise-daemon.sh"

pass() { echo "ok - $1"; }
fail() { echo "not ok - $1"; exit 1; }

new_pane() {  # <window>
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$1" \
    "bash -c 'printf \"done: investigation finished\\n\$ \"; exec bash'" \
    || fail "could not create pane $1"
}

mk_task() {  # <task> <window> -> echoes state dir
  local task=$1 win=$2 st="$STATE_ROOT/$1" key ident
  mkdir -p "$st"
  printf 'window=%s\nkind=ship\nbackend=tmux\nharness=pi\n' "$SESSION:$win" > "$st/$task.meta"
  printf 'done: investigation finished\n' > "$st/$task.status"
  key=$(printf '%s' "$task" | tr ':/.' '___')
  ident=$(_fm_open_decisions_file_ident "$st/$task.status")
  printf '%s@%s' "$(wc -c < "$st/$task.status" | tr -d '[:space:]')" "$ident" \
    > "$st/.subsuper-seen-status-$key"
  printf '%s\n' "$(date +%s)" > "$st/.subsuper-last-scan"
  printf '%s' "$st"
}

age_marker() {  # <file> <secs-ago>
  "$REAL_TMUX" -L "$SOCKET" display-message -p '#{pid}' >/dev/null 2>&1 || true
  touch -d "@$(( $(date +%s) - $2 ))" "$1"
}

# --- D1 + D2: classify parks, first recheck anchored on the stop -------------
new_pane fm-park-resurface
ST1=$(mk_task park-resurface fm-park-resurface)
fm_control_deliberate_stop_record "$ST1" park-resurface
age_marker "$ST1/park-resurface.deliberate-stop" 500

out=$(FM_HOME="$ST1" FM_STATE_OVERRIDE="$ST1" \
  classify_stale "$SESSION:fm-park-resurface" "$ST1")
case "$out" in
  pause\|*"deliberately stopped"*) ;;
  *) fail "D1: deliberately parked task did not classify as pause: $out" ;;
esac
pass "D1 real-tmux: classify_stale parks a deliberately stopped task (pause, not wedge): $out"

reason="stale: $SESSION:fm-park-resurface (deliberately stopped 500s ago, rechecked on a long cadence not a wedge; relaunch the worker or clean up the finished task)"
FM_HOME="$ST1" FM_STATE_OVERRIDE="$ST1" LOG="$ST1/daemon.log" \
  handle_wake "$reason" "$ST1"
[ -e "$ST1/.subsuper-paused-park-resurface" ] \
  || fail "D2: the deliberate-stop wake did not record a pause marker"
# pause_marker_record anchors on the stop marker's MTIME (when the stop was
# recorded), which is what opens the first recheck window.
stop_epoch=$(stat -c %Y "$ST1/park-resurface.deliberate-stop")
paused_epoch=$(cat "$ST1/.subsuper-paused-park-resurface")
[ "$paused_epoch" = "$stop_epoch" ] \
  || fail "D2: pause marker ($paused_epoch) was not anchored on the stop mtime ($stop_epoch): doubled window"

FM_HOME="$ST1" FM_STATE_OVERRIDE="$ST1" FM_ESCALATE_BATCH_SECS=999999 \
  FM_PAUSE_RESURFACE_SECS=240 FM_STALE_ESCALATE_SECS=240 \
  FM_HEARTBEAT_SCAN_SECS=999999 housekeeping "$ST1"
grep -F "deliberately stopped" "$ST1/.subsuper-escalations" >/dev/null 2>&1 \
  || fail "D2: the parked task was not re-surfaced on its first recheck: $(cat "$ST1/.subsuper-escalations" 2>/dev/null || true)"
grep -F "possible wedge" "$ST1/.subsuper-escalations" >/dev/null 2>&1 \
  && fail "D2: the parked task re-surfaced as a possible wedge"
pass "D2 real-tmux: handle_wake anchors the pause marker on the stop epoch and the very next housekeeping tick re-surfaces it as a deliberate-stop recheck"

# --- D3: a pre-aged wedge marker is dropped for a deliberate stop ------------
new_pane fm-park-wedge
ST2=$(mk_task park-wedge fm-park-wedge)
fm_control_deliberate_stop_record "$ST2" park-wedge
age_marker "$ST2/park-wedge.deliberate-stop" 500
echo $(( $(date +%s) - 5000 )) > "$ST2/.subsuper-stale-park-wedge"

FM_HOME="$ST2" FM_STATE_OVERRIDE="$ST2" FM_ESCALATE_BATCH_SECS=999999 \
  FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=240 \
  FM_HEARTBEAT_SCAN_SECS=999999 housekeeping "$ST2"
[ ! -e "$ST2/.subsuper-stale-park-wedge" ] \
  || fail "D3: a pre-aged wedge marker survived a deliberate stop"
[ ! -s "$ST2/.subsuper-escalations" ] \
  || fail "D3: a deliberately parked task wedge-escalated: $(cat "$ST2/.subsuper-escalations")"
pass "D3 real-tmux: housekeeping drops a pre-aged wedge marker for a deliberately stopped task without escalating"

# --- D4 adversarial: the same marker with no deliberate stop still escalates -
new_pane fm-park-nomarker
ST3=$(mk_task park-nomarker fm-park-nomarker)
echo $(( $(date +%s) - 5000 )) > "$ST3/.subsuper-stale-park-nomarker"

FM_HOME="$ST3" FM_STATE_OVERRIDE="$ST3" FM_ESCALATE_BATCH_SECS=999999 \
  FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=240 \
  FM_HEARTBEAT_SCAN_SECS=999999 housekeeping "$ST3"
grep -F "stale persisted" "$ST3/.subsuper-escalations" >/dev/null 2>&1 \
  || fail "D4: a marker-less stale pane no longer wedge-escalated: $(cat "$ST3/.subsuper-escalations" 2>/dev/null || true)"
grep -F "possible wedge" "$ST3/.subsuper-escalations" >/dev/null 2>&1 \
  || fail "D4: the marker-less escalation was not the ordinary possible-wedge path"
pass "D4 adversarial real-tmux: the same pre-aged wedge marker with no deliberate stop still escalates as a possible wedge"
