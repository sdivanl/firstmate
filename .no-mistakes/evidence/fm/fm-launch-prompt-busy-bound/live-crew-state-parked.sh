#!/usr/bin/env bash
# Live driver: prove bin/fm-crew-state.sh reports a launch parked on a real
# Claude trust dialog as `unknown ... launch-prompt` (not `working`), using a
# real tmux pane and the real claude binary. Scratch state lives outside the
# worktree; nothing is answered (Escape only) and no model tokens are spent.
set -u

ROOT=${ROOT:?set ROOT to the worktree}
SOCK=default
SESSION="fm-lp-crewstate-$$"
ID=lp
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lp-crewstate.XXXXXX")
WT="$LAB/wt"
STATE="$LAB/state"
mkdir -p "$WT" "$STATE"
git -C "$WT" init -q
git -C "$WT" symbolic-ref HEAD refs/heads/fm/feat-lp
CLAUDE_BIN=$(command -v claude)

cleanup() {
  tmux kill-session -t "$SESSION" >/dev/null 2>&1 || true
  rm -rf -- "$LAB"
}
trap cleanup EXIT

echo "== lab: $LAB"
echo "== claude: $($CLAUDE_BIN --version 2>&1)"

# Real launch into a brand-new worktree under the operator's onboarded config:
# claude parks on its workspace-trust dialog.
tmux new-session -d -s "$SESSION" -n w -c "$WT" -- "$CLAUDE_BIN" --dangerously-skip-permissions hello
TARGET="$SESSION:w"

tail=''
for _ in $(seq 1 75); do
  tail=$(tmux capture-pane -p -t "$TARGET" -S -40 2>/dev/null) || true
  printf '%s' "$tail" | grep -qiE 'Is this a project you created or one you trust' && break
  sleep 0.2
done
if ! printf '%s' "$tail" | grep -qiE 'Is this a project you created or one you trust'; then
  echo "FAIL: claude never rendered its trust dialog within 15s; tail:"; printf '%s\n' "$tail"; exit 1
fi
echo "== real claude trust dialog captured:"
printf '%s\n' "$tail"

printf 'window=%s\nbackend=tmux\nharness=claude\nworktree=%s\nkind=scout\n' "$TARGET" "$WT" > "$STATE/$ID.meta"
"$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID" >/dev/null

echo
echo "== bin/fm-crew-state.sh $ID (real script, real tmux pane, armed fm-spawn record)"
out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LAB" FM_STATE_OVERRIDE="$STATE" \
  "$ROOT/bin/fm-crew-state.sh" "$ID" 2>&1)
echo "$out"

echo
echo "== bin/fm-busy-classify direct read of the same real capture"
# classify via the library the production way
verdict=$(bash -c '
  . "$1/bin/fm-busy-lib.sh"
  fm_busy_classify tmux "$2" claude "$3" "$4" "$5"
' _ "$ROOT" "$TARGET" "$ID" "$STATE" "$tail")
echo "fm_busy_classify -> $verdict"

case "$out" in
  *"state: unknown"*launch-prompt*) ;;
  *) echo "FAIL: expected 'state: unknown' naming launch-prompt"; exit 1 ;;
esac
case "$out" in
  *"state: working"*) echo "FAIL: parked launch read as working"; exit 1 ;;
esac
[ "$verdict" = "unknown launch-prompt" ] || { echo "FAIL: direct classify was '$verdict'"; exit 1; }

tmux send-keys -t "$TARGET" Escape >/dev/null 2>&1 || true
echo
echo "PASS: real parked launch reads unknown/launch-prompt, never working"
