# 빌드·설치·업데이트

<!-- 최종 계획 문서 -->

이 문서는 release artifact와 CI 배포만 정의한다. 실제 setup, ownership, update와 uninstall 계약의 normative source는 [설치·초기 설정·제거](10-installation-and-removal.md), 인증 계약은 [로그인과 보안](06-security-auth.md)이다.

## 배포 목표

사용자는 개발도구를 설치하지 않고 운영체제용 설치파일 하나로 설치한다.

```text
macOS: .dmg 또는 signed .pkg
Windows: signed .exe 또는 .msi
Linux: AppImage 우선, 필요 시 .deb
Headless: 단일 worklog 바이너리
```

모든 artifact에는 Worklog Core, SQLite runtime, 세 under-claw skill bundle과 host adapter가 포함된다. 사용자는 Flutter, Go, Git, SQLite 또는 각 스킬을 따로 설치하지 않는다.

## 우선 지원 artifact

```text
WorklogStudio-macos-arm64.dmg
WorklogStudio-macos-x64.dmg
WorklogStudio-windows-x64.exe
WorklogStudio-linux-x64.AppImage
worklog-darwin-arm64
worklog-darwin-x64
worklog-windows-x64.exe
worklog-linux-x64
worklog-linux-arm64
checksums.txt
update-manifest.json
update-manifest.sig
skill-bundle-manifest.json
```

## 설치 후 자동 처리

설치 artifact는 [설치·초기 설정·제거](10-installation-and-removal.md)의 단일 setup 흐름을 실행한다. Git, SQLite, Go, Flutter, Node와 Python 설치를 요구하지 않는다.

## CI build matrix

```text
macos-14
├── arm64 GUI
└── x64 GUI/CLI

windows-2025
└── x64 GUI/CLI

ubuntu-24.04
├── x64 GUI/CLI
└── arm64 CLI
```

각 job:

1. 의존성 고정 및 복원
2. Core unit/integration test
3. Flutter test
4. schema fixture validation
5. secret leakage test
6. release build
7. 플랫폼 서명
8. smoke test
9. checksum 생성
10. artifact 업로드

실제 사용자 password는 빌드에 필요하지 않다. login 테스트는 일회성 fixture를 사용하고 workflow, artifact metadata와 로그에 fixture 값을 남기지 않는다.

## 재현성과 공급망

- Flutter와 Go 버전 고정
- lockfile commit
- GitHub Actions dependency를 commit SHA로 pin
- release source commit 기록
- SBOM 생성
- 가능한 경우 provenance attestation 생성
- artifact checksum과 서명 공개

## 자동 업데이트

GUI가 서명된 update manifest를 주기적으로 확인한다.

```text
새 버전 확인
→ manifest signature 검증
→ OS/architecture artifact 선택
→ checksum 검증
→ staging 설치
→ 앱 재시작
→ 실패 시 이전 버전 rollback
```

자동 업데이트는 사용자가 끌 수 있지만 보안 업데이트는 명확히 표시한다.

## 데이터와 앱 버전 분리

앱 업데이트가 정본 데이터 schema를 변경할 때:

1. schema migration 계획 생성
2. Git branch 또는 local backup 생성
3. migration dry-run
4. 검증
5. 정본 commit
6. 인덱스 재생성

SQLite migration 실패는 정본에 영향을 주지 않고 전체 재생성으로 복구한다.

## 오프라인 설치

설치파일만 전달받아 앱 설치와 로그인 화면 진입까지 가능해야 한다. GitHub 저장소의 최초 clone은 네트워크가 필요하다.

완전한 air-gapped 환경은 별도 bundle을 사용한다.

```text
signed installer
+ repository bundle
+ repository bundle checksum
```

## Smoke test

각 release에서 깨끗한 VM으로 검증한다.

1. 개발도구가 없는 상태에서 설치
2. 최초 repository password 설정
3. 올바르지 않은 로그인 거부
4. 다른 OS 설치에서 같은 Private 저장소 연결과 로그인 성공
5. Domain, Milestone, Objective, Knowledge, Reference, Task 생성·연결
6. Meta stale/approval 동작
7. 앱 재시작 후 데이터 유지
8. 다른 OS 클라이언트에서 동기화 확인
9. 로컬 SQLite 삭제 후 자동 복구
10. 민감정보 포함 변경의 push 차단
11. 세 스킬 pipeline invocation 순서
12. Task 시작·일시중지·재개·중단·완료 제어와 ACK
13. 제거 프로그램 동작과 install manifest 외 파일 보존

## 제거

제거 모드, ownership manifest, 원본 복원과 충돌 중단 규칙은 [설치·초기 설정·제거](10-installation-and-removal.md)만을 따른다.
