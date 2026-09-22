#!/usr/bin/env bash
# Focused live reproduction: a same-project nested projected spawn, then normal
# teardown, asserting the presentation journal is retired. Runs real Herdr via
# the guarded lab helper and a real Treehouse pool. Diagnostic only.
set -u
ROOT=/home/ivanl/.no-mistakes/worktrees/bfc710bdae80/01M346VGZPKZYFCNRF23TPBJEF
OUT=/home/ivanl/.no-mistakes/evidence/01M346VGZPKZYFCNRF23TPBJEF/repro
rm -rf "$OUT"; mkdir -p "$OUT"
export OUT
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
REAL_HERDR=$(command -v herdr)
REAL_TREEHOUSE=$(command -v treehouse)
HERDR_ORIGINAL_PATH=$PATH
export FM_GATE_REFUSE_BYPASS=1

TMP_ROOT=$(mktemp -d /tmp/fm-nested-repro.XXXXXX)
FAKEBIN="$TMP_ROOT/fakebin"; mkdir -p "$FAKEBIN"
export HERDR_LAB_SESSION
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-nested-repro) || exit 1
export HERDR_SESSION="$HERDR_LAB_SESSION"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
ORIG_ARGS=("$@")
args=("$@")
n=$((${#args[@]} - 1)); f=$((n - 1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$f]}" = --session ] && [ "${args[$n]}" = "${HERDR_LAB_SESSION:?}" ]; then
  unset "args[$n]" "args[$f]"
fi
set -- "${args[@]}"
out=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@")
status=$?
if [ "${1:-} ${2:-}" = "workspace list" ]; then
  printf '%s\n' "$out" >> "$OUT/workspace-list-calls.jsonl"
fi
printf '%s\n' "$out"
exit "$status"
SH
cat > "$FAKEBIN/treehouse" <<SH
#!/usr/bin/env bash
exec "$REAL_TREEHOUSE" "\$@"
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/treehouse"
export PATH="$FAKEBIN:$PATH"
export REAL_HERDR REAL_TREEHOUSE HERDR_LAB_HELPER HERDR_ORIGINAL_PATH

unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || exit 1
trap 'PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true; for w in ${WORKTREES:-}; do "$REAL_TREEHOUSE" return --force "$w" >/dev/null 2>&1 || true; done; rm -rf "$TMP_ROOT"' EXIT

lab() { PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

HOME_DIR="$TMP_ROOT/home"; PROJ="$TMP_ROOT/project"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data/shape" "$PROJ"
: > "$HOME_DIR/config/herdr-presentation-spaces"
cat > "$HOME_DIR/data/shape/brief.md" <<EOF
# Task
## Captain's intent
Nested teardown reproduction.

## Firstmate spec
Probe.
EOF
git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='T' -c user.email='t@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

read -r WS_PRIMARY WS_TAB WS_PANE <<EOF
$(lab workspace create --cwd "$PROJ" --label firstmate --no-focus | jq -r '[.result.workspace.workspace_id,.result.tab.tab_id,.result.root_pane.pane_id]|@tsv')
EOF
LAUNCH_PANE=$(lab tab create --workspace "$WS_PRIMARY" --cwd "$TMP_ROOT" --label captain-shell --no-focus | jq -r '.result.root_pane.pane_id')
LAB_SOCKET=$(lab session list --json | jq -r --arg s "$HERDR_LAB_SESSION" '.sessions[]|select(.name==$s)|.socket_path')
echo "session=$HERDR_LAB_SESSION ws=$WS_PRIMARY launch=$LAUNCH_PANE" | tee "$OUT/setup.txt"

env HERDR_ENV=1 HERDR_PANE_ID="$LAUNCH_PANE" HERDR_SESSION="$HERDR_LAB_SESSION" \
  HERDR_SOCKET_PATH="$LAB_SOCKET" FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" shape "$PROJ" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr \
  > "$OUT/spawn.out" 2> "$OUT/spawn.err"
echo "spawn rc=$?" | tee -a "$OUT/setup.txt"
META="$HOME_DIR/state/shape.meta"
JOURNAL="$HOME_DIR/state/shape.herdr-presentation"
WT=$(grep '^worktree=' "$META" | cut -d= -f2-); WORKTREES=$WT
WSID=$(grep '^herdr_workspace_id=' "$META" | cut -d= -f2-)
PANE=$(grep '^herdr_pane_id=' "$META" | cut -d= -f2-)
echo "wt=$WT wsid=$WSID pane=$PANE" | tee -a "$OUT/setup.txt"
lab worktree list --workspace "$WS_PRIMARY" > "$OUT/worktree-list-after-spawn.json"
lab workspace list > "$OUT/workspace-list-before-teardown.json"
cat "$JOURNAL" > "$OUT/journal-before-teardown.txt"
# Direct binding probe exactly as teardown computes it.
( . "$ROOT/bin/backends/herdr.sh"
  fm_backend_herdr_projection_endpoint_matches_journal "$HERDR_LAB_SESSION" "$WSID" "$JOURNAL" shape
  echo "binding_rc=$?" ) > "$OUT/binding-probe.txt" 2>&1

# Emulate teardown's leak reaping (lsof-based cwd scan under the worktree) and
# observe whether the nested workspace survives.
RPIDS=$(lsof -t +D "$WT" 2>/dev/null | sort -u | tr '\n' ' ')
echo "manual reap pids: $RPIDS" > "$OUT/manual-reap.txt"
for p in $RPIDS; do [ "$p" = "$$" ] && continue; kill -TERM "$p" 2>/dev/null || true; done
sleep 2
lab workspace list > "$OUT/workspace-list-after-manual-reap.json"
if jq -e --arg w "$WSID" '[.result.workspaces[]?|select(.workspace_id==$w)]|length==1' "$OUT/workspace-list-after-manual-reap.json" >/dev/null 2>&1; then
  echo "workspace survived manual reap" >> "$OUT/manual-reap.txt"
else
  echo "workspace GONE after manual reap" >> "$OUT/manual-reap.txt"
fi
cat "$OUT/manual-reap.txt"

FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  "$ROOT/bin/fm-teardown.sh" shape --force > "$OUT/teardown.out" 2> "$OUT/teardown.err"
echo "teardown rc=$?" | tee -a "$OUT/setup.txt"
[ -e "$JOURNAL" ] && echo "JOURNAL_STILL_PRESENT" || echo "JOURNAL_RETIRED"
echo "--- teardown.err ---"; cat "$OUT/teardown.err"
