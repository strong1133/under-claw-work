---
name: under-claw-work-plan
description: Explicit-only Worklog Task orchestrator. Use only when the user explicitly invokes `$under-claw-work-plan` or asks to run an Under Claw Work Task through Draft meta-prompting, approval, plan-loop execution, independent review, audit, and durable knowledge recording.
---

# Under Claw Work Plan

Read [references/contract.md](references/contract.md) before execution.

## Workflow

1. Load the Task Draft, revision, linked objective, knowledge, references, and
   execution policy.
2. Explicitly invoke `under-claw-meta-prompt`. Store the generated Meta Prompt
   with its source Draft revision.
3. Stop at the approval gate unless that exact Meta revision is approved by the
   user or an authorized repository policy.
4. Explicitly invoke `under-claw-jarvis-plan-loop` with the approved Meta
   Prompt. Require every loop round to explicitly invoke
   `under-claw-jarvis-plan`.
5. Require an independent reviewer verdict and TARGET score of at least 9.5.
   A lower score continues within policy limits or ends blocked; it never
   completes the Task.
6. Append invocation audit, reviewer verdict, learned Knowledge, Events, and
   policy-allowed follow-up Tasks. Never overwrite prior audit records.

Return a structured outcome with Task/Run IDs, final state, invocation trace,
review score, evidence references, and created Knowledge/Event/follow-up IDs.
