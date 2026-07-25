import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory root;
  late Workspace workspace;

  setUp(() {
    root = Directory.systemTemp.createTempSync('worklog-round4-');
    workspace = Workspace(root);
    workspace.ensureLayout();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('candidate policy enforces objective, evidence, depth and dedup', () {
    final canonical = CanonicalRepository(workspace);
    _entity(canonical, EntityKind.domain, 'DOM-test', {'name': 'Domain'});
    _entity(canonical, EntityKind.milestone, 'MLS-test', {
      'title': 'Milestone',
      'domain_id': 'DOM-test',
    });
    _entity(canonical, EntityKind.objective, 'OBJ-test', {
      'title': 'Objective',
      'scope': {'domain_id': 'DOM-test', 'milestone_id': 'MLS-test'},
    });
    _entity(canonical, EntityKind.knowledge, 'KNW-test', {
      'title': 'Evidence',
      'kind': 'confirmed_fact',
      'confidence': 'confirmed',
      'scope': {
        'domain_ids': ['DOM-test'],
      },
    });
    final parent = _task(
      id: 'TSK-parent',
      autoDeriveTasks: true,
      maxGenerationDepth: 1,
    );
    TaskRepository(workspace).create(parent);
    final service = TaskCandidateService(workspace);
    final candidate = service.propose(
      parentTaskId: parent.id,
      title: 'Derived work',
      draft: 'Implement the missing contract.',
      objectiveIds: const ['OBJ-test'],
      knowledgeIds: const ['KNW-test'],
      referenceIds: const [],
      reason: 'The objective is not yet satisfied.',
    );

    expect(candidate.disposition, CandidateDisposition.pending);
    expect(
      () => service.propose(
        parentTaskId: parent.id,
        title: 'Derived work',
        draft: 'Different wording does not bypass semantic identity.',
        objectiveIds: const ['OBJ-test'],
        knowledgeIds: const ['KNW-test'],
        referenceIds: const [],
        reason: 'duplicate',
      ),
      throwsStateError,
    );
    final accepted = service.accept(candidate.id);
    expect(accepted.createdAutomatically, isTrue);
    expect(accepted.parentTaskId, parent.id);
    expect(accepted.alignedObjectiveIds, ['OBJ-test']);
    expect(accepted.evidenceKnowledgeIds, ['KNW-test']);
    expect(accepted.generationDepth, 1);
    expect(
      () => service.propose(
        parentTaskId: accepted.id,
        title: 'Too deep',
        draft: 'No.',
        objectiveIds: const ['OBJ-test'],
        knowledgeIds: const ['KNW-test'],
        referenceIds: const [],
        reason: 'depth',
      ),
      throwsStateError,
    );
  });

  test('candidate reject is immutable and creates no Task', () {
    final canonical = CanonicalRepository(workspace);
    _entity(canonical, EntityKind.domain, 'DOM-test', {'name': 'Domain'});
    _entity(canonical, EntityKind.milestone, 'MLS-test', {
      'title': 'Milestone',
      'domain_id': 'DOM-test',
    });
    TaskRepository(
      workspace,
    ).create(_task(id: 'TSK-parent', autoDeriveTasks: true));
    _entity(canonical, EntityKind.objective, 'OBJ-test', {
      'title': 'Objective',
      'scope': {'domain_id': 'DOM-test'},
    });
    _entity(canonical, EntityKind.reference, 'REF-test', {
      'title': 'Reference',
      'scope': <String, Object?>{},
      'reference_type': 'repository_document',
      'locator': {'kind': 'repo_relative_path', 'value': 'docs/spec.md'},
    });
    final service = TaskCandidateService(workspace);
    final candidate = service.propose(
      parentTaskId: 'TSK-parent',
      title: 'Candidate',
      draft: 'Draft',
      objectiveIds: const ['OBJ-test'],
      knowledgeIds: const [],
      referenceIds: const ['REF-test'],
      reason: 'Evidence',
    );
    service.reject(candidate.id);
    expect(service.list().single.disposition, CandidateDisposition.rejected);
    expect(() => service.accept(candidate.id), throwsStateError);
    expect(TaskRepository(workspace).list(), hasLength(1));
  });

  test('runtime contract validator reports invalid field', () {
    final validator = WorklogContractValidator();
    final valid = CanonicalEntity(
      kind: EntityKind.objective,
      id: 'OBJ-valid',
      data: {
        'schema_version': 1,
        'id': 'OBJ-valid',
        'type': 'objective',
        'scope': {'domain_id': 'DOM-valid'},
        'title': 'Objective',
        'status': 'active',
      },
    );
    validator.validateEntity(valid);
    final invalid = CanonicalEntity(
      kind: EntityKind.objective,
      id: 'OBJ-invalid',
      data: {
        'schema_version': 1,
        'id': 'OBJ-invalid',
        'type': 'objective',
        'scope': {'domain_id': 'wrong'},
        'title': 'Objective',
        'status': 'active',
      },
    );
    expect(
      () => validator.validateEntity(invalid),
      throwsA(
        isA<ContractViolation>().having(
          (error) => error.field,
          'field',
          'scope.domain_id',
        ),
      ),
    );
    expect(
      () => validator.validateTask(
        _task(
          id: 'TSK-invalid',
          createdAutomatically: true,
          alignedObjectiveIds: const [],
        ),
      ),
      throwsA(isA<ContractViolation>()),
    );
  });

  test('legacy migration dry-run requires approval and supports rollback', () {
    final source = Directory('${root.path}/legacy')..createSync();
    final input = File('${source.path}/2026-01-01.md');
    input.writeAsStringSync('''
[요청완료] <PT-20260101-demo-01>

**요구사항**
첫 번째 요구를 구현한다.
targets:: src/module
related:: PT-previous

#### Meta Prompt
    실행용 메타 프롬프트
###

[] <>
**요구사항**
targets::
related::
''');
    final service = LegacyMigrationService(workspace);
    final plan = service.dryRun(source);
    expect(plan.blocks, hasLength(1));
    expect(plan.blocks.single.legacyId, 'PT-20260101-demo-01');
    expect(plan.blocks.single.meta, '실행용 메타 프롬프트');
    expect(input.readAsStringSync(), contains('첫 번째 요구'));
    expect(
      () => service.import(
        plan,
        approved: false,
        domainId: 'DOM-test',
        milestoneId: 'MLS-test',
        targetEnvironment: 'ENV-test',
      ),
      throwsStateError,
    );
    final imported = service.import(
      plan,
      approved: true,
      domainId: 'DOM-test',
      milestoneId: 'MLS-test',
      targetEnvironment: 'ENV-test',
    );
    expect(imported.single.legacyIds, ['PT-20260101-demo-01']);
    expect(imported.single.approval, PromptApproval.pending);
    service.rollback(plan.importId);
    expect(TaskRepository(workspace).list(), isEmpty);
    expect(input.existsSync(), isTrue);
  });

  test('projection lifecycle fingerprints, skips and recovers atomically', () {
    TaskRepository(workspace).create(_task(id: 'TSK-one'));
    final lifecycle = ProjectionLifecycle(workspace);
    final first = lifecycle.rebuildIfNeeded();
    expect(first.rebuilt, isTrue);
    final second = lifecycle.rebuildIfNeeded();
    expect(second.rebuilt, isFalse);
    final database = sqlite3.open(workspace.database.path);
    expect(
      database.select('PRAGMA integrity_check').single.values.single,
      'ok',
    );
    expect(
      database.select('SELECT COUNT(*) FROM tasks').single.values.single,
      1,
    );
    database.close();

    TaskRepository(workspace).create(_task(id: 'TSK-two'));
    final third = lifecycle.rebuildIfNeeded();
    expect(third.rebuilt, isTrue);
    expect(third.fingerprint, isNot(first.fingerprint));

    File(
      '${workspace.database.path}.building',
    ).writeAsStringSync('interrupted');
    lifecycle.recover();
    expect(File('${workspace.database.path}.building').existsSync(), isFalse);
    expect(workspace.database.existsSync(), isTrue);
  });
}

CanonicalEntity _entity(
  CanonicalRepository repository,
  EntityKind kind,
  String id,
  Map<String, Object?> fields,
) {
  final entity = CanonicalEntity(
    kind: kind,
    id: id,
    data: {
      'schema_version': 1,
      'id': id,
      'type': kind.type,
      'status': 'active',
      ...fields,
    },
  );
  return repository.create(entity);
}

WorkTask _task({
  required String id,
  bool autoDeriveTasks = false,
  int maxGenerationDepth = 2,
  bool createdAutomatically = false,
  List<String> alignedObjectiveIds = const [],
}) => WorkTask(
  id: id,
  domainId: 'DOM-test',
  milestoneId: 'MLS-test',
  title: id,
  status: TaskStatus.draft,
  promptDraft: 'Draft',
  promptMeta: '',
  promptDraftRevision: 1,
  promptMetaSourceRevision: 0,
  approval: PromptApproval.missing,
  autoDeriveTasks: autoDeriveTasks,
  maxGenerationDepth: maxGenerationDepth,
  targetEnvironment: 'ENV-test',
  createdAutomatically: createdAutomatically,
  alignedObjectiveIds: alignedObjectiveIds,
);
