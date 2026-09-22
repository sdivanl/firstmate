# Finding: nested projected teardown quarantines its presentation journal

## Symptom
`tests/fm-backend-herdr-presentation-e2e.test.sh` (required `real-herdr-gated`
CI family) fails at:

```
not ok - confirmed projected teardown did not retire its presentation journal
```

after `pass - durable nested checkout allocation preserves the task metadata
contract`. Teardown stderr shows:

```
warning: herdr presentation journal for shape remains quarantined; no workspace cleanup was attempted
```

so `HERDR_PRESENTATION_RETIRE_CANDIDATE` never became 1.

## Root cause (live reproduction)
For a same-project nested projection the task pane is created with
`herdr worktree open --path <checkout>`, so the pane's **top-level shell cwd is
the Treehouse checkout**. `fm-teardown.sh` computes
`fm_backend_herdr_projection_endpoint_matches_journal` (which matches the
workspace label suffix ` · p:<token>`) only *after*
`reap_task_worktree_processes`, which kills every process whose cwd is under the
worktree. That reaper therefore kills the pane's own shell; Herdr removes the
nested workspace; the later binding finds no matching workspace and the journal
is quarantined. Flat tasks are unaffected because their top-level shell stays in
the project directory while only the `treehouse get` subshell lives in the
worktree.

Minimal live repro `repro-nested-teardown.sh` proves the sequence:
1. same-project nested spawn: `worktree list` shows the checkout as an open
   linked child of the home workspace;
2. a direct call to `fm_backend_herdr_projection_endpoint_matches_journal`
   **before** teardown returns 0 (`repro/binding-probe.txt`);
3. the `workspace list` captured during teardown no longer contains the task
   workspace (last lines of `repro/workspace-list-calls.jsonl`) because the
   reaper killed the pane shell immediately before;
4. teardown exits 0 but leaves `shape.herdr-presentation` in place
   (`JOURNAL_STILL_PRESENT`, `repro/teardown.err`).

The pre-return binding that the change added is still too late: the workspace
disappears during the earlier leak reaping.

## Impact
The documented invariant (`docs/herdr-backend.md`: exact teardown retires the
journal once the exact pane is confirmed gone) does not hold for nested
projections, and the change's own required live E2E fails. The quarantined
journal makes a later spawn of the same task see a stale presentation binding.

## Suggested remedy (product code, outside test scope)
Compute the read-only journal/endpoint binding before
`reap_task_worktree_processes` (or preserve its verdict across the reap), so the
post-close confirmation can still retire the journal when the nested workspace
has already vanished with its pane shell.
