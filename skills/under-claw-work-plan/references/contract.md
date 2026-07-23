# Execution contract

## Input

`task_id`, Draft content and revision, linked context IDs, approved Meta
revision when present, runner/environment identity, derivation policy, and
idempotent operation/run IDs.

## States

```text
draft_loaded
  -> meta_generated
  -> approval_pending | approved
  -> loop_running
  -> review_pending
  -> completed | blocked | failed | cancelled
```

`approval_pending` cannot transition to `loop_running`. Meta becomes stale when
the Draft revision changes. Completion requires a reviewer score `>= 9.5`.

## Required trace

```text
under-claw-work-plan
  under-claw-meta-prompt
  approval
  under-claw-jarvis-plan-loop
    round 1: under-claw-jarvis-plan
    round N: under-claw-jarvis-plan
  independent-reviewer (TARGET >= 9.5)
  knowledge/event/follow-up persistence
```

Every entry includes immutable invocation ID, bundle version/checksum, input
revision, runner/environment, timestamps, result reference, and parent
invocation ID. Missing order, a loop round without the base plan, or missing
independent review blocks completion.

On Hermes, load each nested skill with `skill_view` and record the completed
host result with:

```text
worklog invocation-record <workspace> <run-id> <skill-id> <round> <sequence> <status>
```

The command writes canonical data before rebuilding SQLite. A skill name in
assistant prose, a Hermes bundle load, or stdout without that canonical record
is not execution evidence.

## Output

Return final state, ordered trace, reviewer score/evidence, result refs, created
Knowledge/Event IDs, and follow-up Task IDs. Do not include passwords, verifier
material, provider tokens, or secure-store values.
