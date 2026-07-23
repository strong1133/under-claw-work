# ADR 0001: single Worklog orchestration skill

Status: accepted

The product originally called three independent skills directly. The newer
requirement introduces `under-claw-work-plan` as the only Task execution
entrypoint. It owns the approval/reviewer/persistence contract and invokes the
three existing skills in the required order.

Core therefore asks RunnerAdapter to invoke only `under-claw-work-plan`, then
validates the returned nested trace: Meta precedes Plan Loop, every loop round
contains base Plan, and an independent reviewer reaches TARGET 9.5. The
installer owns a four-skill bundle and removes only manifest-owned copies.

This preserves each underlying skill's explicit activation gate while removing
duplicated orchestration logic from Flutter and Core.
