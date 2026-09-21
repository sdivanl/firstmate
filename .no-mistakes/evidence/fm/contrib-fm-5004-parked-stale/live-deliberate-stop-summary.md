# Deliberate-stop (#5004) live validation — fixed test-phase round

The previous test round returned `inconclusive` because 8 of 12 intent scenarios
were only exercised hermetically with a stubbed tmux endpoint. This round adds a
committed live guard and drives the intent-critical paths against the real
product on a real private-socket tmux server.

## Committed live guard

`tests/fm-deliberate-stop-live-e2e.test.sh` (real tmux, default-on gate). Ran 4x,
stable. Output: `live-deliberate-stop-e2e.log`. All seven scenarios pass:

1. A verified `fm-control.sh exit` against a real tmux pane records
   `state/<id>.deliberate-stop`; an absent/unprovable tmux endpoint refuses and
   records none.
2. The real `fm-watch.sh` absorbs a freshly deliberately-stopped finished idle
   pane (no wake, no wedge timer) and re-surfaces it past `FM_PAUSE_RESURFACE_SECS`
   as a bounded `deliberately stopped ... not a wedge` recheck.
3. The watcher parks a deliberately-stopped pane whose pane still reads busy past
   the busy-turn bound, and still re-surfaces it on the pause cadence — never a
   wedge.
4. The watcher keeps the bounded deliberate-stop recheck for an idle pane whose
   display churns a new hash every poll, instead of rotting invisibly.
5. Adversarial: removing the marker returns the same finished idle pane to the
   ordinary terminal-stale path, proving the marker is what parks it.
6. Real `fm-teardown.sh --force` (real tmux close, real git worktree; external
   worktree pool + forge stubbed) retires the marker for the task.
7. Real `fm-control.sh relaunch` launches a real `pi` replacement in the same
   endpoint/worktree and clears the marker; a relaunch whose replacement launch
   is refused (malformed brief) keeps the parked stop.

## Hermetic (unchanged) suites, re-run green

- `tests/.tmp-fm-control-targeted.test.sh`: verified stop records marker; refusal
  records none.
- `tests/.tmp-fm-control-relaunch-targeted.test.sh`: relaunch clears the marker;
  a failed post-launch backlog commit still clears it; an aborted wiring failure
  retains the parked stop.
- `tests/.tmp-fm-teardown-targeted.test.sh`: teardown clears the marker.
- `tests/.tmp-fm-daemon-targeted.test.sh`: away-mode classify parks the task, the
  bounded pause cadence re-surfaces it, and the first recheck is anchored on the
  stop epoch.
- `tests/.tmp-watch-targeted.test.sh`: all five deliberate-stop watcher behaviors
  plus the terminal-stale and wedge-escalation baselines.

## Not driven live this round (with reason)

- **Away-mode daemon recheck as a process**: the daemon's own loop starts and
  supervises the watcher child and injects into a supervisor pane; the same
  classify/housekeeping/recheck functions were driven in-process (hermetic) but no
  standalone daemon process was stood up.
- **Genuine wedge escalation for a never-stopped worker**: requires a crew verdict
  that is provably-working (a real worktree being written); the marker-less
  terminal-stale adversarial scenario is driven live instead, which proves the
  marker is load-bearing.
