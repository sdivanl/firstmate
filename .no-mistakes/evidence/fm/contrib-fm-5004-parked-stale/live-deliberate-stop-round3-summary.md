# Deliberate-stop (#5004) live validation — round 3

Change under test: durable `state/<id>.deliberate-stop` marker written by
`bin/fm-control.sh exit`, read by the watcher and the away-mode daemon, cleared
by relaunch and teardown, so a deliberately parked finished task gets the
declared-pause treatment (long bounded recheck, never a stale/wedge escalation).

Everything below was driven against the real product in this run. Worktree at
`9e83c8209b1ce1347ce7d0c82b2aab1f679cd3eb`.

## Committed live guard (real control plane + real watcher + real tmux + real pi)

`tests/fm-deliberate-stop-live-e2e.test.sh` — ran 3x, stable, exit 0.

| # | Scenario | Result |
|---|----------|--------|
| 1 | Verified `fm-control exit` records the marker; absent/unprovable endpoint refuses and records none | pass |
| 2 | Watcher absorbs a fresh idle deliberate stop and re-surfaces it past the cadence, never a wedge | pass |
| 3 | Watcher parks a deliberately stopped pane whose pane still reads busy past the busy-turn bound | pass |
| 4 | A churning idle pane still gets the bounded deliberate-stop recheck | pass |
| 5 | Adversarial: removing the marker returns the finished pane to ordinary terminal-stale | pass |
| 6 | Teardown retires the marker for a real task (real tmux + real git worktree) | pass |
| 7 | Relaunch clears the marker (real `pi` replacement); an aborted relaunch retains the parked stop | pass |

Logs: `live-deliberate-stop-e2e.log`, `live-e2e-rerun-1.log`,
`live-e2e-rerun-2.log`, `live-e2e-rerun-3.log`.

## Supplemental real-tmux away-mode-daemon driver

The repo's own `tests/fm-daemon.test.sh` covers the daemon only over a shimmed
tmux. `live-daemon-deliberate-stop-driver.sh` sources the real
`bin/fm-supervise-daemon.sh` functions and runs `classify_stale` / `handle_wake`
/ `housekeeping` against a real tmux server on a private socket (no fake, no
stub). Ran 2x, stable, exit 0.

| # | Scenario | Result |
|---|----------|--------|
| 8 | `classify_stale` parks a deliberately stopped task (pause, not wedge) | pass |
| 9 | `handle_wake` anchors the pause marker on the stop mtime; the very next `housekeeping` tick re-surfaces it (no doubled window) | pass |
| 10 | Adversarial: a pre-aged wedge marker + deliberate marker is dropped with no escalation | pass |
| 11 | Adversarial: the same pre-aged wedge marker with NO deliberate marker still escalates as `possible wedge` | pass |

Method note: scenarios 8–11 execute the real daemon code paths and real tmux
backend, but in library mode (the long-running daemon process was not stood
up). Logs: `live-daemon-deliberate-stop.log`,
`live-daemon-deliberate-stop-rerun.log`.

## Targeted hermetic suites re-run (user-requested)

- `tests/fm-control.test.sh` — pass (includes verified-stop-records /
  refused-records-none).
- `tests/fm-control-relaunch.test.sh` — pass (clear on delivered relaunch, clear
  even when the backlog commit fails, retain on aborted wiring).
- `tests/fm-daemon.test.sh` — pass (park, re-surface cadence, stop-epoch anchor).
- `tests/fm-watch-triage.test.sh` — the five deliberate-stop cases (parked,
  re-stop first-sight absorb, marker-cleared resume, busy-pane, churning-pane)
  all pass; the suite itself is ~25+ min and was stopped after the relevant
  cases plus ~80 total cases passed (no failures).
- `tests/fm-teardown.test.sh` — the deliberate-stop teardown case passes. The
  suite aborts on `test_leaked_worktree_process_is_reaped`, which fails here on
  BOTH the base commit and the target commit (verified from a base-commit
  archive): process reaping is not supported in this sandbox, unrelated to this
  change.

Evidence: `hermetic-fm-control.log`, `hermetic-fm-control-relaunch.log`,
`hermetic-fm-daemon.log`, `hermetic-fm-watch-triage.log`,
`hermetic-fm-teardown.log`.
