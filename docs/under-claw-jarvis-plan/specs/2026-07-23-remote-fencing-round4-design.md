# Remote fencing and worker reconciliation design (2026-07-23)

## 1. 요구 & 성공기준

- Worker polls only after a fast-forward reconciliation and publishes canonical
  dispositions/results through an injected sync boundary. [verify: two-clone
  bare-remote test]
- A remote claim is authoritative only while its exact remote ref OID is
  current. Wall-clock expiry is advisory and cannot authorize takeover.
  [verify: stale lease cannot pass a write guard after explicit CAS takeover]
- Pipeline result writes and final Run/Task completion each recheck the fence.
  [verify: short-run takeover race test]
- A crash after an orchestration completion event is reconciled idempotently.
  [verify: repeated recovery produces the same terminal state]
- Hermes remains experimental until it has trusted reviewer attestation.
  [verify: default installer and discovery do not connect Hermes]

Brownfield comparison: remote Git CAS already exists, but expiry uses local
wall clocks, the worker does not sync canonical state, and pipeline writes have
no fence. These are corrected without changing the canonical storage layout.

## 2. 채택 접근법 & 근거

Use the remote claim ref OID as a monotonic fencing token. Renewal and explicit
takeover create a commit whose parent is the previous token and replace the ref
with `--force-with-lease`. Ordinary acquisition never steals an existing ref,
regardless of a client clock. This is simpler and safer than pretending Git
provides trusted server time.

Rejected: expiry-based automatic takeover. It cannot distinguish clock skew
from a dead owner and permits two workers to believe they own the task.

## 3. 변경 범위 & 파일

- `git_remote_claim_service.dart`: lineage token, `isCurrent`, explicit takeover.
- `skill_pipeline.dart`: asynchronous write guard before every canonical batch.
- `execution_worker.dart`: sync boundary, fence checks, terminal reconciliation.
- host discovery/install/readmes: Hermes opt-in experimental status.
- task schema/codec: versioned execution-scope migration.
- focused tests for stale writers, reconciliation, and host behavior.

Unrelated Flutter screens, authentication selection, signing, and release
publishing are not modified in this round.

## 4. 프로젝트 간 계약 영향

`RemoteClaimProvider` gains `isCurrent`. `SkillPipeline` accepts an optional
asynchronous `beforeCanonicalWrite` callback. Worker sync is an injected
interface so tests use temporary repositories and production code never
implicitly commits the implementation checkout.

## 5. 리스크 & 미해결 가정

- A crashed owner leaves a ref requiring an explicit takeover decision. This is
  deliberate fail-closed behavior until a trusted lease-time authority exists.
- Git worktree publishing can fail on divergence; the worker must stop rather
  than merge automatically.
- Trusted no-follow artifact verification is not portable in pure Dart.
  Process execution therefore requires an external verifier and Hermes remains
  disabled by default.

## 6. 검증 방법

Run format, analyze, all Flutter tests, CLI and macOS builds, local bare-remote
tests, packaging smoke, secret scan, and `git diff --check`.

## 7. task 분할

1. Implement remote OID lineage and fence checks.
2. Guard pipeline writes and final worker completion.
3. Add canonical sync/reconciliation boundary and crash recovery.
4. Make Hermes opt-in experimental and update claims.
5. Version execution-scope schema migration.
6. Add race/restart/two-clone tests and run the full verification matrix.
