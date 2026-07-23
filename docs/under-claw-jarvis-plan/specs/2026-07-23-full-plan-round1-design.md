# Full plan round 1 design (2026-07-23)

## 1. Requirements and success criteria

This is a brownfield correction against the final plan in
`underjoy-work-log/docs/최종계획`.

| Requirement | Current implementation | Round 1 correction |
|---|---|---|
| Durable graph | Canonical generic files and SQLite relations exist | Add typed Core CRUD, archive, graph validation, dependency cycle checks, and context packs |
| GUI management | Task-only two-pane shell | Add Domain/Milestone navigation and Objective/Knowledge/Reference management using the same Core |
| CLI management | Generic entity list and Task commands | Add typed entity create/update/archive/link, graph validation, context build, and knowledge search |
| Authentication | Deliberately locked provider gate | Preserve the normative security gate; do not invent or persist a verifier |
| Distribution | Developer installer and ownership manifest | Keep existing safe installer; verify smoke behavior without claiming signed artifacts |

Success criteria:

1. Domain → Milestone → Objective/Knowledge/Reference can be created and linked
   through Core, CLI, and Flutter. `[verify: unit and widget tests]`
2. Invalid references and cyclic Task dependencies are rejected.
   `[verify: negative unit tests]`
3. A Task context pack returns scoped objectives, knowledge, and references.
   `[verify: deterministic unit test]`
4. SQLite is rebuilt automatically and supports local knowledge search.
   `[verify: delete/rebuild/search test]`
5. Existing Task and immutable control contracts remain green.
   `[verify: complete Flutter test suite]`

## 2. Adopted approach and rationale

Add a small `EntityService` above `CanonicalRepository`. It owns typed defaults,
relationship mutation, archive semantics, whole-graph validation, and context
assembly. CLI and Flutter call this service; neither duplicates YAML rules.

Rejected alternative: replacing the canonical model with an ORM/RDB schema.
That would violate Git-as-source-of-truth and create a migration risk unrelated
to the missing user workflows.

## 3. Change scope and files

- Core: `lib/core/entity_service.dart`, projection/search additions, exports.
- CLI: typed `entity-*`, `graph-validate`, `knowledge-search`, `context-build`.
- Flutter: Domain/Milestone tree and graph entity create/edit/archive dialogs.
- Tests: Core graph/context/search and GUI creation flow.
- Documentation: this design and README command summary.

Unchanged: authentication provider selection, user credentials, Git history,
release signing, and legacy source files.

## 4. Cross-project contract impact

No external RPC contract changes. New Core APIs are additive. Canonical IDs,
paths, Task YAML, immutable Event/ControlRequest/Disposition behavior, and
installer ownership stay unchanged.

## 5. Risks and unresolved assumptions

- The final plan cannot honestly be fully complete until an external repository
  authentication provider is selected and signed installers are produced.
  Mitigation: preserve the locked gate and report it rather than weakening it.
- Generic frontmatter is JSON-compatible YAML. This remains readable by the
  existing decoder and avoids adding a serializer dependency.
- Full semantic Git merge is outside this bounded round. Existing optimistic
  head checks remain the concurrency guard.

## 6. Verification

- `dart format --output=none --set-exit-if-changed .`
- `flutter analyze`
- `flutter test`
- desktop and CLI builds
- isolated install/initialize/uninstall smoke
- repository secret scan and `git diff --check`

## 7. Tasks

1. Implement typed graph CRUD, archive, link, validation, context pack, and
   search. Verify with positive and negative Core tests.
2. Expose the same operations through CLI. Verify with process-level smoke.
3. Add Flutter graph navigation and editor actions. Verify with widget tests.
4. Run full regression, build, packaging smoke, and security scan.
