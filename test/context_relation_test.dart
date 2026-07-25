import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory temporary;
  late Workspace workspace;
  late EntityService service;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('under-claw-context-');
    workspace = Workspace(temporary)..ensureLayout();
    service = EntityService(workspace);
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test('typed relation registry rejects wrong target and cardinality', () {
    final graph = _seed(workspace, service);
    workspace.taskRelations(graph.task.id).writeAsStringSync('''
objective_ids: [${graph.objective.id}]
knowledge_ids: [${graph.current.id}]
follows: [${graph.task.id}, ${graph.task.id}]
''');
    expect(service.validateGraph, throwsFormatException);

    workspace.taskRelations(graph.task.id).writeAsStringSync('''
objective_ids: [${graph.objective.id}]
knowledge_ids: [${graph.current.id}]
follows: [${graph.task.id}]
''');
    expect(service.validateGraph, throwsFormatException);

    workspace.taskRelations(graph.task.id).writeAsStringSync('''
objective_ids: [${graph.objective.id}]
knowledge_ids: [${graph.current.id}]
''');
    service.validateGraph();
  });

  test(
    'context pack is deterministic budgeted and records graph provenance',
    () {
      final graph = _seed(workspace, service);
      workspace.taskRelations(graph.task.id).writeAsStringSync('''
objective_ids: [${graph.objective.id}]
knowledge_ids: [${graph.current.id}]
reference_ids: [${graph.reference.id}]
''');
      final repository = CanonicalRepository(workspace);
      repository.update(
        CanonicalEntity(
          kind: EntityKind.knowledge,
          id: graph.current.id,
          data: {
            ...graph.current.data,
            'importance': 90,
            'relations': {
              'supports': [graph.contradiction.id],
              'contradicts': [graph.contradiction.id],
              'supersedes': [graph.old.id],
              'derived_from': <String>[],
            },
          },
          body: graph.current.body,
        ),
      );

      final first = service.buildExecutionContext(
        graph.task.id,
        tokenBudget: 120,
      );
      final second = service.buildExecutionContext(
        graph.task.id,
        tokenBudget: 120,
      );
      expect(first.estimatedTokens, lessThanOrEqualTo(120));
      expect(
        first.entries.map((entry) => entry.id),
        second.entries.map((entry) => entry.id),
      );
      expect(first.supersededIds, contains(graph.old.id));
      expect(
        first.entries.map((entry) => entry.id),
        isNot(contains(graph.old.id)),
      );
      final current = first.entries.singleWhere(
        (entry) => entry.id == graph.current.id,
      );
      expect(current.provenance, 'task.relation');
      expect(current.contradictionIds, contains(graph.contradiction.id));
      final expanded = first.entries.singleWhere(
        (entry) => entry.id == graph.contradiction.id,
      );
      expect(expanded.provenance, contains('knowledge.'));
    },
  );

  test('required context is truncated instead of exceeding a tiny budget', () {
    final graph = _seed(workspace, service, meta: List.filled(200, 'M').join());
    final pack = service.buildExecutionContext(graph.task.id, tokenBudget: 1);
    expect(pack.estimatedTokens, lessThanOrEqualTo(1));
    expect(pack.entries.single.truncated, isTrue);
    expect(pack.entries.single.entityType, 'domain');
  });

  test('execution context excludes archived and sibling task Knowledge', () {
    final graph = _seed(workspace, service);
    final repository = CanonicalRepository(workspace);
    TaskRepository(workspace).create(
      WorkTask(
        id: 'TSK-sibling',
        domainId: graph.task.domainId,
        milestoneId: graph.task.milestoneId,
        title: 'Sibling',
        status: TaskStatus.draft,
        promptDraft: 'Draft',
        promptMeta: '',
        promptDraftRevision: 1,
        promptMetaSourceRevision: 0,
        approval: PromptApproval.missing,
        autoDeriveTasks: false,
        targetEnvironment: 'ENV-test',
      ),
    );
    final archived = service.create(
      kind: EntityKind.knowledge,
      title: 'Archived direct evidence',
      body: 'ARCHIVED-DIRECT-BODY',
      domainId: graph.task.domainId,
      milestoneId: graph.task.milestoneId,
    );
    repository.update(
      CanonicalEntity(
        kind: archived.kind,
        id: archived.id,
        data: {...archived.data, 'status': 'archived'},
        body: archived.body,
      ),
    );
    final sibling = service.create(
      kind: EntityKind.knowledge,
      title: 'Sibling task fact',
      body: 'SIBLING-TASK-BODY',
      domainId: graph.task.domainId,
      milestoneId: graph.task.milestoneId,
      taskId: 'TSK-sibling',
    );
    workspace.taskRelations(graph.task.id).writeAsStringSync('''
knowledge_ids: [${archived.id}]
''');

    final execution = service.buildExecutionContext(graph.task.id);
    final legacy = service.buildContext(graph.task.id);
    expect(
      execution.entries.map((entry) => entry.id),
      isNot(contains(archived.id)),
    );
    expect(
      execution.entries.map((entry) => entry.id),
      isNot(contains(sibling.id)),
    );
    expect(
      legacy.knowledge.map((entry) => entry.id),
      isNot(contains(archived.id)),
    );
    expect(
      legacy.knowledge.map((entry) => entry.id),
      isNot(contains(sibling.id)),
    );
  });

  test('execution context rejects archived scope anchors', () {
    final graph = _seed(workspace, service);
    final repository = CanonicalRepository(workspace);
    final milestone = repository.get(
      EntityKind.milestone,
      graph.task.milestoneId,
    )!;
    repository.update(
      CanonicalEntity(
        kind: milestone.kind,
        id: milestone.id,
        data: {...milestone.data, 'status': 'archived'},
        body: milestone.body,
      ),
    );

    expect(
      () => service.buildExecutionContext(graph.task.id),
      throwsStateError,
    );
    expect(() => service.buildContext(graph.task.id), throwsStateError);
  });
}

_Graph _seed(
  Workspace workspace,
  EntityService service, {
  String meta = 'Approved execution prompt',
}) {
  final domain = service.create(
    kind: EntityKind.domain,
    title: 'Domain',
    body: 'Domain rules',
  );
  final milestone = service.create(
    kind: EntityKind.milestone,
    title: 'Milestone',
    domainId: domain.id,
  );
  final objective = service.create(
    kind: EntityKind.objective,
    title: 'Objective',
    domainId: domain.id,
    milestoneId: milestone.id,
  );
  final old = service.create(
    kind: EntityKind.knowledge,
    title: 'Old fact',
    body: 'No longer applicable',
    domainId: domain.id,
    milestoneId: milestone.id,
  );
  final contradiction = service.create(
    kind: EntityKind.knowledge,
    title: 'Alternative fact',
    body: 'Conflicting evidence',
  );
  final current = service.create(
    kind: EntityKind.knowledge,
    title: 'Current fact',
    body: 'Current evidence',
    domainId: domain.id,
    milestoneId: milestone.id,
  );
  final reference = service.create(
    kind: EntityKind.reference,
    title: 'Source',
    body: 'Allowed excerpt',
  );
  final task = TaskRepository(workspace).create(
    WorkTask(
      id: 'TSK-context',
      domainId: domain.id,
      milestoneId: milestone.id,
      title: 'Execute',
      status: TaskStatus.ready,
      promptDraft: 'draft',
      promptMeta: meta,
      promptDraftRevision: 1,
      promptMetaSourceRevision: 1,
      promptMetaSourceSha256: TaskRepository.draftSha256('draft'),
      approval: PromptApproval.approved,
      autoDeriveTasks: false,
      targetEnvironment: 'ENV-local',
    ),
  );
  return _Graph(task, objective, old, current, contradiction, reference);
}

class _Graph {
  const _Graph(
    this.task,
    this.objective,
    this.old,
    this.current,
    this.contradiction,
    this.reference,
  );

  final WorkTask task;
  final CanonicalEntity objective;
  final CanonicalEntity old;
  final CanonicalEntity current;
  final CanonicalEntity contradiction;
  final CanonicalEntity reference;
}
