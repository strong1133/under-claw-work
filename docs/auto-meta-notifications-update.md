# Automatic Meta Prompt, Notifications, and Runtime Updates

## Eligibility and state

A Task is eligible for automatic Meta Prompt generation when all of these are
true:

- `prompt_draft` is non-empty;
- the Task is not `claimed`, `running`, `completed`, or `cancelled`; and
- `prompt_meta` is empty, `prompt_approval` is `missing`/`stale`, or the stored
  source SHA-256 is absent or differs from the exact current Draft bytes.

The existing `prompt_approval` state is authoritative, so no second ambiguous
prompt-state field is introduced. A generated Meta Prompt is saved as
`pending`; it is never automatically approved or executed.

`auto-meta-next` first fast-forwards the Git workspace, then claims the Task
through `refs/under-claw-work/claims/<task-id>`. The canonical branch and the
unchanged claim object are pushed in one atomic Git transaction with exact
force-with-lease expectations, so a stale holder cannot publish. It explicitly
invokes the verified runtime adapter for
`under-claw-meta-prompt`, saves the output, writes immutable Run,
SkillInvocation, and Event evidence, validates the canonical graph, commits,
and pushes. Notifications occur only after this transaction succeeds. The
claim is renewed before both publications. Adapter output is accepted only when
its Draft revision, Draft bytes, source revision, and source SHA-256 still
match both the post-start fenced Task snapshot and the repository Task after
adapter save. The final Git transaction fences the exact expected Task file in
both `HEAD` and the working tree immediately before the atomic push. Task writes,
generation, canonical sync, and rollback share a reentrant cross-process mutation
lock; compensation uses compare-and-swap and cannot overwrite a newer Task.
Claim-check and renewal exceptions remove attempt-local Meta and unpublished
audits before propagating. A mismatch preserves a newer local Draft, skips the
final publication, and suppresses stale notification delivery. Durable start
evidence includes the
verified adapter executable SHA-256; adapter exceptions produce a failed Run,
SkillInvocation, and Event containing only the exception type (not its possibly
secret message) and are published through the same atomic claim fence.

```bash
worklog auto-meta-next <workspace> <environment-id> <adapter-id>
```

The packaged Linux watcher polls both local and remote changes. One watcher on
Astro-Hermes can therefore process Drafts pushed by either the MacBook or
Astro-Hermes.

```bash
packaging/install-auto-meta-service.sh \
  /absolute/workspace ENV-... hermes-meta-prompt 15
```

## Verified Hermes adapter

The installed `worklog` binary doubles as a checksum-pinned adapter with fixed
arguments `hermes-meta-adapter`. It invokes:

```text
hermes chat -Q --source tool -s under-claw-meta-prompt ...
```

The request also contains the explicit `$under-claw-meta-prompt` activation
token. The adapter asks Hermes to return only the transformed prompt and never
to execute it or modify the clipboard.

Register a local descriptor using the installed `worklog` executable, fixed
argument `hermes-meta-adapter`, capability `generate_meta`, and the executable's
SHA-256. Runtime descriptors are local and fail closed if the executable hash
changes after an update; re-register after a verified update.

## Notification channels

Notification credentials and FCM registration tokens are local-only under
`.worklog/notification-channels.json` with mode `0600`. They are excluded from
Git. Register a prepared configuration file with:

```bash
worklog notification-register <workspace> /secure/channels.json
worklog notification-list <workspace>
```

Supported channels:

- `fcm`: Firebase Cloud Messaging HTTP v1. The access token is obtained from an
  absolute local command, and one message is sent per Environment registration.
- `hermes_webhook`: an HMAC-SHA256 signed Hermes webhook route configured with
  `--deliver-only --deliver discord`, avoiding an extra LLM call.

Delivery intent is durably queued under `.worklog/notification-outbox/` before
the first network attempt and retried on each watcher tick. Successful targets
are removed from a partially failed item, so normal retries address only failed
FCM registrations or webhook channels. Crash recovery is intentionally
at-least-once. The canonical Meta Prompt is not rolled back when a notification
provider is unavailable. Task ID, Draft revision, exact Draft SHA-256, and
adapter ID form the notification idempotency key.

Firebase project setup, service-account/Workload Identity configuration, and
client token acquisition remain deployment credentials. Never commit service
accounts, OAuth access tokens, FCM registration tokens, Discord bot tokens, or
webhook secrets.

## Runtime update and rollback

Extracted releases remain manifest-verified before mutation:

```bash
worklog update-check /absolute/extracted-release
worklog update-apply /absolute/extracted-release
worklog update-rollback
```

`update-apply` runs the installed transactional updater. It builds and health
checks a candidate, atomically swaps it into place, and retains the previous
installation at `<install-root>.previous`. `update-rollback` health-checks and
swaps that version back. Release manifests provide integrity, not publisher
authenticity; unsigned archive warnings still apply.
