-- under-claw-work — task prompt 데이터 구조 초기 스키마
-- 대상: PostgreSQL 14+
-- 적용: psql "$UNDER_CLAW_DB_URL" -f schema/001_init.sql
--
-- 이 파일은 데이터를 담지 않는다. 구조 정의만 담는다.
-- 실제 데이터는 별도로 할당한 데이터 저장소(원격 DB)에 위치한다.

BEGIN;

-- ─────────────────────────────────────────────────────────────
-- 열거형
-- ─────────────────────────────────────────────────────────────

-- 관리 상태: 이 task가 살아있는가
CREATE TYPE task_status AS ENUM (
  'open',      -- 진행 대상
  'blocked',   -- 외부 요인으로 멈춤
  'done',      -- 종료
  'dropped'    -- 폐기
);

-- 처리 단계: 파이프라인의 어디에 있는가
CREATE TYPE task_stage AS ENUM (
  'draft',     -- 프롬프트 초안 작성중
  'meta',      -- 메타 프롬프팅 진행/완료
  'ready',     -- 실행 대기 (에이전트가 집어갈 수 있음)
  'running',   -- 실행중
  'review'     -- 결과 검수중
);

CREATE TYPE run_result AS ENUM ('done', 'partial', 'failed');

CREATE TYPE reference_kind AS ENUM (
  'knowledge', -- 본문을 직접 보유한 지식
  'file',      -- 파일 경로 참조
  'url',       -- 외부 링크
  'snippet'    -- 짧은 인용/규격
);

-- ─────────────────────────────────────────────────────────────
-- 공통: updated_at 자동 갱신
-- ─────────────────────────────────────────────────────────────

CREATE FUNCTION touch_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ─────────────────────────────────────────────────────────────
-- 계층 1. 도메인
-- ─────────────────────────────────────────────────────────────

CREATE TABLE domain (
  id               text PRIMARY KEY,           -- 'ff-genius', 'dgdr', 'astro'
  name             text NOT NULL,
  summary          text,                       -- 한 줄 설명
  objectives       text,                       -- 주요 목표
  common_notes     text,                       -- 공통사항
  constraint_notes text,                       -- 제약사항
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER domain_touch BEFORE UPDATE ON domain
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

COMMENT ON COLUMN domain.objectives       IS '이 도메인이 달성하려는 주요 목표';
COMMENT ON COLUMN domain.common_notes     IS '소속 task 전반에 공통 적용되는 사항';
COMMENT ON COLUMN domain.constraint_notes IS '소속 task가 지켜야 하는 제약';

-- ─────────────────────────────────────────────────────────────
-- 계층 2. 마일스톤 (도메인에 종속)
-- ─────────────────────────────────────────────────────────────

CREATE TABLE milestone (
  id               text PRIMARY KEY,           -- 'ffg-1.2-dev-task'
  domain_id        text NOT NULL REFERENCES domain(id) ON UPDATE CASCADE,
  name             text NOT NULL,
  summary          text,
  objectives       text,                       -- 주요 목표
  common_notes     text,                       -- 공통사항
  constraint_notes text,                       -- 제약사항
  due_on           date,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),

  -- task가 (milestone_id, domain_id) 복합 참조로 정합성을 검증하기 위한 키
  UNIQUE (id, domain_id)
);

CREATE INDEX milestone_domain_idx ON milestone (domain_id);

CREATE TRIGGER milestone_touch BEFORE UPDATE ON milestone
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ─────────────────────────────────────────────────────────────
-- 실행 환경 / 모델
-- ─────────────────────────────────────────────────────────────

CREATE TABLE environment (
  id         text PRIMARY KEY,                 -- 'mac', 'astro-hermes'
  name       text NOT NULL,
  kind       text,                             -- 'local' | 'remote'
  note       text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE model (
  id         text PRIMARY KEY,                 -- 'claude-opus-5', 'gpt-5-codex'
  name       text NOT NULL,
  vendor     text,
  note       text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ─────────────────────────────────────────────────────────────
-- 계층 3. Task
-- ─────────────────────────────────────────────────────────────

CREATE TABLE task (
  id             text PRIMARY KEY,             -- 'PT-20260722-ffg-03'
  title          text NOT NULL,                -- 목록 조회용 요약 제목
  domain_id      text REFERENCES domain(id) ON UPDATE CASCADE,
  milestone_id   text,
  parent_id      text REFERENCES task(id) ON DELETE SET NULL,

  status         task_status NOT NULL DEFAULT 'open',
  stage          task_stage  NOT NULL DEFAULT 'draft',

  draft          text NOT NULL,                -- 프롬프트 초안 원문
  meta_prompt    text,                         -- 초안으로부터 생성된 메타 프롬프팅 결과

  auto           boolean NOT NULL DEFAULT false,  -- 자동화 대상 여부
  environment_id text REFERENCES environment(id) ON UPDATE CASCADE,

  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),

  -- 마일스톤은 반드시 같은 도메인에 속한다
  CONSTRAINT task_milestone_same_domain
    FOREIGN KEY (milestone_id, domain_id)
    REFERENCES milestone (id, domain_id) ON UPDATE CASCADE,

  -- 마일스톤이 있으면 도메인도 있어야 한다
  CONSTRAINT task_milestone_requires_domain
    CHECK (milestone_id IS NULL OR domain_id IS NOT NULL),

  -- 자기 자신을 상위로 둘 수 없다
  CONSTRAINT task_parent_not_self CHECK (parent_id IS NULL OR parent_id <> id)
);

CREATE INDEX task_status_idx    ON task (status);
CREATE INDEX task_stage_idx     ON task (stage);
CREATE INDEX task_domain_idx    ON task (domain_id);
CREATE INDEX task_milestone_idx ON task (milestone_id);
CREATE INDEX task_parent_idx    ON task (parent_id);
CREATE INDEX task_auto_idx      ON task (auto) WHERE auto;

CREATE TRIGGER task_touch BEFORE UPDATE ON task
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

COMMENT ON COLUMN task.status IS '관리 상태 — 이 task가 살아있는가';
COMMENT ON COLUMN task.stage  IS '처리 단계 — 파이프라인의 어디에 있는가';
COMMENT ON COLUMN task.draft  IS '사용자가 작성한 프롬프트 초안 원문';
COMMENT ON COLUMN task.auto   IS 'true면 도메인/마일스톤 원칙에 따라 자동 처리 대상';

-- 작업할 모델 (여러 개 가능)
CREATE TABLE task_model (
  task_id  text NOT NULL REFERENCES task(id) ON DELETE CASCADE,
  model_id text NOT NULL REFERENCES model(id) ON UPDATE CASCADE,
  role     text,                               -- 'primary' | 'review' | 'fallback'
  PRIMARY KEY (task_id, model_id)
);

CREATE INDEX task_model_model_idx ON task_model (model_id);

-- 관련 task (여러 개 가능). 상하위는 task.parent_id가 담당한다.
CREATE TABLE task_link (
  from_id text NOT NULL REFERENCES task(id) ON DELETE CASCADE,
  to_id   text NOT NULL REFERENCES task(id) ON DELETE CASCADE,
  kind    text NOT NULL DEFAULT 'related',     -- 'related' | 'follows' | 'blocks'
  note    text,
  PRIMARY KEY (from_id, to_id, kind),
  CONSTRAINT task_link_not_self CHECK (from_id <> to_id)
);

CREATE INDEX task_link_to_idx ON task_link (to_id);

-- 작업대상 프로젝트 (기존 work-log의 targets::)
CREATE TABLE task_target (
  task_id text NOT NULL REFERENCES task(id) ON DELETE CASCADE,
  target  text NOT NULL,                       -- 'lawtomatic-core', 경로 또는 프로젝트명
  PRIMARY KEY (task_id, target)
);

CREATE INDEX task_target_target_idx ON task_target (target);

-- 실행 이력 (결과 추적)
CREATE TABLE task_run (
  id             bigserial PRIMARY KEY,
  task_id        text NOT NULL REFERENCES task(id) ON DELETE CASCADE,
  environment_id text REFERENCES environment(id) ON UPDATE CASCADE,
  model_id       text REFERENCES model(id) ON UPDATE CASCADE,
  started_at     timestamptz NOT NULL DEFAULT now(),
  finished_at    timestamptz,
  result         run_result,
  note           text,
  CONSTRAINT task_run_time_order
    CHECK (finished_at IS NULL OR finished_at >= started_at)
);

CREATE INDEX task_run_task_idx ON task_run (task_id, started_at DESC);

-- ─────────────────────────────────────────────────────────────
-- 참고자료 — 도메인 / 마일스톤 / task 모두와 다대다
-- ─────────────────────────────────────────────────────────────

CREATE TABLE reference (
  id         text PRIMARY KEY,                 -- 'REF-eslitigation-api'
  title      text NOT NULL,
  kind       reference_kind NOT NULL,
  body       text,                             -- kind='knowledge' | 'snippet'
  uri        text,                             -- kind='file' | 'url'
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  -- 내용을 보유하든 위치를 가리키든 둘 중 하나는 있어야 한다
  CONSTRAINT reference_has_content CHECK (body IS NOT NULL OR uri IS NOT NULL)
);

CREATE TRIGGER reference_touch BEFORE UPDATE ON reference
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TABLE domain_reference (
  domain_id    text NOT NULL REFERENCES domain(id) ON DELETE CASCADE ON UPDATE CASCADE,
  reference_id text NOT NULL REFERENCES reference(id) ON DELETE CASCADE ON UPDATE CASCADE,
  PRIMARY KEY (domain_id, reference_id)
);

CREATE TABLE milestone_reference (
  milestone_id text NOT NULL REFERENCES milestone(id) ON DELETE CASCADE ON UPDATE CASCADE,
  reference_id text NOT NULL REFERENCES reference(id) ON DELETE CASCADE ON UPDATE CASCADE,
  PRIMARY KEY (milestone_id, reference_id)
);

CREATE TABLE task_reference (
  task_id      text NOT NULL REFERENCES task(id) ON DELETE CASCADE,
  reference_id text NOT NULL REFERENCES reference(id) ON DELETE CASCADE ON UPDATE CASCADE,
  PRIMARY KEY (task_id, reference_id)
);

CREATE INDEX domain_reference_ref_idx    ON domain_reference (reference_id);
CREATE INDEX milestone_reference_ref_idx ON milestone_reference (reference_id);
CREATE INDEX task_reference_ref_idx      ON task_reference (reference_id);

-- ─────────────────────────────────────────────────────────────
-- 조회 편의 뷰
-- ─────────────────────────────────────────────────────────────

-- 실행 대기 큐: 에이전트가 집어갈 대상
CREATE VIEW task_queue AS
SELECT t.id,
       t.title,
       t.domain_id,
       t.milestone_id,
       t.environment_id,
       t.auto,
       t.meta_prompt,
       t.updated_at
  FROM task t
 WHERE t.status = 'open'
   AND t.stage  = 'ready'
 ORDER BY t.updated_at;

COMMENT ON VIEW task_queue IS '복사·붙여넣기 없이 에이전트가 바로 집어갈 수 있는 task 목록';

COMMIT;
