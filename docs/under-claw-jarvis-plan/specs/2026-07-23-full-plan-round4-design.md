# Full plan round 4 design (2026-07-23)

## 1. Requirements and success criteria

This round closes four executable gaps from the normative plan without
claiming that external authentication, code signing, or remote CAS exists.

- Derived Task candidates contain an Objective and evidence, enforce depth and
  fingerprint deduplication, and require an explicit accept/reject disposition.
  [verify: candidate unit tests]
- Every canonical entity kind has a runtime contract validator and invalid
  documents fail with field-specific diagnostics. The validator is deliberately
  a product-contract validator, not a claim of complete JSON Schema 2020-12
  support. [verify: valid/invalid matrix tests]
- Legacy prompt blocks are parsed into a dry-run report; import requires an
  approval flag, preserves legacy IDs, leaves source files untouched, and can
  roll back only files created by that import. [verify: synthetic fixture E2E]
- SQLite projection rebuild uses a canonical fingerprint, format version,
  exclusive process lock, temporary database, integrity check, and atomic
  rename; an interrupted temporary file is recoverable. [verify: lifecycle
  tests]

## 2. Adopted approach and rationale

Add small Core services around the existing repositories. This is safer than a
large rewrite while rounds 1-3 are still uncommitted. Candidate and migration
records remain local plans until explicit approval. Projection lifecycle owns
only `.worklog` files and never mutates canonical Git data.

Rejected alternative: adding a general JSON Schema package and claiming full
Draft 2020-12 conformance. The current repository schemas use a small subset,
and the product needs cross-entity rules that JSON Schema alone cannot express.

## 3. Change scope and files

- New: `task_candidate_service.dart`, `schema_validator.dart`,
  `legacy_migration.dart`, `projection_lifecycle.dart`, focused tests.
- Small integrations: `workspace.dart`, `models.dart`, `task_codec.dart`,
  `worklog_core.dart`, and CLI command routing.
- No changes to auth protocols, signing, remote repositories, or installer
  ownership in this round.

## 4. Cross-project contract impact

The source work-log repository is read-only input to migration. Public Dart
Core APIs and CLI commands are additive. Existing task YAML remains readable;
new generation and legacy fields are optional and emitted by new writes.

## 5. Risks and unresolved assumptions

- Legacy Markdown has historical variants. The parser recognizes the documented
  `[state] <PT-...>`, requirement, `targets::`, `related::`, and indented Meta
  section forms and reports skipped/ambiguous blocks instead of guessing.
- Atomic replacement relies on same-directory rename semantics.
- External auth, remote compare-and-create, signed installers, and real host
  acceptance remain separate gates and are not represented as complete.

## 6. Verification

Run formatter, analyzer, all Flutter tests, CLI build, macOS build, secret scan,
diff check, and a temporary-directory migration/projection lifecycle E2E.

## 7. Task split

1. Implement candidate policy and accept/reject persistence.
2. Implement runtime schema and cross-document validation.
3. Implement dry-run/approve/import/rollback legacy migration.
4. Implement atomic versioned projection lifecycle.
5. Wire public exports/CLI and run the full verification matrix.
