#!/usr/bin/env bash
# Live end-to-end proof for fm-launch-prompt-busy-bound.
#
# Drives the REAL claude binary into its real trust dialog in a throwaway git
# worktree on an isolated tmux server, then runs the REAL supervision watcher
# (bin/fm-watch.sh) against that real parked pane with an isolated FM_HOME and a
# scratch busy-state record armed exactly as fm-spawn.sh does at launch.
#
#   fixed  run: the launch-prompt backstop is live -> the watcher must SURFACE
#               the parked launch promptly (prints "stale: ..." and exits)
#   control run: the backstop's Claude signature is disabled via its documented
#               env override, reproducing the pre-fix busy verdict -> the
#               watcher must NOT surface inside the same budget (it keeps
#               absorbing as "busy fm-spawn", the one-hour bound)
set -u

ROOT=/home/ivanl/.no-mistakes/worktrees/bfc710bdae80/01M33PWK6YN00GY8BRRD1BQZG8
EV="$ROOT/bin/fm-busy-event.sh"
WATCH="$ROOT/bin/fm-watch.sh"
CLAUDE=$(command -v claude)
SESS="fm-lp-watch-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lp-watch.XXXXXX")

cleanup() {
  tmux kill-session -t "$SESS" >/dev/null 2>&1 || true
  tmux kill-server >/dev/null 2>&1 || true
  rm -rf -- "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB/wt" "$LAB/home/state" "$LAB/home/config"
git -C "$LAB/wt" init -q

tmux new-session -d -s "$SESS" -n w -c "$LAB/wt" -- "$CLAUDE" --dangerously-skip-permissions hello
target="$SESS:w"

tail=''
for _ in $(seq 1 75); do
  tail=$(tmux capture-pane -p -t "$target" -S -40 2>/dev/null) || true
  printf '%s' "$tail" | grep -qiE 'Is this a project you created or one you trust' && break
  sleep 0.2
done
if ! printf '%s' "$tail" | grep -qiE 'Is this a project you created or one you trust'; then
  echo "FATAL: real claude never rendered its trust dialog"
  exit 1
fi
printf '%s' "$tail" > "$LAB/real-parked-tail.txt"

setup_home() {  # <home>
  local home=$1
  mkdir -p "$home/state" "$home/config"
  printf 'window=%s\nbackend=tmux\nharness=claude\nworktree=%s\nkind=ship\n' "$target" "$LAB/wt" > "$home/state/t1.meta"
  "$EV" arm "$home/state" t1 >/dev/null
}

run_watch() {  # <home> <log> <extra-env...>
  local home=$1 log=$2
  shift 2
  local start end rc
  start=$(date +%s)
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" \
    timeout 25 "$WATCH" > "$log" 2>&1
  rc=$?
  end=$(date +%s)
  echo "$rc $((end - start))"
}

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

echo "== real captured parked tail (production tmux capture-pane -p -S -40) =="
cat "$LAB/real-parked-tail.txt"
echo

# --- fixed run: backstop live ------------------------------------------------
setup_home "$LAB/home"
fixed_verdict=$(fm_busy_classify tmux "$target" claude t1 "$LAB/home/state" "$(cat "$LAB/real-parked-tail.txt")")
echo "== classifier on the real captured pane =="
echo "fixed-verdict: $fixed_verdict"

read -r fixed_rc fixed_secs <<EOF
$(run_watch "$LAB/home" "$LAB/fixed.log")
EOF
echo "== fixed run (backstop live) =="
echo "watcher-exit: $fixed_rc after ${fixed_secs}s"
echo "watcher-stdout:"; cat "$LAB/fixed.log"

# --- control run: backstop disabled (pre-fix busy verdict) -------------------
control_home="$LAB/control"
setup_home "$control_home"
read -r control_rc control_secs <<EOF
$(run_watch "$control_home" "$LAB/control.log" \
  FM_BUSY_CLAUDE_TRUST_PROMPT_REGEX='NEVER_MATCH_PREFIX_XYZ')
EOF
echo "== control run (Claude signature disabled) =="
echo "watcher-exit: $control_rc after ${control_secs}s"
echo "watcher-stdout:"; cat "$LAB/control.log"

echo "== result =="
if [ "$fixed_verdict" = "unknown launch-prompt" ]; then
  echo "PASS classifier: real parked pane -> $fixed_verdict"
else
  echo "FAIL classifier: got '$fixed_verdict'"
fi
if [ "$fixed_rc" = 0 ] && grep -q '^stale:' "$LAB/fixed.log"; then
  echo "PASS fixed: parked launch surfaced promptly (exit 0 after ${fixed_secs}s with stale:)"
else
  echo "FAIL fixed: parked launch did not surface (exit $fixed_rc)"
fi
if [ "$control_rc" = 124 ] && ! grep -q '^stale:' "$LAB/control.log"; then
  echo "PASS control: without the backstop the parked launch stays absorbed as busy (no wake in ${control_secs}s)"
else
  echo "CONTROL-UNEXPECTED: exit $control_rc, stdout above"
fi
