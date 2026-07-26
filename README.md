# Under Claw Work

[English](README.en.md)

## 설치 · 초기화 · 첫 사용

아래 명령은 macOS·Linux용 unsigned MVP artifact를 압축 해제한 디렉터리에서 실행한다.
Hermes, Claude Code, Codex 중 이미 설치된 host를 자동 탐지해 스킬을 연결하며
Agent 자체나 모델, 전역 페르소나는 설치하거나 변경하지 않는다. 스킬 사용과 자동
Task runner 지원은 별도 경계다. Hermes에서도 스킬은 사용할 수 있지만 자동 runner는
adapter acceptance를 통과하기 전까지 fail-closed다.

```bash
# 1. Under Claw Work runtime과 5-skill bundle 설치
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
UNDER_CLAW_HOSTS=hermes,codex ./packaging/install.sh
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

Under Claw Work는 Agent를 대체하지 않는 **Agent 중립 작업환경·도구·스킬
모음**이다. Hermes, Claude Code, Codex가 각자의 모델과 도구를 유지한 채 Task
제어, Meta Prompt 승인, 실행 감사, 영구 기억을 사용한다.

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

- Hermes에는 검증된 스킬 bundle을 일반 host와 동일하게 연결한다. 단, Task runner는
  acceptance 통과 전 fail-closed 한다.
- 어느 한 host만 있어도 해당 Agent가 스킬과 관리 도구를 사용할 수 있다.
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
| Hermes | `hermes` 명령 또는 `${HERMES_HOME:-~/.hermes}` | `skills/` |
| Claude Code | `claude` 명령 또는 `${CLAUDE_HOME:-~/.claude}` | `skills/`, `commands/` |
| Codex | `codex` 명령 또는 `${CODEX_HOME:-~/.codex}` | `skills/` |

기존 동명 파일이 Under Claw Work 소유가 아니면 덮어쓰지 않고 설치를 중단한다.

### 기억 저장소는 사용자 소유다

설치 시 사용자가 자신의 기억DB 저장소 경로를 지정하고, Under Claw Work는 그
경로만 사용한다. 이후 Domain·Milestone·Persona·Skill Policy·host binding을 어떻게
구성할지는 **사용자가 자발적으로 정하는 영역**이다. 도구도 Agent도 요청받지 않은
저장소 구조 변경, Domain 임의 생성, 기록 이관을 수행하지 않는다.

## Meta Prompt 작성 루프

검증된 `generate_meta` runtime adapter가 없는 workstation host(Claude Code,
Codex 등)에서 쓰는 실무 경로다. 추론은 host Agent가 하고, Under Claw Work는 큐와
정본 기록을 제공한다.

```bash
# 1. Draft를 메타 작성 대기로 표시
worklog task-prompt <workspace> <task-id> request-meta

# 2. 대기 큐 조회 — task-id, 상태, Draft revision, 정본 경로, 제목
worklog task-pending-meta <workspace>

# 3. 큐가 알려준 정본 경로에서 Draft를 읽는다
# 4. under-claw-meta-prompt를 명시적으로 호출해 결과를 파일로 저장한다

# 5. host 호출 ID와 pinned bundle checksum으로 evidence v1 생성
worklog task-meta-evidence <workspace> <task-id> <meta-file> \
  <bundle-version> <bundle-sha256> <host-invocation-id> \
  <host-id> <runner-id> <started-at> <finished-at> > evidence.json

# 6. host 실행 증거와 함께 같은 Draft revision의 결과를 기록
worklog task-meta-record <workspace> <task-id> <meta-file> <evidence-json>

# 7. 검토 후 승인
worklog task-prompt <workspace> <task-id> approve
```

5단계 이후 Draft를 편집하면 Task가 `writing`으로 돌아가고 승인이 stale이 되므로
4단계를 다시 수행해야 한다. 검증된 adapter가 있는 원격 Hermes host는 같은 루프를
`auto-meta-next`가 대신한다.

## 전달 파일 첨부

Domain·Milestone·Task가 참고할 전달 파일은 Reference 정본 데이터로 편입한다.
파일 본문이 Reference 엔티티의 Markdown body가 되므로, 원격 agent host를 포함한
어느 clone에서도 같은 내용을 읽는다. 로컬 절대경로는 정본에 들어가지 않는다.

```bash
worklog reference-attach <workspace> "<제목>" <파일> [domain] [milestone] [task]
```

UTF-8 텍스트만 받고 상한은 256 KiB다. 더 큰 자료는 별도 저장소에 두고 Repository
엔티티로 참조한다.

## Task 실행 스킬

설명과 명령 선택은 `under-claw-work`, 실제 governed Task 실행은
`under-claw-work-plan`을 진입점으로 사용한다.

```text
under-claw-work-plan
→ under-claw-meta-prompt
→ Meta Prompt 승인
→ under-claw-jarvis-plan-loop
→ 각 회차 under-claw-jarvis-plan
→ 독립 검수
→ Knowledge · Event · Audit 기록
```

설치 bundle은 다음 다섯 스킬을 포함한다.

- `under-claw-work`
- `under-claw-work-plan`
- `under-claw-meta-prompt`
- `under-claw-jarvis-plan-loop`
- `under-claw-jarvis-plan`

마지막 세 스킬은
[`strong1133/under-claw-jarvis-plan`](https://github.com/strong1133/under-claw-jarvis-plan)의
고정 revision과 checksum으로 패키징한다. Host별 프로젝트 지침과 opt-in 페르소나
템플릿은 [`personas/`](personas/)에 있다. Installer는 기존 `AGENTS.md`,
`CLAUDE.md`, `SOUL.md`를 덮어쓰지 않는다.

## 관리·조회 표면

같은 정본을 세 갈래로 본다. **정본을 바꾸는 것은 CLI와 데스크톱 앱뿐**이다. 상태
전이와 Meta 승인은 evidence 게이트를 통과해야 하므로 읽기 표면에 열지 않는다.

| 표면 | 용도 | 쓰기 |
|---|---|---|
| 데스크톱 앱 (Flutter) | Task 생성·편집, Meta 요청·승인, 실행 제어 | O |
| `worklog` CLI | 위 전부 + 자동화·배치 | O |
| Obsidian 파생 vault | 프롬프트 읽기, 그래프·백링크 탐색 | X |
| 로컬 브라우저 뷰 | 목록·검색·프롬프트 열람 | X |

### Obsidian 파생 vault

정본 Draft·Meta는 `task.yaml` 안에 있어 Obsidian이 직접 열지 못한다. 정본을
분해하는 대신 읽기 전용 vault로 투영한다.

```bash
worklog obsidian-export <workspace>          # 기본 .worklog/obsidian/
worklog obsidian-export <workspace> <vault>  # 위치 지정
```

노트 파일명이 정본 ID이므로 `[[TSK-...]]` 링크, 그래프 뷰, 백링크가 정본 관계를
그대로 따른다. 단방향이다 — vault에서 고친 내용은 정본으로 돌아가지 않고 다음
export에서 덮어써진다. 기본 출력 위치는 `.worklog/` 아래라 커밋되지 않는다. 이미
내용이 있으면서 이 도구가 만들지 않은 디렉터리로는 export를 거부한다.

### 로컬 브라우저 뷰

```bash
worklog serve <workspace> [port]
```

기동할 때마다 1회용 토큰을 발급해 URL과 함께 출력한다. 보안 경계는 다음과 같다.

- loopback 인터페이스에만 바인딩한다. 다른 인터페이스로 여는 옵션이 없다.
- 모든 요청이 토큰을 제시해야 한다. 토큰은 Git·정본·로그에 남기지 않는다.
- `Host` 헤더가 loopback이 아니면 거부한다(DNS rebinding 차단).
- CORS 헤더를 보내지 않아 다른 origin이 응답을 읽지 못한다.
- 쓰기 엔드포인트가 없다. `GET` 외 모든 메서드를 거부한다.

이 토큰은 전송 계층의 세션 토큰이며 저장소 password가 아니다. 저장소 인증은
검증된 provider가 선정될 때까지 잠겨 있다.

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
worklog task-create <workspace> <title> [--domain <domain>] \
  [--milestone <milestone>] [--environment <environment>]
worklog task-policy <workspace> <task> <derive> <followup> <depth>
worklog task-candidate-list <workspace>
worklog task-candidate-dispose <workspace> <candidate> <accept|reject>
worklog task-prompt <workspace> <task> <draft|request-meta|approve> [content-file]
worklog task-meta-evidence <workspace> <task> <meta-file> <bundle-version> <bundle-sha256> <host-invocation-id> <host-id> <runner-id> <started-at> <finished-at> [environment]
worklog task-meta-record <workspace> <task> <meta-file> <evidence-json>
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
worklog auto-meta-next <workspace> <environment-id> <adapter-id>
worklog notification-register <workspace> <local-config-json>
worklog notification-list <workspace>
worklog worker-next-agent <workspace> <environment-id> <adapter-id>
worklog update-check|update-apply <extracted-release-directory>
worklog update-rollback
worklog obsidian-export <workspace> [vault-directory]
worklog serve <workspace> [port]
worklog doctor <workspace>
```

`git-sync`는 graph/schema와 민감정보 검사를 통과한 Git 정본만 configured
upstream으로 publish하며, 충돌 시 원격을 덮어쓰지 않는다. Runtime descriptor는
`.worklog/`에만 저장되고 executable·독립 reviewer checksum을 매 실행 검증한다.
배포 archive에는 production descriptor가 내장되지 않으므로 acceptance를 통과한
generic/host adapter를 `runtime-register`로 등록하기 전 Meta/worker 실행은
fail-closed 한다.

`auto-meta-next`는 Draft가 있고 Meta가 비어 있거나 `missing`/`stale`인 Task만
Git remote claim으로 선점한 뒤 `$under-claw-meta-prompt`를 명시 호출한다. 생성된
Meta는 `pending`으로 저장하며 자동 승인·실행하지 않는다. 정본 push 성공 후에만
로컬 FCM/Hermes webhook 알림을 전송하고 실패는 outbox에서 재시도한다. 자세한
운영 계약은 [`docs/auto-meta-notifications-update.md`](docs/auto-meta-notifications-update.md)에
있다.

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
- `worklog serve`는 loopback에만 바인딩하고 1회용 토큰을 요구하며 쓰기 경로가 없다.

## 기억 저장소 구조

사용자가 지정한 기억 저장소는 초기화 시 표준 트리로 규격화된다. Git이 빈
디렉터리를 추적하지 않으므로 각 정본 디렉터리에 placeholder를 씨딩하고,
`workdb/workspace.yaml`에 레이아웃 버전과 디렉터리 목록을 남긴다. 그래서 다른
기기에서 clone해도 같은 트리가 그대로 재현된다.

```text
<기억 저장소 루트>/
├─ workdb/          정본. Git이 추적한다.
│  ├─ workspace.yaml            레이아웃 매니페스트
│  ├─ tasks/ domains/ milestones/ objectives/ projects/ ...
│  ├─ knowledge/ references/ matches/
│  ├─ events/ runs/ claims/ invocations/ control-requests/ ...
│  └─ config/                   environments.yaml, agents.yaml 등
└─ .worklog/        호스트 로컬. Git이 추적하지 않는다.
   ├─ projection.sqlite3        재생성 가능한 SQLite projection
   └─ obsidian/                 파생 Obsidian vault
```

```bash
worklog doctor <workspace>   # workspace=ok | unversioned | version_mismatch
                             # | incomplete | not_portable
worklog init <workspace>     # 진단에서 나온 격차를 복구한다
```

`doctor`는 진단만 하고 고치지 않는다. 사용자가 자기 저장소 상태를 먼저 보고
복구를 결정하도록 하기 위해서다. 전체 명세는
[`docs/최종계획/12-memory-repository-layout.md`](docs/최종계획/12-memory-repository-layout.md)에
있다. 도구가 보장하는 것은 레이아웃뿐이며 Domain·Task·Knowledge의 내용은 저장소
주인의 몫이다.

## 제품 저장소 구조

```text
lib/core/              공용 Core와 SQLite projection
lib/main.dart          Flutter 데스크톱 앱
bin/worklog.dart       headless CLI
workdb/schemas/        정본 데이터 계약
skills/                under-claw-work 안내·실행 스킬과 pinned bundle lock
personas/              Host별 프로젝트 지침·전역 persona opt-in 템플릿
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
