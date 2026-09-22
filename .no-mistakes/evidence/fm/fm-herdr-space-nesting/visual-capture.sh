#!/usr/bin/env bash
# Focused live visual capture: a same-project crewmate task space renders as a
# child level under its exact home space in the Herdr sidebar, while a
# foreign-project task stays top-level beside it.
#
# All lab lifecycle goes through bin/fm-herdr-lab.sh with a throwaway
# fm-lab-* session. The TUI screen is captured through a fixed-size tmux pane
# so the sidebar grid is readable.
set -u

ROOT=${ROOT:?}
EVIDENCE_DIR=${EVIDENCE_DIR:?}
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
REAL_HERDR=$(command -v herdr)
REAL_TREEHOUSE=$(command -v treehouse)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-visual.XXXXXX")
HERDR_LAB_SESSION=$(PATH="$PATH" "$HERDR_LAB_HELPER" name fm-herdr-visual)
export HERDR_LAB_SESSION
LAB_READY=0
RECORDED_WORKTREES=""
TMUX_SESSION=fmvis-capture

log() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; cleanup; exit 1; }

lab() { PATH="$PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

cleanup() {
  tmux kill-session -t "$TMUX_SESSION" >/dev/null 2>&1 || true
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    [ -d "$wt" ] || continue
    "$REAL_TREEHOUSE" return --force "$wt" >/dev/null 2>&1 || true
  done <<EOF
$RECORDED_WORKTREES
EOF
  if [ "$LAB_READY" = 1 ]; then
    "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true
    LAB_READY=0
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

make_project() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# Visual capture fixture\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='FM Test' -c user.email='t@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}

write_ship_brief() {
  local home=$1 id=$2
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Visual capture fixture $id

## Firstmate spec
Fixture.
EOF
}

remember_wt() {
  local wt
  wt=$(grep '^worktree=' "$1" | cut -d= -f2-)
  [ -n "$wt" ] || fail "metadata did not record a worktree"
  RECORDED_WORKTREES="${RECORDED_WORKTREES}${wt}"$'\n'
}

spawn_task() {
  local id=$1 home=$2 project=$3
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr
}

HOME_DIR="$TMP_ROOT/home"
PROJECT_DIR="$TMP_ROOT/project"
FOREIGN_DIR="$TMP_ROOT/foreign"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
touch "$HOME_DIR/state/.last-watcher-beat"
make_project "$PROJECT_DIR"
make_project "$FOREIGN_DIR"
write_ship_brief "$HOME_DIR" anchor
write_ship_brief "$HOME_DIR" nested-task
write_ship_brief "$HOME_DIR" foreign-task

# The anchor, opted out of projection, establishes the home's own workspace
# (labeled "firstmate") that later projected children hang beneath.
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null 2>&1 || fail "could not provision lab"
LAB_READY=1
HERDR_SESSION="$HERDR_LAB_SESSION" spawn_task anchor "$HOME_DIR" "$PROJECT_DIR" \
  > "$TMP_ROOT/anchor.err" 2>&1 || fail "anchor spawn failed: $(cat "$TMP_ROOT/anchor.err")"
remember_wt "$HOME_DIR/state/anchor.meta"

# Default-on projection for the same-project task, plus a foreign-project task.
rm -f "$HOME_DIR/config/herdr-presentation-spaces"
HERDR_SESSION="$HERDR_LAB_SESSION" spawn_task nested-task "$HOME_DIR" "$PROJECT_DIR" \
  > "$TMP_ROOT/nested.err" 2>&1 || fail "nested spawn failed: $(cat "$TMP_ROOT/nested.err")"
remember_wt "$HOME_DIR/state/nested-task.meta"
HERDR_SESSION="$HERDR_LAB_SESSION" spawn_task foreign-task "$HOME_DIR" "$FOREIGN_DIR" \
  > "$TMP_ROOT/foreign.err" 2>&1 || fail "foreign spawn failed: $(cat "$TMP_ROOT/foreign.err")"
remember_wt "$HOME_DIR/state/foreign-task.meta"

HOME_WSID=$(grep '^herdr_workspace_id=' "$HOME_DIR/state/anchor.meta" | cut -d= -f2-)
NESTED_WSID=$(grep '^herdr_workspace_id=' "$HOME_DIR/state/nested-task.meta" | cut -d= -f2-)
FOREIGN_WSID=$(grep '^herdr_workspace_id=' "$HOME_DIR/state/foreign-task.meta" | cut -d= -f2-)

# Machine-readable proof of the hierarchy Herdr renders.
lab workspace list > "$EVIDENCE_DIR/visual-workspace-list.json" 2>/dev/null || true
lab worktree list --workspace "$HOME_WSID" > "$EVIDENCE_DIR/visual-worktree-list-home.json" 2>/dev/null || true
{
  printf 'home_workspace=%s\n' "$HOME_WSID"
  printf 'nested_workspace=%s\n' "$NESTED_WSID"
  printf 'foreign_workspace=%s\n' "$FOREIGN_WSID"
} > "$EVIDENCE_DIR/visual-workspace-ids.txt"

# Capture the rendered sidebar through a fixed-size tmux client. The pty is
# non-zero (120x40) before the TUI reads its grid.
tmux kill-session -t "$TMUX_SESSION" >/dev/null 2>&1 || true
tmux new-session -d -s "$TMUX_SESSION" -x 120 -y 40 \
  "env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH -u HERDR_SESSION TERM=xterm-256color $REAL_HERDR --session $HERDR_LAB_SESSION" \
  || fail "could not start tmux viewer"
sleep 6
tmux capture-pane -p -e -t "$TMUX_SESSION" > "$EVIDENCE_DIR/visual-sidebar.txt" 2>/dev/null || true
tmux capture-pane -p -t "$TMUX_SESSION" > "$EVIDENCE_DIR/visual-sidebar-plain.txt" 2>/dev/null || true
tmux kill-session -t "$TMUX_SESSION" >/dev/null 2>&1 || true

log "=== workspace list ==="
cat "$EVIDENCE_DIR/visual-workspace-list.json"
log ""
log "=== worktree list home ==="
cat "$EVIDENCE_DIR/visual-worktree-list-home.json"
log ""
log "=== plain sidebar capture ==="
cat "$EVIDENCE_DIR/visual-sidebar-plain.txt"
