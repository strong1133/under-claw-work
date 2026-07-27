# under-claw-work

맥북의 AI 환경과 원격지 hermes agent에서 함께 쓰는 **업무지침 · 워크플로 명세 · 스킬 모음**.

## 이 레포에 없는 것

**데이터가 없다.** 프롬프트 초안, task, 도메인 내용은 전부 별도 데이터 저장소(PostgreSQL)에 있다.
**접속정보도 없다** — `~/.config/under-claw-work/db.env`에 둔다.

애플리케이션도 없다. 앱·서버·동기화 계층을 두지 않는다.

## 구축

```sh
./docker/setup.sh
```

Docker 기반 PostgreSQL을 띄우고, 계정을 만들고, 스키마 적용까지 한 번에 한다.
몇 번을 실행해도 안전하다 — 이미 있는 접속정보와 데이터는 건드리지 않는다.

전제 조건은 `docker`, `docker compose` v2, `openssl` 뿐이다. 호스트에 PostgreSQL을 설치하지 않는다.

```sh
set -a; . ~/.config/under-claw-work/db.env; set +a
docker exec -it -e PGPASSWORD="$POSTGRES_PASSWORD" under-claw-db \
  psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"
```

## 현재 범위

프롬프트 초안의 데이터화. 날짜별 Markdown에 `====`로 구분해 쌓던 방식을 관계형 구조로 대체한다.

| 문서 | 내용 |
|---|---|
| [`docs/01-data-model.md`](docs/01-data-model.md) | 데이터 모델 — 계층, 상태 축, 테이블별 목적, 필드 출처 |
| [`docs/02-database-setup.md`](docs/02-database-setup.md) | 구축 절차 — 접속정보 규약, 스키마 적용, 운영, id 규칙 |
| [`schema/001_init.sql`](schema/001_init.sql) | DDL — 테이블 13 · 열거형 4 · 뷰 1 |
| [`docker/compose.yaml`](docker/compose.yaml) | 컨테이너 정의 (볼륨 마운트) |
| [`docker/setup.sh`](docker/setup.sh) | 구축 스크립트 |

## 규칙

- 접속정보·자격증명은 어떤 형태로도 커밋하지 않는다.
- 적용된 스키마 파일은 수정하지 않는다. 변경은 `schema/002_*.sql`로 추가한다.
- id는 발급 시점에 확정되고 이후 변경하지 않는다.
- DB 포트는 루프백 전용이 기본값이다. 원격 노출은 암호화·접근제어와 함께 결정한다.
