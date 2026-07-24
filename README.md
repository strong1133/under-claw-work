# Under Claw Work

[English](README.en.md)

## 설치 · 초기화 · 첫 사용

아래 명령은 macOS·Linux용 unsigned MVP artifact를 압축 해제한 디렉터리에서 실행한다.
Claude Code와 Codex 중 이미 설치된 host만 자동 탐지해 연결하며 Agent 자체는
설치하거나 변경하지 않는다. Hermes는 검증된 reviewer attestation 경계가 준비될
때까지 기본 비활성화된 실험 기능이다.

```bash
# 1. Under Claw Work runtime과 4-skill bundle 설치
./packaging/install.sh

# 2-A. 기존 로컬 Git 저장소를 작업 저장소로 초기화
~/.local/share/under-claw-work/bin/worklog initialize \
  /절대경로/내-work-repository \
  "내 MacBook"

# 2-B. Private 원격 저장소를 새 디렉터리에 clone해 초기화
~/.local/share/under-claw-work/bin/worklog initialize \
  /절대경로/새-work-repository \
  "원격 Linux" \
  ssh://git@github.com/OWNER/REPOSITORY.git

# 3. 연결된 Agent host 확인
~/.local/share/under-claw-work/bin/worklog host-list

# 4. Task 확인
~/.local/share/under-claw-work/bin/worklog task-list \
  /절대경로/내-work-repository
```

Private 저장소 인증은 운영체제의 Git credential helper 또는 SSH Agent를 사용한다.
토큰이나 패스워드를 URL·명령 인자·설정파일에 넣지 않는다.

특정 host만 명시적으로 연결해야 하는 격리 설치에서는 다음처럼 지정할 수 있다.

```bash
UNDER_CLAW_HOSTS=codex ./packaging/install.sh
```

제거:

```bash
./packaging/uninstall.sh --mode app
./packaging/uninstall.sh --mode runtime
./packaging/uninstall.sh --mode full --workspace /absolute/clone \
  --confirm-full /absolute/clone
```

`app`은 launcher/command만, `runtime`은 소유한 runtime·skill까지 제거한다.
`full`은 정확한 절대경로 확인을 요구하며 Under Claw Work가 직접 clone한 작업공간만
삭제한다. 직접 연결한 기존 저장소의 정본과 Hermes, Claude Code, Codex 자체는 보존한다.

## 무엇인가

Under Claw Work는 Agent가 아니라 **Agent 중립 작업환경 및 스킬 모음**이다.

```text
                         사용자가 지정한 Git 저장소
                        YAML·Markdown 영구 정본
                                  │
                         Under Claw Work Core
                    SQLite projection · CLI · Flutter
                                  │
             ┌────────────────────┼────────────────────┐
             │                    │                    │
      기존 Hermes Agent    기존 Claude Code       기존 Codex
             └────────────────────┼────────────────────┘
                         under-claw-work-plan
```

- Hermes는 자동 연결하지 않는다. 실험용 skill 설치는
  `UNDER_CLAW_EXPERIMENTAL_HERMES=1`로만 활성화하며 Task runner는 acceptance
  통과 전 fail-closed 한다.
- Hermes가 없어도 Claude Code 또는 Codex가 있으면 해당 Agent로 Task를 처리한다.
- 여러 Agent가 있으면 Task의 실행 환경 정책에 따라 선택한다.
- Agent가 하나도 없어도 Flutter와 CLI에서 업무 DB를 관리할 수 있다. AI Task
  실행만 `unavailable` 상태가 된다.

## 초기화가 수행하는 작업

`worklog initialize`는 다음을 수행한다.

1. 사용자가 지정한 로컬 Git 경로를 초기화하거나 Private 원격 저장소를 clone한다.
2. 환경 고유 ID를 발급한다.
3. 로컬 SQLite projection을 별도 설치·설정 없이 생성한다.
4. Hermes·Claude Code·Codex 연결 상태를 표시한다.
5. Task, Prompt, Knowledge와 실행 기록은 Git 정본을 사용하고 SQLite는 언제든
   재생성 가능한 인덱스로만 사용한다.

`install.sh`는 host를 다음 경로로 연결한다.

| Host | 탐지 기준 | 설치 대상 |
|---|---|---|
| Hermes (실험) | 명시적 opt-in + `hermes` 또는 `${HERMES_HOME:-~/.hermes}` | `skills/` |
| Claude Code | `claude` 명령 또는 `${CLAUDE_HOME:-~/.claude}` | `skills/`, `commands/` |
| Codex | `codex` 명령 또는 `${CODEX_HOME:-~/.codex}` | `skills/` |

기존 동명 파일이 Under Claw Work 소유가 아니면 덮어쓰지 않고 설치를 중단한다.

## Task 실행 스킬

모든 Agent host는 `under-claw-work-plan`을 단일 진입점으로 사용한다.

```text
under-claw-work-plan
→ under-claw-meta-prompt
→ Meta Prompt 승인
→ under-claw-jarvis-plan-loop
→ 각 회차 under-claw-jarvis-plan
→ 독립 검수
→ Knowledge · Event · Audit 기록
```

설치 bundle은 다음 네 스킬을 포함한다.

- `under-claw-work-plan`
- `under-claw-meta-prompt`
- `under-claw-jarvis-plan-loop`
- `under-claw-jarvis-plan`

## Flutter 앱

개발 환경에서 실행:

```bash
flutter pub get
flutter run -d macos
```

현재 Flutter 원본은 macOS, Windows와 Linux runner를 포함한다. GitHub Actions는
세 운영체제의 unsigned MVP artifact를 생성한다. 배포용 코드 서명과 notarization은
저장소 외부의 플랫폼 인증서가 필요하다.

## 주요 명령

```text
worklog initialize <path> <environment-name> [remote]
worklog host-list
worklog task-list <workspace>
worklog entity-list <workspace> [kind]
worklog entity-create <workspace> <kind> <title> [domain] [milestone]
worklog entity-update <workspace> <kind> <id> <title>
worklog entity-archive <workspace> <kind> <id>
worklog entity-link <workspace> <kind> <id> <field> <target-kind> <target-id>
worklog graph-validate <workspace>
worklog knowledge-search <workspace> <query>
worklog context-build <workspace> <task>
worklog task-create <workspace> <domain> <milestone> <title> <environment>
worklog task-policy <workspace> <task> <derive> <followup> <depth>
worklog task-candidate-list <workspace>
worklog task-candidate-dispose <workspace> <candidate> <accept|reject>
worklog task-prompt <workspace> <task> <draft|meta|approve> [content-file]
worklog task-control <workspace> <task> <start|pause|resume|cancel|complete>
worklog migrate-dry-run <workspace> <legacy-path>
worklog migrate-import <workspace> <legacy-path> <domain> <milestone> <environment> --approve
worklog migrate-rollback <workspace> <import-id>
worklog git-status <workspace>
worklog git-pull <workspace>
worklog git-sync <workspace> [commit-message]
worklog runtime-register <workspace> <descriptor-json>
worklog runtime-list <workspace>
worklog meta-generate <workspace> <task-id> <adapter-id>
worklog worker-next-agent <workspace> <environment-id> <adapter-id>
worklog doctor <workspace>
```

`git-sync`는 graph/schema와 민감정보 검사를 통과한 Git 정본만 configured
upstream으로 publish하며, 충돌 시 원격을 덮어쓰지 않는다. Runtime descriptor는
`.worklog/`에만 저장되고 executable·독립 reviewer checksum을 매 실행 검증한다.
배포 archive에는 production descriptor가 내장되지 않으므로 acceptance를 통과한
generic/host adapter를 `runtime-register`로 등록하기 전 Meta/worker 실행은
fail-closed 한다.

CI의 OS별 unsigned archive는 GUI, precompiled CLI, pinned skill bundle과
installer/updater를 한 파일에 포함한다. archive 내부 checksum은 손상 검출용이며
publisher identity나 코드 서명을 대신하지 않는다.

## 보안 경계

- 실제 패스워드, verifier, token과 credential은 Git·artifact·로그에 저장하지 않는다.
- 공유 repository password provider는 검증된 표준 provider 선정 전까지
  `pending_selection` 상태다.
- 현재 MVP의 Private Git 접근은 Git credential helper 또는 SSH Agent를 사용한다.
- 자체 암호 프로토콜은 구현하지 않는다.
- `.worklog/projection.sqlite3`은 Git에 포함하지 않는다.

## 저장소 구조

```text
lib/core/              공용 Core와 SQLite projection
lib/main.dart          Flutter 데스크톱 앱
bin/worklog.dart       headless CLI
workdb/schemas/        정본 데이터 계약
skills/                under-claw-work-plan과 bundle lock
packaging/             설치·제거와 ownership manifest
docs/                  아키텍처와 보안 경계
```

## 개발 검증

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter build macos
./tool/secret_scan.sh
```
