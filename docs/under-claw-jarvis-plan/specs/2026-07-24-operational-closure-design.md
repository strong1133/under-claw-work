# 운영 경로 완결 설계 doc (2026-07-24)

## 1. 요구 & 성공기준

추가 요구 1~5의 완료 상태를 보존하면서 `00-최종계획.md`의 내부 구현 범위 중
끊겨 있는 Git 정본 동기화, installed-agent runtime, 단일 unsigned artifact/update
경로를 실제 CLI/Flutter 사용자 흐름으로 연결한다.

| 최초 요구 | 현재 구현 | 교정 요구 | 판정 |
|---|---|---|---|
| 여러 환경의 Git 정본 동기화 | clone, pull, remote claim, push primitive | 일반 편집 publish GUI/CLI | ➕ 공용 Sync service |
| 승인 Meta와 세 스킬 실행 | pipeline/worker와 임의 executable CLI | 설치된 runtime bridge | ➕ verified descriptor |
| 개발도구 없는 단일 설치 | unsigned OS build와 source-tree installer | 단일 archive/update rollback | ➕ bundle 조립 |
| repository password | provider 선정 전 fail-closed | 임의 프로토콜 금지 | ⛔ 외부 gate 유지 |
| Hermes와 signed release | acceptance/signing 전 잠금 | 지원 완료 주장 금지 | ⛔ 외부 gate 유지 |

성공기준:

1. CLI와 Flutter가 동일한 `CanonicalSyncService`로 canonical 변경을 검증·secret
   scan·commit·fetch/rebase·push하며 충돌 시 원격을 덮지 않는다.
   `[verify: bare remote + two clone E2E, CLI/widget reachability]`
2. local verified runtime descriptor만 Meta JSON protocol과 worker runner로 선택되며,
   생성 Meta는 pending 상태로 저장되고 사용자 승인 전 실행할 수 없다.
   `[verify: fake accepted executable E2E, checksum/protocol rejection]`
3. OS별 GUI·CLI·skills·packaging을 checksum manifest가 포함된 단일 unsigned
   archive로 조립하고, update는 staging health 실패 시 이전 설치를 복구한다.
   `[verify: isolated temp install/update/corruption/rollback tests]`
4. 기존 158개 테스트, D2Coding provenance와 secret scan이 회귀하지 않는다.

## 2. 채택 접근법 & 근거

채택 구조는 `shared Core application service → CLI/Flutter adapters → packaged runtime`다.

- Sync 정책을 GUI/CLI shell command 조합으로 중복하지 않는다. 사전 staged 변경은
  거부하고 canonical worktree 변경만 service가 stage한다.
- fetch 후 upstream이 앞서면 rebase를 시도하되 Git conflict는 abort하고 원래
  상태로 복구한다. text merge 성공 후에도 graph/schema/projection 검증을 다시 한다.
- Codex/Claude CLI 문법을 추측하지 않는다. local-only descriptor가 executable,
  fixed args, protocol, checksum과 capability를 선언하고 conformance를 통과한 generic
  JSON adapter만 사용한다.
- unsigned artifact는 SHA-256 무결성과 원자적 rollback만 보장한다. publisher
  authenticity, repository password provider와 Hermes는 기존 외부 acceptance gate다.

버린 대안:

- UI와 CLI가 직접 `git pull/add/commit/push`를 조합: scan·conflict 정책 drift 때문에 제외.
- 임의 executable 인자를 worker에 계속 전달: 설치 runtime 신뢰 경계를 우회하므로 제외.
- runtime 설치 시 upstream skill clone: offline 단일 artifact와 재현성을 깨므로 bundle
  조립 시 pinned skill bytes를 포함한다.
- 자체 password, update signature 또는 Hermes invocation 프로토콜: 제품 불변조건 위반.

## 3. 변경 범위 & 파일

1. Sync Core: 신규 `lib/core/canonical_sync_service.dart`,
   `lib/core/canonical_secret_verifier.dart`, 기존 `git_sync_service.dart`,
   Core tests.
2. Runtime Core: 신규 local descriptor/registry/meta adapter service, existing process
   runner/worker composition, Core tests.
3. CLI/Flutter: `bin/worklog.dart`, `lib/main.dart`와 최소 sync/runtime UI tests.
4. Distribution: `packaging/` bundle/update scripts, release manifest, CI and shell smoke.
5. 문서: 본 설계와 최종계획 구현 상태.

변경하지 않는 영역: auth provider status, Hermes disabled boundary, Notion sync,
Environment/Agent/Match/Memory schema와 서비스, migration canonical data.

## 4. 프로젝트 간 계약 영향

단일 Dart/Flutter 프로젝트 내부 계약만 추가한다.

- `CanonicalSyncService.syncCanonical(message, verifier) -> CanonicalSyncReport`
- `InstalledRuntimeRegistry.resolve(adapterId, capability) -> RuntimeDescriptor`
- `MetaPromptService.generate(taskId, adapterId) -> WorkTask(pending meta)`
- `release-manifest.tsv`는 archive의 모든 managed 파일 경로와 SHA-256을
  결정적으로 기록하고 공용 verifier가 install/update 전에 검사한다.

CLI와 Flutter는 위 Core 계약만 호출하며 Git/Agent process를 직접 호출하지 않는다.

## 5. 리스크 & 미해결 가정

- Git rebase는 semantic correctness를 보장하지 않는다. rebase 뒤 graph/schema/projection
  검증 실패 시 abort·복구하고 push하지 않는다.
- production Codex/Claude adapter descriptor는 각 host acceptance가 필요하다. 이번
  범위는 fake/generic JSON conformance와 local registry 경계까지 완료한다.
- unsigned manifest는 공격자가 archive와 hash를 함께 바꾸는 것을 막지 못한다.
  production authenticity는 signed manifest 외부 gate로 유지한다.
- 실제 Git commit 실패 시 기존 index 보존은 sync service가 사전 staged state를
  거부하고 실패 시 index/worktree를 복구하는 방식으로 닫는다.

## 6. 검증 방법

1. Sync targeted tests와 bare remote/two clone E2E
2. Runtime fake executable Meta→pending→approve→worker pipeline E2E
3. CLI/widget reachability tests
4. isolated artifact install/update corruption/health rollback smoke
5. `dart format --output=none --set-exit-if-changed .`
6. `flutter analyze`
7. `flutter test`
8. `tool/font_provenance_check.sh`
9. `tool/secret_scan.sh`

## 7. task 분할

1. **Canonical Sync service**
   - 작업: PRODUCT_AUDITOR
   - 파일: Sync Core, verifier, tests
   - 검증: clean push, remote-ahead rebase, conflict abort/restore, scan block.
2. **Installed runtime bridge**
   - 작업: RUNTIME_AUDITOR
   - 파일: runtime descriptor/registry/meta service, worker composition, tests
   - 검증: descriptor checksum/protocol/capability와 fake agent E2E.
3. **CLI·Flutter 연결**
   - 작업: ORCHESTRATOR
   - 파일: CLI, main/UI, reachability tests
   - 검증: 공용 Core API만 호출하며 pending Meta/Sync 상태를 표시.
4. **Unsigned artifact와 updater**
   - 작업: PRODUCT_AUDITOR
   - 파일: packaging, release manifest, CI/smoke
   - 검증: single archive, checksum rejection, health failure rollback.
5. **독립 종합 검수**
   - 작업: 각 모듈 비작업 참여자
   - 검증: 스펙→품질 리뷰, 전체 format/analyze/test/font/secret.

## 8. 구현 결과 (2026-07-24)

- Canonical sync는 GUI와 CLI가 동일 Core transaction을 사용하며 persistent
  cross-process lock, configured upstream, 재검증, exact lease push와 push 전
  rollback boundary를 적용했다.
- Runtime registry와 Meta adapter는 local-only strict JSON, executable/reviewer
  checksum, capability, symlink 거부와 pending Meta revision 검사를 적용했다.
  검증된 production descriptor는 번들하지 않아 Codex/Claude/Hermes 실행은
  acceptance 전까지 fail-closed다.
- OS별 unsigned archive는 GUI·headless CLI·pinned skills·installer/updater를
  포함한다. install/update 모두 candidate health 후 swap하며 실패 시 install과
  host target을 복구한다.
- 독립 리뷰 결과 Sync/Runtime 연결과 Distribution 경계가 PASS했다.
- 최종 검증: format 80 files, analyze 0 issues, Flutter tests 173 PASS,
  headless CLI build PASS, D2Coding provenance PASS, secret scan PASS,
  최신 macOS archive build/extract/packaging smoke PASS.
- 외부 gate는 의도적으로 유지한다: reviewed auth provider, 실제 host별 runtime
  acceptance, Hermes adapter acceptance, signing/notarization과 live credential
  smoke는 이번 구현이 완료됐다고 주장하지 않는다.
